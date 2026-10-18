"""Repository rule: Dart tests never read the wall clock.

`DateTime.now()` in a test makes its result depend on when it runs: a day,
hour or DST boundary between building the expectation and the code under test
flips it. Tests use `clock.now()` under `withClock(Clock.fixed(...))` or
`withClockAt(...)` (test/support/pinned_clock.dart), fixed `DateTime` values,
or `Stopwatch`/fake_async for durations.

Full-line comments may name the call. Exceptions need an entry with a reason
in wall_clock_allowlist.txt next to this file; entries that no longer match
fail, so the list cannot rot.
"""
from __future__ import annotations

from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ALLOWLIST = Path(__file__).with_name("wall_clock_allowlist.txt")
MAX_ALLOWED = 10

# Calls and tear-offs; `DateTime.timestamp()` is the same clock in UTC.
FORBIDDEN = re.compile(r"\bDateTime\s*\.\s*(?:now|timestamp)\b")


def parse_allowlist(text: str) -> dict[str, str]:
    """`test/path.dart | reason` per line; blank lines and `#` comments skip."""
    entries: dict[str, str] = {}
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        path, separator, reason = (part.strip() for part in line.partition("|"))
        if not separator or not reason:
            raise ValueError(f"allowlist line {number}: missing '| reason'")
        if not re.fullmatch(r"test/[\w./-]+\.dart", path) or ".." in path.split("/"):
            raise ValueError(f"allowlist line {number}: invalid path {path!r}")
        if path in entries:
            raise ValueError(f"allowlist line {number}: duplicate {path}")
        entries[path] = reason
    return entries


def wall_clock_reads(text: str) -> list[int]:
    """Line numbers that read the wall clock outside full-line comments."""
    return [number for number, line in enumerate(text.splitlines(), 1)
            if not line.lstrip().startswith("//") and FORBIDDEN.search(line)]


def check(root: Path, allowlist: dict[str, str]) -> list[str]:
    """Every violation as a readable message; empty when the rule holds."""
    if len(allowlist) > MAX_ALLOWED:
        return [f"allowlist has {len(allowlist)} entries, at most {MAX_ALLOWED}"]
    problems = []
    seen = set()
    for path in sorted((root / "test").rglob("*.dart")):
        relative = path.relative_to(root).as_posix()
        lines = wall_clock_reads(path.read_text(encoding="utf-8"))
        if not lines:
            continue
        if relative in allowlist:
            seen.add(relative)
            continue
        problems += [f"{relative}:{line}: reads the wall clock" for line in lines]
    for stale in sorted(set(allowlist) - seen):
        problems.append(f"{stale}: allowlisted but reads no wall clock (remove it)")
    return problems


class WallClockRuleTest(unittest.TestCase):
    def test_repository_tests_do_not_read_the_wall_clock(self):
        allowlist = parse_allowlist(ALLOWLIST.read_text(encoding="utf-8"))
        problems = check(ROOT, allowlist)
        self.assertEqual(problems, [], "\n" + "\n".join(problems) + (
            "\nUse clock.now() with withClock/withClockAt, a fixed DateTime or "
            "Stopwatch/fake_async; see test/tooling/wall_clock_rule_test.py."))


class WallClockRuleDetectionTest(unittest.TestCase):
    """The rule must catch what it exists for and nothing it should not."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="eatova-clock-rule-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def write(self, name: str, text: str) -> None:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def test_calls_tear_offs_and_spacing_variants_are_caught(self):
        for code in ["final t = DateTime.now();",
                     "final t = DateTime.now().toUtc();",
                     "clock: DateTime.now,",
                     "final t = DateTime .now ();",
                     "final t = DateTime.timestamp();",
                     "x = f(); // trailing comment, DateTime.now() before it"]:
            with self.subTest(code=code):
                self.assertEqual(wall_clock_reads(f"void main() {{\n  {code}\n}}\n"), [2])

    def test_injected_clocks_comments_and_lookalikes_pass(self):
        text = "\n".join([
            "// DateTime.now() in a line comment explains history.",
            "  /// Doc comments may name DateTime.now() too.",
            "final a = clock.now();",
            "final b = withClock(Clock.fixed(DateTime(2026, 8, 31)), f);",
            "final c = MyDateTime.now();",
            "final d = 'DateTimeNow';",
        ])
        self.assertEqual(wall_clock_reads(text), [])

    def test_nested_helpers_and_probes_are_scanned(self):
        self.write("test/support/helper.dart", "final t = DateTime.now();\n")
        self.write("test/feature/deep/probe.dart", "\nfinal t = DateTime.now();\n")
        self.write("lib/app.dart", "final t = DateTime.now();\n")
        self.assertEqual(check(self.root, {}), [
            "test/feature/deep/probe.dart:2: reads the wall clock",
            "test/support/helper.dart:1: reads the wall clock",
        ])

    def test_allowlisted_file_passes_and_stale_entries_fail(self):
        self.write("test/a_test.dart", "final t = DateTime.now();\n")
        self.write("test/b_test.dart", "final t = clock.now();\n")
        allowlist = parse_allowlist(
            "# comment\n\ntest/a_test.dart | real socket deadline\n"
            "test/b_test.dart | no longer needed\n")
        self.assertEqual(check(self.root, allowlist), [
            "test/b_test.dart: allowlisted but reads no wall clock (remove it)"])

    def test_allowlist_requires_reason_valid_path_and_unique_entries(self):
        for text in ["test/a_test.dart\n", "test/a_test.dart |  \n",
                     "lib/a.dart | reason\n", "test/../a.dart | reason\n",
                     "test/a_test.dart | one\ntest/a_test.dart | two\n"]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                parse_allowlist(text)

    def test_allowlist_stays_small(self):
        allowlist = {f"test/f{i}_test.dart": "reason" for i in range(MAX_ALLOWED + 1)}
        self.assertEqual(len(check(self.root, allowlist)), 1)


if __name__ == "__main__":
    unittest.main()
