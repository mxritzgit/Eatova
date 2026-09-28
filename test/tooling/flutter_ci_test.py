"""Prove sharded Flutter CI cannot omit tests or inflate merged coverage."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("flutter_ci", ROOT / "tool/flutter_ci.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def lcov(source, hits):
    return "\n".join([
        f"SF:{source}",
        *(f"DA:{line},{hit}" for line, hit in hits.items()),
        f"LF:{len(hits)}", f"LH:{sum(hit > 0 for hit in hits.values())}",
        "end_of_record", "",
    ])


def events(paths):
    """Match Flutter's JSON protocol, including invisible loading tests."""
    result = [{"type": "start", "protocolVersion": "0.1.1", "time": 0}]
    for index, path in enumerate(paths):
        base = index * 10
        result.extend([
            {"type": "suite", "suite": {"id": base, "platform": "vm", "path": path}, "time": base},
            {"type": "testStart", "test": {"id": base + 1, "name": f"loading {path}",
                "suiteID": base, "groupIDs": [], "metadata": {"skip": False}}, "time": base},
            {"type": "testDone", "testID": base + 1, "result": "success", "skipped": False,
                "hidden": True, "time": base + 1},
            {"type": "group", "group": {"id": base + 2, "suiteID": base,
                "parentID": None, "name": "", "testCount": 1, "metadata": {"skip": False}}, "time": base + 1},
            {"type": "testStart", "test": {"id": base + 3, "name": f"case {index}",
                "suiteID": base, "groupIDs": [base + 2], "metadata": {"skip": False}}, "time": base + 2},
            {"type": "testDone", "testID": base + 3, "result": "success", "skipped": False,
                "hidden": False, "time": base + 3},
        ])
    result.extend([{"type": "allSuites", "count": len(paths), "time": 100},
                   {"type": "done", "success": True, "time": 101}])
    return result


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class CoverageTests(unittest.TestCase):
    def test_merge_uses_unique_source_lines_and_hits_from_every_shard(self):
        first = MODULE.parse_lcov(lcov("lib/a.dart", {1: 1, 2: 0, 3: 0}))
        second = MODULE.parse_lcov(lcov("lib/a.dart", {1: 0, 2: 1, 3: 0}) + lcov("lib/b.dart", {8: 1}))
        merged = MODULE.merge_coverage([first, second])
        self.assertEqual(set(merged), {"lib/a.dart", "lib/b.dart"})
        self.assertEqual(set(merged["lib/a.dart"]), {1, 2, 3})
        self.assertGreater(merged["lib/a.dart"][1], 0)
        self.assertGreater(merged["lib/a.dart"][2], 0)
        self.assertEqual(merged["lib/a.dart"][3], 0)
        self.assertEqual(MODULE.coverage_percent(merged), 75.0)

    def test_repeated_high_coverage_shards_cannot_hide_uncovered_lines(self):
        # Summing per-shard LF/LH would report 90/91 and falsely pass 88%.
        good = MODULE.parse_lcov(lcov("lib/good.dart", {i: 1 for i in range(1, 10)}))
        bad = MODULE.parse_lcov(lcov("lib/bad.dart", {1: 0, 2: 0}))
        merged = MODULE.merge_coverage([good] * 10 + [bad])
        self.assertAlmostEqual(MODULE.coverage_percent(merged), 900 / 11)
        self.assertLess(MODULE.coverage_percent(merged), 88)

    def test_floor_comparison_does_not_round_87_99_to_88(self):
        coverage = {"lib/a.dart": {line: int(line <= 8799) for line in range(1, 10001)}}
        self.assertLess(MODULE.coverage_percent(coverage), 88)

    def test_generated_l10n_is_excluded_by_exact_directory(self):
        parsed = MODULE.parse_lcov(lcov("lib/a.dart", {1: 0}) +
                                  lcov("lib/src/l10n/generated/app_localizations.dart", {1: 1}) +
                                  lcov("lib/src/l10n/generated_custom.dart", {1: 0}))
        self.assertEqual(set(parsed), {"lib/a.dart", "lib/src/l10n/generated_custom.dart"})
        self.assertEqual(MODULE.coverage_percent(parsed), 0)

    def test_windows_source_paths_normalize_before_union(self):
        parsed = MODULE.parse_lcov(lcov(r"lib\src\feature.dart", {2: 1}))
        self.assertEqual(set(parsed), {"lib/src/feature.dart"})

    def test_invalid_lcov_never_supplies_a_percentage(self):
        valid = lcov("lib/a.dart", {1: 1, 2: 0})
        invalid = ["", "garbage\n", valid.replace("end_of_record", ""),
                   valid.replace("LF:2\n", ""), valid.replace("LH:1\n", ""),
                   valid.replace("LF:2", "LF:20"), valid.replace("LH:1", "LH:2"),
                   valid.replace("DA:2,0", "DA:1,0"), valid.replace("DA:2,0", "DA:2,-1"),
                   valid.replace("DA:2,0", "DA:0,0"), valid.replace("DA:2,0", "DA:2,NaN"),
                   valid.replace("DA:2,0", "DA:2,1.5"), valid.replace("LF:2", "LF:-2")]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                MODULE.parse_lcov(value)

    def test_source_path_cannot_escape_lib_or_impersonate_generated_exclusion(self):
        for source in ["../lib/a.dart", "lib/../private.dart", "/etc/passwd",
                       "test/test.dart", "lib/src/l10n/generated/../../feature.dart"]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                MODULE.parse_lcov(lcov(source, {1: 1}))

    def test_empty_eligible_coverage_fails(self):
        with self.assertRaises(ValueError):
            MODULE.coverage_percent({})


