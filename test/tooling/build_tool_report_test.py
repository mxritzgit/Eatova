"""Scanner infrastructure failures must not become advisory-only success."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("report", ROOT / "tool/build_tool_report.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BuildToolReportTests(unittest.TestCase):
    inventory = {"components": [{"group": "example", "name": "tool", "version": "1.0"}]}

    def report(self, vulnerabilities):
        return {"results": [{"packages": [{
            "package": {"name": "example:tool", "version": "1.0"},
            "vulnerabilities": vulnerabilities,
        }]}]}

    def test_complete_clean_report_and_visible_advisories_are_distinct_successes(self):
        _, clean = MODULE.summarize(0, self.inventory, self.report([]))
        _, findings = MODULE.summarize(1, self.inventory, self.report([{"id": "GHSA-example"}]))
        self.assertEqual(clean, [])
        self.assertEqual(findings, [("example:tool", "1.0", "GHSA-example")])

    def test_scanner_errors_and_inconsistent_status_fail(self):
        for code, findings in [(2, []), (1, []), (0, [{"id": "GHSA-example"}])]:
            with self.subTest(code=code, findings=findings):
                with self.assertRaises(ValueError):
                    MODULE.summarize(code, self.inventory, self.report(findings))

    def test_missing_or_incomplete_inventory_fails(self):
        for inventory, report in [({"components": []}, self.report([])),
                                  (self.inventory, {"results": []}),
                                  (self.inventory, {"results": [{"packages": []}]})]:
            with self.assertRaises(ValueError):
                MODULE.summarize(0, inventory, report)


if __name__ == "__main__":
    unittest.main()
