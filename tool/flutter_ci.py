"""Run complete Flutter file shards and verify their reports and merged coverage.

Timing hints affect placement only. Tests are always discovered from the checkout;
no prior result can satisfy this gate. Artifacts bind to the exact manifest/SHA.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[1]
TIMINGS = ROOT / "tool/flutter_ci_timings.json"
GENERATED = "lib/src/l10n/generated/"


def _decode_json(text: str):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"Duplicate JSON key: {key}")
            result[key] = value
        return result
    return json.loads(text, object_pairs_hook=unique,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))


def _json(path: Path):
    return _decode_json(path.read_text(encoding="utf-8"))


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _write(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _relative(path: str, prefix: str) -> str:
    path = path.replace("\\", "/")
    parts = PurePosixPath(path).parts
    if (not path.startswith(prefix + "/") or ".." in parts or "." in parts
            or "//" in path or ":" in path or path.startswith("/")):
        raise ValueError(f"Invalid {prefix} path: {path}")
    return path


def discover_tests(root: Path) -> list[str]:
    root = root.resolve()
    files = []
    for path in (root / "test").rglob("*_test.dart"):
        if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(root):
            raise ValueError("Test discovery encountered an unsafe path")
        files.append(_relative(path.relative_to(root).as_posix(), "test"))
    if not files:
        raise ValueError("No Flutter tests discovered")
    return sorted(files)


def partition_tests(files: list[str], shard_count: int,
                    timings: dict[str, float] | None = None) -> list[list[str]]:
    if (type(shard_count) is not int or shard_count < 1 or shard_count > len(files)
            or len(set(files)) != len(files)):
        raise ValueError("Invalid test partition")
    timings = timings or {}
    def weight(path):
        value = timings.get(path, 2.0)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            raise ValueError("Invalid timing hint")
        return max(2.0, value)
    groups = [[] for _ in range(shard_count)]
    totals = [0.0] * shard_count
    for path in sorted(files, key=lambda item: (-weight(item), item)):
        index = min(range(shard_count), key=lambda i: (totals[i], len(groups[i]), i))
        groups[index].append(path)
        totals[index] += weight(path)
    # Start the slowest suites first so they overlap the shorter files.
    return groups


def build_manifest(root: Path, shard_count: int, timings=None, revision=None) -> dict:
    root = root.resolve()
    files = discover_tests(root)
    revision = revision or subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", revision):
        raise ValueError("Invalid checkout revision")
    sources = {}
    for path in sorted((root / "lib").rglob("*.dart")):
        relative = path.relative_to(root).as_posix()
        if relative.startswith(GENERATED):
            continue
        if path.is_symlink() or not path.resolve().is_relative_to(root):
            raise ValueError("Unsafe source path")
        sources[relative] = {"sha256": _sha(path), "lines": len(path.read_text(encoding="utf-8").splitlines())}
    if not sources:
        raise ValueError("No application sources found")
    return {"version": 1, "revision": revision, "tests": files,
            "test_sha256": {path: _sha(root / path) for path in files},
            "sources": sources, "shards": partition_tests(files, shard_count, timings)}


def manifest_digest(manifest: dict) -> str:
    return hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def parse_lcov(text: str) -> dict[str, dict[int, int]]:
    records = {}
    source = None
    lines = {}
    totals = {}
    count = 0
    for raw in text.splitlines():
        if not raw.strip():
            continue
        if raw.startswith("TN:") and source is None:
            continue
        if raw.startswith("SF:"):
            if source is not None:
                raise ValueError("Unterminated coverage record")
            source = _relative(raw[3:], "lib")
            if source in records:
                raise ValueError("Duplicate coverage source")
            lines, totals = {}, {}
        elif raw == "end_of_record":
            if source is None or set(totals) != {"LF", "LH"}:
                raise ValueError("Incomplete coverage record")
            if totals["LF"] != len(lines) or totals["LH"] != sum(n > 0 for n in lines.values()):
                raise ValueError("Coverage totals do not match line records")
            # Validate generated records too; only their contribution is excluded.
            records[source] = lines
            source = None
            count += 1
        elif source is None:
            raise ValueError("Coverage data outside a source record")
        elif raw.startswith("DA:"):
            values = raw[3:].split(",")
            if len(values) not in (2, 3) or not all(re.fullmatch(r"\d+", v) for v in values[:2]):
                raise ValueError("Invalid coverage line")
            line, hits = map(int, values[:2])
            if line < 1 or line in lines:
                raise ValueError("Duplicate or invalid coverage line")
            lines[line] = hits
        elif raw.startswith(("LF:", "LH:")):
            key, value = raw.split(":", 1)
            if key in totals or not re.fullmatch(r"\d+", value):
                raise ValueError("Invalid coverage total")
            totals[key] = int(value)
        elif not raw.startswith(("FN:", "FNDA:", "FNF:", "FNH:", "BRDA:", "BRF:", "BRH:")):
            raise ValueError("Unknown coverage record")
    if source is not None or count == 0:
        raise ValueError("Empty or truncated coverage report")
    return {path: values for path, values in records.items() if not path.startswith(GENERATED)}


def merge_coverage(coverages: list[dict[str, dict[int, int]]]) -> dict[str, dict[int, int]]:
    result = {}
    for coverage in coverages:
        for path, lines in coverage.items():
            target = result.setdefault(path, {})
            for line, hits in lines.items():
                target[line] = max(target.get(line, 0), hits)
    return result


def coverage_percent(coverage: dict[str, dict[int, int]]) -> float:
    values = [hit for lines in coverage.values() for hit in lines.values()]
    if not values:
        raise ValueError("No eligible coverage lines")
    return 100.0 * sum(hit > 0 for hit in values) / len(values)


def coverage_inventory(coverage):
    return {path: sorted(lines) for path, lines in sorted(coverage.items())}


def _suite_path(value: str, root: Path) -> str:
    if value.startswith("file:"):
        value = unquote(urlparse(value).path)
        if re.match(r"^/[A-Za-z]:/", value):
            value = value[1:]
    path = Path(value)
    if path.is_absolute():
        try:
            value = path.resolve().relative_to(root.resolve()).as_posix()
        except ValueError as error:
            raise ValueError("Reporter suite outside checkout") from error
    return _relative(value, "test")


def validate_report(report: Path, expected: list[str], root: Path) -> dict:
    if len(expected) != len(set(expected)) or not expected:
        raise ValueError("Invalid expected test suites")
    events = []
    for line in report.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            raise ValueError("Empty reporter event")
        event = _decode_json(line)
        if not isinstance(event, dict) or not isinstance(event.get("type"), str):
            raise ValueError("Invalid reporter event")
        events.append(event)
    if (not events or events[0].get("type") != "start" or
            events[-1].get("type") != "done" or events[-1].get("success") is not True or
            sum(e["type"] == "done" for e in events) != 1):
        raise ValueError("Missing successful reporter completion")
    suites, starts, completed = {}, {}, set()
    suite_times, visible, declared_counts = {}, {}, {}
    all_suites = []
    for event in events:
        kind = event["type"]
        if kind == "error":
            raise ValueError("Reporter recorded a test error")
        if kind == "suite":
            suite = event.get("suite", {})
            ident = suite.get("id")
            path = _suite_path(suite.get("path", ""), root)
            if type(ident) is not int or ident < 0 or ident in suites or path in suites.values() or path not in expected:
                raise ValueError("Duplicate or unexpected suite")
            suites[ident] = path
            suite_times[ident] = [event.get("time", 0), event.get("time", 0)]
            visible[ident] = 0
        elif kind == "group":
            group = event.get("group", {})
            if group.get("parentID") is None:
                suite, count = group.get("suiteID"), group.get("testCount")
                if type(suite) is not int or suite not in suites or suite in declared_counts or type(count) is not int or count < 1:
                    raise ValueError("Invalid root test group")
                declared_counts[suite] = count
        elif kind == "allSuites":
            count = event.get("count")
            if type(count) is not int or count < 1:
                raise ValueError("Invalid suite count")
            all_suites.append(count)
        elif kind == "testStart":
            test = event.get("test", {})
            ident, suite = test.get("id"), test.get("suiteID")
            if type(ident) is not int or type(suite) is not int or ident < 0 or ident in starts or suite not in suites or test.get("metadata", {}).get("skip") is True:
                raise ValueError("Duplicate, skipped or unknown test start")
            starts[ident] = suite
        elif kind == "testDone":
            ident = event.get("testID")
            if (type(ident) is not int or ident not in starts or ident in completed or event.get("result") != "success"
                    or event.get("skipped") is not False or type(event.get("hidden")) is not bool):
                raise ValueError("Incomplete, skipped or failing test")
            completed.add(ident)
            suite = starts[ident]
            suite_times[suite][1] = event.get("time", 0)
            if event["hidden"] is False:
                visible[suite] += 1
    if (set(suites.values()) != set(expected) or all_suites != [len(expected)]
            or set(starts) != completed or not starts or visible != declared_counts
            or any(n == 0 for n in visible.values())):
        raise ValueError("Omitted or unfinished test suites")
    durations = {}
    for ident, (start, end) in suite_times.items():
        if not all(type(v) in (int, float) and math.isfinite(v) for v in (start, end)) or end < start:
            raise ValueError("Invalid reporter timing")
        durations[suites[ident]] = (end - start) / 1000.0
    return {"tests": sum(visible.values()), "suites": sorted(suites.values()), "durations": durations}


def _valid_attempt(value) -> bool:
    return type(value) is int and value >= 1


def select_attempts(artifact_dir: Path, shard_count: int, run_attempt: int) -> dict[int, tuple[int, Path]]:
    """Pick each shard's artifact from its latest workflow run attempt.

    "Re-run failed jobs" keeps earlier attempts' artifacts in the same run,
    so every attempt uploads its own name. Selection is by attempt number only:
    a failed newer attempt never falls back to an older successful artifact.
    """
    if not _valid_attempt(run_attempt) or type(shard_count) is not int or shard_count < 1:
        raise ValueError("Invalid run attempt or shard count")
    latest = {}
    for entry in artifact_dir.iterdir():
        match = re.fullmatch(r"shard-(0|[1-9][0-9]*)-attempt-([1-9][0-9]*)", entry.name)
        if not match or entry.is_symlink() or not entry.is_dir():
            raise ValueError(f"Unexpected shard artifact: {entry.name}")
        index, attempt = int(match[1]), int(match[2])
        if index >= shard_count or attempt > run_attempt:
            raise ValueError(f"Unexpected shard artifact: {entry.name}")
        if index not in latest or attempt > latest[index][0]:
            latest[index] = (attempt, entry)
    if set(latest) != set(range(shard_count)):
        raise ValueError("Missing shard artifacts")
    return dict(sorted(latest.items()))


def validate_shards(manifest: dict, artifact_dir: Path, root: Path | None = None,
                    run_attempt: int | None = None):
    root = (root or Path.cwd()).resolve()
    shards = manifest.get("shards", [])
    if type(manifest.get("version")) is not int or manifest.get("version") != 1 or not shards:
        raise ValueError("Invalid manifest version or shards")
    flat = [path for shard in shards for path in shard]
    if len(flat) != len(set(flat)) or sorted(flat) != manifest.get("tests") or any(not s for s in shards):
        raise ValueError("Manifest omits or duplicates tests")
    actual = build_manifest(root, len(shards), revision=manifest["revision"])
    for key in ("tests", "test_sha256", "sources"):
        if actual[key] != manifest.get(key):
            raise ValueError(f"Checkout no longer matches manifest {key}")
    if run_attempt is None:
        expected_dirs = {f"shard-{i}" for i in range(len(shards))}
        if {p.name for p in artifact_dir.iterdir()} != expected_dirs:
            raise ValueError("Missing or unexpected shard artifacts")
        folders = {i: (None, artifact_dir / f"shard-{i}") for i in range(len(shards))}
    else:
        folders = select_attempts(artifact_dir, len(shards), run_attempt)
    coverages = []
    for index, files in enumerate(shards):
        attempt, folder = folders[index]
        if _json(folder / "manifest.json") != manifest:
            raise ValueError("Shard manifest mismatch")
        result = _json(folder / "result.json")
        if (type(result.get("version")) is not int or result.get("version") != 1 or result.get("revision") != manifest["revision"] or
                result.get("manifest_sha256") != manifest_digest(manifest) or
                type(result.get("shard")) is not int or result.get("shard") != index or
                type(result.get("exit_code")) is not int or result.get("exit_code") != 0):
            raise ValueError("Unsuccessful or mismatched shard")
        # The artifact name and the evidence inside it must name the same attempt.
        if attempt is not None and (not _valid_attempt(result.get("run_attempt")) or result["run_attempt"] != attempt):
            raise ValueError("Shard artifact does not belong to its run attempt")
        report, lcov = folder / "report.jsonl", folder / "lcov.info"
        if (result.get("report_sha256") != _sha(report) or result.get("coverage_sha256") != _sha(lcov)
                or result.get("coverage_bytes") != lcov.stat().st_size):
            raise ValueError("Changed or truncated shard artifact")
        validate_report(report, files, root)
        coverage = parse_lcov(lcov.read_text(encoding="utf-8"))
        if result.get("coverage_inventory") != coverage_inventory(coverage):
            raise ValueError("Coverage source/line inventory mismatch")
        for source, lines in coverage.items():
            if source not in manifest["sources"] or any(n > manifest["sources"][source]["lines"] for n in lines):
                raise ValueError("Coverage does not belong to checked out source")
        coverage_percent(coverage)
        coverages.append(coverage)
    merged = merge_coverage(coverages)
    coverage_percent(merged)
    return merged


def _lcov_text(coverage):
    chunks = []
    for path, lines in sorted(coverage.items()):
        chunks += [f"SF:{path}", *(f"DA:{line},{hit}" for line, hit in sorted(lines.items())),
                   f"LF:{len(lines)}", f"LH:{sum(hit > 0 for hit in lines.values())}", "end_of_record"]
    return "\n".join(chunks) + "\n"


def _timings(path):
    data = _json(path)
    return data["seconds"]


def check_dependencies(needs: dict) -> None:
    if (not isinstance(needs, dict) or set(needs) != {"flutter-analyze", "flutter-test"} or
            any(not isinstance(job, dict) or job.get("result") != "success" for job in needs.values())):
        raise ValueError("Analyzer and every test shard must succeed")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "run", "aggregate"))
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--shards", type=int, default=4)
    parser.add_argument("--shard", type=int)
    parser.add_argument("--timings", type=Path, default=TIMINGS)
    parser.add_argument("--output", type=Path, default=Path(".dart_tool/flutter-ci"))
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument("--floor", type=float, default=88.0)
    parser.add_argument("--run-attempt", type=int,
                        help="GitHub run attempt; artifacts are then named shard-N-attempt-K")
    args = parser.parse_args(argv)
    root, output = args.root.resolve(), args.output.resolve()
    if args.run_attempt is not None and not _valid_attempt(args.run_attempt):
        raise ValueError("Invalid run attempt")
    if args.command == "aggregate" and os.environ.get("GITHUB_ACTIONS") == "true":
        check_dependencies(json.loads(os.environ.get("FLUTTER_CI_NEEDS", "{}")))
    manifest = build_manifest(root, args.shards, _timings(args.timings))
    if args.command == "plan":
        _write(output / "manifest.json", manifest)
        print(json.dumps({"files": len(manifest["tests"]), "shards": [len(s) for s in manifest["shards"]]}))
    elif args.command == "run":
        if args.shard is None or not 0 <= args.shard < args.shards:
            raise ValueError("Choose a valid shard")
        folder = output / f"shard-{args.shard}"
        # A prior successful artifact must never survive a failed rerun.
        if folder.exists():
            raise ValueError("Shard output already exists; choose a fresh output directory")
        _write(folder / "manifest.json", manifest)
        files = manifest["shards"][args.shard]
        command = [args.flutter, "test", "--no-pub", "--coverage", f"--coverage-path={folder / 'lcov.info'}",
                   f"--file-reporter=json:{folder / 'report.jsonl'}", "--reporter=expanded",
                   f"--concurrency={max(1, min(4, (os.cpu_count() or 2) // 2))}",
                   "--dart-define=SUPABASE_URL=https://ci.invalid", "--dart-define=SUPABASE_ANON_KEY=ci-dummy-key", *files]
        print(f"Running {len(files)} complete test files in shard {args.shard + 1}/{args.shards}", flush=True)
        process = subprocess.run(command, cwd=root, check=False)
        if process.returncode != 0:
            return process.returncode
        summary = validate_report(folder / "report.jsonl", files, root)
        coverage_file = folder / "lcov.info"
        coverage = parse_lcov(coverage_file.read_text(encoding="utf-8"))
        coverage_percent(coverage)
        result = {"version": 1, "revision": manifest["revision"], "manifest_sha256": manifest_digest(manifest),
                  "shard": args.shard, "exit_code": 0, "report_sha256": _sha(folder / "report.jsonl"),
                  "coverage_sha256": _sha(coverage_file), "coverage_bytes": coverage_file.stat().st_size,
                  "coverage_inventory": coverage_inventory(coverage), **summary}
        if args.run_attempt is not None:
            result["run_attempt"] = args.run_attempt
        _write(folder / "result.json", result)
        print(f"Validated {summary['tests']} tests across {len(files)} files", flush=True)
    else:
        if args.run_attempt is not None:
            selected = select_attempts(output, args.shards, args.run_attempt)
            print("Selected shard artifacts: " + ", ".join(path.name for _, path in selected.values()), flush=True)
        coverage = validate_shards(manifest, output, root, args.run_attempt)
        percentage = coverage_percent(coverage)
        if not math.isfinite(args.floor) or not 88 <= args.floor <= 100:
            raise ValueError("Coverage floor may not be lowered below 88%")
        merged = output.parent / "lcov.info"
        merged.write_text(_lcov_text(coverage), encoding="utf-8")
        summary = f"All {len(manifest['tests'])} test files verified; global coverage {percentage:.2f}% (floor {args.floor:g}%)."
        print(summary)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as stream:
                stream.write(summary + "\n")
        if percentage < args.floor:
            raise ValueError("Global line coverage is below the required floor")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Flutter CI validation failed: {error}", file=sys.stderr)
        sys.exit(1)