class DependencyTests(unittest.TestCase):
    def test_only_successful_analyzer_and_complete_matrix_pass_required_gate(self):
        MODULE.check_dependencies({"flutter-analyze": {"result": "success"},
                                   "flutter-test": {"result": "success"}})

    def test_failure_cancellation_skip_missing_or_extra_dependency_fails(self):
        valid = {"flutter-analyze": {"result": "success"}, "flutter-test": {"result": "success"}}
        cases = [{}, {"flutter-test": {"result": "success"}},
                 {**valid, "unexpected-job": {"result": "success"}}]
        for job in valid:
            for status in ["failure", "cancelled", "skipped", "pending", None, True]:
                cases.append({**valid, job: {"result": status}})
        for needs in cases:
            with self.subTest(needs=needs), self.assertRaises(ValueError):
                MODULE.check_dependencies(needs)

    def test_dependency_payload_must_be_a_mapping(self):
        for needs in [None, True, 1, "success", [], ["flutter-analyze", "flutter-test"]]:
            with self.subTest(needs=needs), self.assertRaises(ValueError):
                MODULE.check_dependencies(needs)


class FlutterCiFixtures(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="eatova-flutter-ci-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ["test/a_test.dart", "test/nested/b_test.dart", "test/c_test.dart"]:
            self.write(name, "void main() {}\n")
        self.write("test/support.dart", "// Not a test entry point.\n")
        self.write("lib/a.dart", "\n" * 10)
        self.write("lib/b.dart", "\n" * 10)
        self.manifest = MODULE.build_manifest(self.root, 2, revision="a" * 40)

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def write_report(self, entries, name="report.jsonl"):
        return self.write(name, "".join(json.dumps(event) + "\n" for event in entries))

    def artifacts(self):
        destination = self.root / "artifacts"
        for index, tests in enumerate(self.manifest["shards"]):
            directory = destination / f"shard-{index}"
            directory.mkdir(parents=True, exist_ok=True)
            (directory / "manifest.json").write_text(json.dumps(self.manifest), encoding="utf-8")
            self.write_report(events(tests), f"artifacts/shard-{index}/report.jsonl")
            coverage = lcov("lib/a.dart", {1: int(index == 0), 2: int(index == 1)})
            coverage += lcov("lib/b.dart", {1: 1})
            (directory / "lcov.info").write_text(coverage, encoding="utf-8")
            self.stamp(directory, index)
        return destination

    def stamp(self, directory, index, run_attempt=None):
        coverage = MODULE.parse_lcov((directory / "lcov.info").read_text(encoding="utf-8"))
        result = {"version": 1, "revision": self.manifest["revision"],
                  "manifest_sha256": MODULE.manifest_digest(self.manifest), "shard": index,
                  "exit_code": 0, "report_sha256": digest(directory / "report.jsonl"),
                  "coverage_sha256": digest(directory / "lcov.info"),
                  "coverage_bytes": (directory / "lcov.info").stat().st_size,
                  "coverage_inventory": {source: sorted(lines) for source, lines in coverage.items()}}
        if run_attempt is not None:
            result["run_attempt"] = run_attempt
        (directory / "result.json").write_text(json.dumps(result), encoding="utf-8")

    def attempt_artifacts(self, attempts):
        """Lay out a download of every attempt's artifacts, as CI receives it."""
        destination = self.root / "attempts"
        for index, attempt in attempts:
            directory = destination / f"shard-{index}-attempt-{attempt}"
            directory.mkdir(parents=True)
            (directory / "manifest.json").write_text(json.dumps(self.manifest), encoding="utf-8")
            self.write_report(events(self.manifest["shards"][index]),
                              f"attempts/shard-{index}-attempt-{attempt}/report.jsonl")
            coverage = lcov("lib/a.dart", {1: int(index == 0), 2: int(index == 1)})
            coverage += lcov("lib/b.dart", {1: 1})
            (directory / "lcov.info").write_text(coverage, encoding="utf-8")
            self.stamp(directory, index, attempt)
        return destination


class DiscoveryTests(FlutterCiFixtures):
    def test_discovery_and_shards_cover_nested_and_new_tests_exactly_once(self):
        self.write("test/new/nested/new_test.dart", "void main() {}\n")
        discovered = MODULE.discover_tests(self.root)
        self.assertEqual(discovered, sorted(["test/a_test.dart", "test/c_test.dart",
                                             "test/nested/b_test.dart", "test/new/nested/new_test.dart"]))
        shards = MODULE.partition_tests(discovered, 3)
        self.assertEqual(sorted(path for shard in shards for path in shard), discovered)
        self.assertTrue(all(shards))

    def test_timing_hints_balance_cost_without_selecting_or_omitting_tests(self):
        files = [f"test/{letter}_test.dart" for letter in "abcdefgh"]
        timings = {files[0]: 100, files[1]: 90, "deleted_test.dart": 10000}
        first = MODULE.partition_tests(files, 2, timings)
        second = MODULE.partition_tests(list(reversed(files)), 2, timings)
        self.assertEqual(first, second)
        self.assertEqual(sorted(path for shard in first for path in shard), files)
        self.assertNotEqual(next(i for i, shard in enumerate(first) if files[0] in shard),
                            next(i for i, shard in enumerate(first) if files[1] in shard))

    def test_longest_suites_start_first_instead_of_waiting_behind_alphabetic_order(self):
        files = ["test/a_short_test.dart", "test/b_short_test.dart", "test/y_heavy_test.dart",
                 "test/z_longest_test.dart", "test/m_medium_test.dart", "test/c_short_test.dart"]
        timings = {"test/z_longest_test.dart": 100, "test/y_heavy_test.dart": 90,
                   "test/m_medium_test.dart": 10}
        shards = MODULE.partition_tests(files, 2, timings)
        self.assertEqual({shard[0] for shard in shards},
                         {"test/z_longest_test.dart", "test/y_heavy_test.dart"})
        for shard in shards:
            weights = [max(2, timings.get(path, 2)) for path in shard]
            self.assertEqual(weights, sorted(weights, reverse=True))
        self.assertEqual(sorted(path for shard in shards for path in shard), sorted(files))

    def test_revision_is_an_exact_git_object_id(self):
        for revision in ["a" * 39, "a" * 41, "a" * 63, "a" * 65, "z" * 40]:
            with self.subTest(revision=revision), self.assertRaises(ValueError):
                MODULE.build_manifest(self.root, 2, revision=revision)
        self.assertEqual(MODULE.build_manifest(self.root, 2, revision="a" * 64)["revision"], "a" * 64)

    def test_invalid_partition_never_silently_drops_a_shard_or_test(self):
        for files, count in [([], 2), (["test/a_test.dart"], 0),
                             (["test/a_test.dart"], 2), (["test/a_test.dart"] * 2, 1)]:
            with self.subTest(files=files, count=count), self.assertRaises(ValueError):
                MODULE.partition_tests(files, count)

    def test_manifest_binds_test_and_source_content_not_only_names(self):
        self.assertEqual(sorted(self.manifest["test_sha256"]), self.manifest["tests"])
        self.assertEqual(set(self.manifest["sources"]), {"lib/a.dart", "lib/b.dart"})
        before = MODULE.manifest_digest(self.manifest)
        self.write("test/a_test.dart", "void main() { throw StateError('changed'); }\n")
        after = MODULE.build_manifest(self.root, 2, revision="a" * 40)
        self.assertNotEqual(MODULE.manifest_digest(after), before)


class ReporterTests(FlutterCiFixtures):
    def report(self, entries, expected=None):
        return MODULE.validate_report(self.write_report(entries), expected or ["test/a_test.dart"], self.root)

    def test_real_protocol_counts_actual_tests_and_ignores_successful_loader(self):
        result = self.report(events(["test/a_test.dart"]))
        self.assertEqual(result["tests"], 1)
        self.assertEqual(result["suites"], ["test/a_test.dart"])

    def test_absolute_and_file_uri_paths_stay_inside_checkout(self):
        for path in [str(self.root / "test/a_test.dart"), (self.root / "test/a_test.dart").as_uri()]:
            self.assertEqual(self.report(events([path]))["tests"], 1)
        outside = self.root.parent / "another-checkout/test/a_test.dart"
        with self.assertRaises(ValueError):
            self.report(events([str(outside)]))

    def test_failed_skipped_cancelled_or_truncated_report_fails(self):
        base = events(["test/a_test.dart"])
        cases = [base[:-1], []]
        for success in [False, None, "true"]:
            bad = copy.deepcopy(base)
            bad[-1]["success"] = success
            cases.append(bad)
        for change in [{"result": "failure"}, {"result": "error"}, {"skipped": True}]:
            bad = copy.deepcopy(base)
            bad[-3].update(change)
            cases.append(bad)
        for bad in cases:
            with self.subTest(events=bad), self.assertRaises(ValueError):
                self.report(bad)

    def test_successful_done_cannot_hide_a_missing_test_completion_or_reported_error(self):
        base = events(["test/a_test.dart"])
        missing_completion = [event for event in base if not (event["type"] == "testDone" and event["testID"] == 3)]
        explicit_error = copy.deepcopy(base)
        explicit_error.insert(-1, {"type": "error", "testID": 3, "error": "failed", "isFailure": True})
        for bad in [missing_completion, explicit_error]:
            with self.assertRaises(ValueError):
                self.report(bad)

    def test_missing_duplicate_or_unplanned_suite_fails_even_with_successful_done(self):
        for actual, expected in [(["test/a_test.dart"], ["test/a_test.dart", "test/c_test.dart"]),
                                 (["test/a_test.dart", "test/a_test.dart"], ["test/a_test.dart"]),
                                 (["test/c_test.dart"], ["test/a_test.dart"])]:
            with self.subTest(actual=actual), self.assertRaises(ValueError):
                self.report(events(actual), expected)

    def test_group_count_prevents_a_report_with_a_silently_missing_test(self):
        report = events(["test/a_test.dart"])
        next(event for event in report if event["type"] == "group")["group"]["testCount"] = 2
        with self.assertRaises(ValueError):
            self.report(report)

    def test_duplicate_completion_cannot_manufacture_test_count(self):
        report = events(["test/a_test.dart"])
        report.insert(-1, copy.deepcopy(report[-3]))
        with self.assertRaises(ValueError):
            self.report(report)

    def test_all_suites_completion_and_count_are_required(self):
        base = events(["test/a_test.dart"])
        missing = [event for event in base if event["type"] != "allSuites"]
        wrong_count = copy.deepcopy(base)
        next(event for event in wrong_count if event["type"] == "allSuites")["count"] = 2
        for report in [missing, wrong_count]:
            with self.assertRaises(ValueError):
                self.report(report)

    def test_reporter_integer_ids_and_counts_cannot_be_boolean_aliases(self):
        base = events(["test/a_test.dart"])
        changes = [("suite", "suite", "id", False), ("testStart", "test", "id", True),
                   ("testStart", "test", "suiteID", False), ("group", "group", "suiteID", False),
                   ("testDone", None, "testID", True), ("allSuites", None, "count", True)]
        for kind, nested, key, value in changes:
            report = copy.deepcopy(base)
            event = next(event for event in report if event["type"] == kind)
            (event[nested] if nested else event)[key] = value
            with self.subTest(kind=kind, key=key), self.assertRaises(ValueError):
                self.report(report)

    def test_reporter_duplicate_json_keys_and_nonfinite_values_fail_closed(self):
        valid = "".join(json.dumps(event) + "\n" for event in events(["test/a_test.dart"]))
        for text in [valid.replace('"success": true', '"success": false, "success": true'),
                     valid.replace('"time": 101', '"time": NaN')]:
            report = self.write("report.jsonl", text)
            with self.assertRaises(ValueError):
                MODULE.validate_report(report, ["test/a_test.dart"], self.root)


class ArtifactTests(FlutterCiFixtures):
    def validate(self, path):
        return MODULE.validate_shards(self.manifest, path, self.root)

    def test_complete_artifacts_merge_to_same_union_as_one_unsharded_report(self):
        merged = self.validate(self.artifacts())
        self.assertEqual(MODULE.coverage_percent(merged), 100)
        self.assertEqual({key: sorted(lines) for key, lines in merged.items()},
                         {"lib/a.dart": [1, 2], "lib/b.dart": [1]})

    def test_each_required_artifact_is_fail_closed_when_missing(self):
        for filename in ["manifest.json", "report.jsonl", "lcov.info", "result.json"]:
            destination = self.artifacts()
            target = destination / "shard-1" / filename
            backup = target.read_bytes()
            target.unlink()
            try:
                with self.subTest(filename=filename), self.assertRaises((ValueError, FileNotFoundError)):
                    self.validate(destination)
            finally:
                target.write_bytes(backup)

    def test_missing_or_extra_shard_directory_fails(self):
        destination = self.artifacts()
        (destination / "shard-1").rename(destination / "shard-9")
        with self.assertRaises(ValueError):
            self.validate(destination)

    def test_failed_exit_wrong_revision_index_or_manifest_cannot_be_accepted(self):
        destination = self.artifacts()
        target = destination / "shard-0/result.json"
        original = json.loads(target.read_text())
        for key, value in [("exit_code", 1), ("revision", "b" * 40), ("shard", 1),
                           ("manifest_sha256", "0" * 64), ("coverage_bytes", 1)]:
            bad = {**original, key: value}
            target.write_text(json.dumps(bad))
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.validate(destination)
        target.write_text(json.dumps(original))

    def test_artifact_integer_metadata_rejects_boolean_and_float_aliases(self):
        destination = self.artifacts()
        target = destination / "shard-0/result.json"
        original = json.loads(target.read_text())
        for key, value in [("version", True), ("version", 1.0), ("shard", False),
                           ("shard", 0.0), ("exit_code", False), ("exit_code", 0.0)]:
            target.write_text(json.dumps({**original, key: value}))
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                self.validate(destination)
        target.write_text(json.dumps(original))

    def test_manifest_integer_version_rejects_boolean_alias(self):
        self.manifest["version"] = True
        with self.assertRaises(ValueError):
            self.validate(self.artifacts())

    def test_valid_record_boundary_coverage_truncation_cannot_raise_percentage(self):
        destination = self.artifacts()
        target = destination / "shard-0/lcov.info"
        target.write_text(lcov("lib/a.dart", {1: 1, 2: 0}), encoding="utf-8")
        with self.assertRaises(ValueError):
            self.validate(destination)

    def test_coverage_inventory_detects_missing_source_even_if_digest_is_rewritten(self):
        destination = self.artifacts()
        directory = destination / "shard-0"
        coverage = directory / "lcov.info"
        coverage.write_text(lcov("lib/a.dart", {1: 1, 2: 0}), encoding="utf-8")
        result = json.loads((directory / "result.json").read_text())
        result["coverage_sha256"] = digest(coverage)
        result["coverage_bytes"] = coverage.stat().st_size
        (directory / "result.json").write_text(json.dumps(result))
        with self.assertRaises(ValueError):
            self.validate(destination)

    def test_truncated_test_report_cannot_be_hidden_by_successful_process_exit(self):
        destination = self.artifacts()
        target = destination / "shard-0/report.jsonl"
        target.write_text("\n".join(target.read_text().splitlines()[:-1]) + "\n")
        with self.assertRaises(ValueError):
            self.validate(destination)

    def test_report_suite_omission_is_rejected_even_when_rehashed(self):
        destination = self.artifacts()
        index = next(i for i, tests in enumerate(self.manifest["shards"]) if len(tests) > 1)
        directory = destination / f"shard-{index}"
        self.write_report(events(self.manifest["shards"][index][:-1]), f"artifacts/shard-{index}/report.jsonl")
        self.stamp(directory, index)
        with self.assertRaises(ValueError):
            self.validate(destination)

    def test_coverage_source_must_exist_in_manifest_and_line_must_exist_in_source(self):
        destination = self.artifacts()
        directory = destination / "shard-0"
        for content in [lcov("lib/invented.dart", {1: 1}), lcov("lib/a.dart", {1000: 1})]:
            (directory / "lcov.info").write_text(content)
            self.stamp(directory, 0)
            with self.assertRaises(ValueError):
                self.validate(destination)

    def test_changed_checkout_tests_or_sources_invalidate_stamped_results(self):
        destination = self.artifacts()
        for name in ["test/a_test.dart", "lib/a.dart"]:
            path = self.root / name
            original = path.read_text()
            path.write_text(original + "// changed after run\n")
            try:
                with self.subTest(name=name), self.assertRaises(ValueError):
                    self.validate(destination)
            finally:
                path.write_text(original)

    def test_even_self_consistent_artifacts_cannot_omit_a_test_from_the_plan(self):
        omitted = self.manifest["shards"][0].pop()
        # Keep both shards nonempty; omission still violates the discovered list.
        if not self.manifest["shards"][0]:
            self.manifest["shards"][0].append(self.manifest["shards"][1].pop())
        self.assertIn(omitted, self.manifest["tests"])
        destination = self.artifacts()
        with self.assertRaises(ValueError):
            self.validate(destination)


class RerunTests(FlutterCiFixtures):
    """A rerun keeps every earlier attempt's artifacts in the same workflow run."""

    def validate(self, path, run_attempt):
        return MODULE.validate_shards(self.manifest, path, self.root, run_attempt)

    def fresh(self, attempts):
        shutil.rmtree(self.root / "attempts", ignore_errors=True)
        return self.attempt_artifacts(attempts)

    def test_rerun_of_a_failed_shard_uses_that_shards_newest_attempt(self):
        # Run 36347378169: shard 1 failed in attempt 1 (no result.json) and
        # passed when "Re-run failed jobs" started attempt 2.
        destination = self.attempt_artifacts([(0, 1), (1, 1), (1, 2)])
        (destination / "shard-1-attempt-1/result.json").unlink()
        selected = MODULE.select_attempts(destination, 2, 2)
        self.assertEqual({index: path.name for index, (_, path) in selected.items()},
                         {0: "shard-0-attempt-1", 1: "shard-1-attempt-2"})
        merged = self.validate(destination, 2)
        self.assertEqual(MODULE.coverage_percent(merged), 100)

    def test_rerun_of_a_passing_shard_supersedes_its_earlier_artifact(self):
        destination = self.attempt_artifacts([(0, 1), (0, 3), (1, 1), (1, 2)])
        selected = MODULE.select_attempts(destination, 2, 3)
        self.assertEqual([path.name for _, path in selected.values()],
                         ["shard-0-attempt-3", "shard-1-attempt-2"])
        self.validate(destination, 3)

    def test_failed_newest_attempt_never_falls_back_to_an_older_success(self):
        for filename in ["result.json", "report.jsonl", "lcov.info", "manifest.json"]:
            with self.subTest(filename=filename):
                destination = self.fresh([(0, 1), (1, 1), (1, 2)])
                (destination / "shard-1-attempt-2" / filename).unlink()
                with self.assertRaises((ValueError, FileNotFoundError)):
                    self.validate(destination, 2)

    def test_missing_shard_future_attempt_or_unexpected_artifact_fails(self):
        cases = {
            "missing shard": ([(0, 1), (0, 2)], None),
            "attempt newer than the run": ([(0, 1), (1, 3)], None),
            "shard outside the plan": ([(0, 1), (1, 1)], "shard-2-attempt-1"),
            "unversioned name": ([(0, 1), (1, 1)], "shard-1"),
            "attempt zero": ([(0, 1), (1, 1)], "shard-1-attempt-0"),
            "padded attempt": ([(0, 1), (1, 1)], "shard-1-attempt-01"),
            "padded shard": ([(0, 1), (1, 1)], "shard-01-attempt-1"),
            "foreign artifact": ([(0, 1), (1, 1)], "shard-summary"),
        }
        for name, (attempts, extra) in cases.items():
            with self.subTest(name=name):
                destination = self.fresh(attempts)
                if extra:
                    (destination / extra).mkdir()
                with self.assertRaises(ValueError):
                    self.validate(destination, 2)

    def test_artifact_file_in_place_of_a_directory_fails(self):
        destination = self.attempt_artifacts([(0, 1), (1, 1)])
        (destination / "shard-1-attempt-2").write_text("not a directory")
        with self.assertRaises(ValueError):
            self.validate(destination, 2)

    def test_evidence_must_name_the_attempt_of_its_artifact(self):
        destination = self.attempt_artifacts([(0, 1), (1, 1), (1, 2)])
        target = destination / "shard-1-attempt-2/result.json"
        original = json.loads(target.read_text())
        # A stale attempt-1 result under the attempt-2 name, a missing
        # attempt, or type aliases must not pass as the rerun's evidence.
        for value in [1, None, True, 2.0, "2", 0]:
            bad = {key: item for key, item in original.items() if key != "run_attempt"}
            if value is not None:
                bad["run_attempt"] = value
            target.write_text(json.dumps(bad))
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.validate(destination, 2)
        target.write_text(json.dumps(original))
        self.validate(destination, 2)

    def test_run_attempt_must_be_a_positive_integer(self):
        destination = self.attempt_artifacts([(0, 1), (1, 1)])
        for value in [0, -1, True, 1.0, None]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                MODULE.select_attempts(destination, 2, value)
        with self.assertRaises(ValueError):
            MODULE.main(["aggregate", "--root", str(self.root), "--shards", "2",
                         "--output", str(destination), "--run-attempt", "0"])

    def test_local_layout_rejects_attempt_named_artifacts(self):
        destination = self.attempt_artifacts([(0, 1), (1, 1)])
        with self.assertRaises(ValueError):
            MODULE.validate_shards(self.manifest, destination, self.root)

    def test_aggregate_command_verifies_and_reports_the_selected_attempts(self):
        destination = self.attempt_artifacts([(0, 1), (1, 1), (1, 2)])
        output = io.StringIO()
        with mock.patch.object(MODULE, "build_manifest", return_value=self.manifest), \
             mock.patch.object(MODULE, "_timings", return_value={}), \
             mock.patch.dict(MODULE.os.environ, {"GITHUB_ACTIONS": "false", "GITHUB_STEP_SUMMARY": ""}), \
             contextlib.redirect_stdout(output):
            self.assertEqual(MODULE.main(["aggregate", "--root", str(self.root), "--shards", "2",
                                          "--output", str(destination), "--run-attempt", "2"]), 0)
        self.assertIn("Selected shard artifacts: shard-0-attempt-1, shard-1-attempt-2", output.getvalue())
        self.assertIn("All 3 test files verified", output.getvalue())


class RunnerTests(FlutterCiFixtures):
    def run_shard(self, compiler, output, *extra):
        with mock.patch.object(MODULE, "build_manifest", return_value=self.manifest), \
             mock.patch.object(MODULE, "_timings", return_value={}), \
             mock.patch.object(MODULE.subprocess, "run", side_effect=compiler):
            return MODULE.main(["run", "--root", str(self.root), "--shards", "2",
                                "--shard", "0", "--output", str(output), "--flutter", "stub-flutter", *extra])

    def test_failed_compiler_never_stamps_a_success_artifact(self):
        output = self.root / "run-output"
        self.assertEqual(self.run_shard(lambda *args, **kwargs: SimpleNamespace(returncode=7), output), 7)
        self.assertFalse((output / "shard-0/result.json").exists())

    def test_fresh_run_executes_every_assigned_file_with_coverage_and_dummy_defines(self):
        output = self.root / "run-output"

        def compiler(command, **kwargs):
            self.assertEqual(command[:2], ["stub-flutter", "test"])
            self.assertEqual(kwargs["cwd"], self.root)
            self.assertEqual([arg for arg in command if arg.endswith("_test.dart")], self.manifest["shards"][0])
            self.assertIn("--coverage", command)
            self.assertIn("--reporter=expanded", command)
            self.assertIn("--dart-define=SUPABASE_URL=https://ci.invalid", command)
            self.assertIn("--dart-define=SUPABASE_ANON_KEY=ci-dummy-key", command)
            self.assertFalse(any(arg.startswith(("--name", "--plain-name", "--tags", "--exclude-tags", "--total-shards")) for arg in command))
            directory = output / "shard-0"
            self.write_report(events(self.manifest["shards"][0]), "run-output/shard-0/report.jsonl")
            (directory / "lcov.info").write_text(lcov("lib/a.dart", {1: 1}))
            return SimpleNamespace(returncode=0)

        self.assertEqual(self.run_shard(compiler, output), 0)
        result = json.loads((output / "shard-0/result.json").read_text())
        self.assertEqual(result["exit_code"], 0)
        self.assertEqual(result["coverage_inventory"], {"lib/a.dart": [1]})
        self.assertNotIn("run_attempt", result)

    def test_ci_run_stamps_its_attempt_into_the_evidence(self):
        output = self.root / "run-output"

        def compiler(command, **kwargs):
            self.write_report(events(self.manifest["shards"][0]), "run-output/shard-0/report.jsonl")
            (output / "shard-0/lcov.info").write_text(lcov("lib/a.dart", {1: 1}))
            return SimpleNamespace(returncode=0)

        self.assertEqual(self.run_shard(compiler, output, "--run-attempt", "3"), 0)
        self.assertEqual(json.loads((output / "shard-0/result.json").read_text())["run_attempt"], 3)

    def test_stale_success_output_cannot_be_reused_instead_of_running_tests(self):
        output = self.root / "run-output"
        self.write("run-output/shard-0/result.json", '{"exit_code":0}')
        compiler = mock.Mock(return_value=SimpleNamespace(returncode=0))
        with self.assertRaises(ValueError):
            self.run_shard(compiler, output)
        compiler.assert_not_called()


if __name__ == "__main__":
    unittest.main()
