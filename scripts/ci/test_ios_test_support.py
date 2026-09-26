"""Offline fixtures for simulator selection and XCTest discovery safeguards."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import unittest

from ios_test_support import (
    SHARE_SUITES, declared_share_cases, declared_test_methods, select_device, verify_results,
)


def device(number, *, available=True, name="iPhone 17", state="Shutdown", **extra):
    return {
        "udid": f"00000000-0000-0000-0000-{number:012d}",
        "name": name,
        "state": state,
        "isAvailable": available,
        **extra,
    }


def runtime(version):
    return f"com.apple.CoreSimulator.SimRuntime.iOS-{version}"


def result_tree():
    cases = declared_share_cases()
    return {"testNodes": [{"nodeType": "Unit test bundle", "children": [
        {"nodeType": "Test Suite", "name": suite, "children": [
            {"nodeType": "Test Case", "name": f"{case}()",
             "nodeIdentifier": f"RunnerTests.{suite}/{case}()", "result": "Passed"}
            for case in sorted(cases[suite])
        ]} for suite in SHARE_SUITES
    ]}]}


class SimulatorSelectionTests(unittest.TestCase):
    def test_newest_available_iphone_wins_over_old_booted_ipad_and_unavailable(self):
        selected = device(3)
        self.assertEqual(select_device({"devices": {
            runtime("18-5"): [device(1, state="Booted")],
            runtime("26-0"): [device(2, name="iPad Pro", state="Booted"), selected],
            runtime("27-0"): [device(4, available=False)],
            "com.apple.CoreSimulator.SimRuntime.tvOS-27-0": [device(5)],
        }}), selected["udid"])

    def test_numeric_runtime_order_and_booted_preference(self):
        selected = device(2, state="Booted")
        self.assertEqual(select_device({"devices": {
            runtime("26-9"): [device(4, state="Booted")],
            runtime("26-10"): [device(3), selected],
        }}), selected["udid"])

    def test_device_type_allows_renamed_iphone_and_rejects_renamed_ipad(self):
        selected = device(1, name="Test device", deviceTypeIdentifier="com.apple.CoreSimulator.SimDeviceType.iPhone-17")
        self.assertEqual(select_device({"devices": {runtime("26-0"): [
            selected, device(2, deviceTypeIdentifier="com.apple.CoreSimulator.SimDeviceType.iPad-Pro"),
        ]}}), selected["udid"])

    def test_rejects_no_usable_destination_and_invalid_udid(self):
        for document in [
            {}, {"devices": {}}, {"devices": {runtime("14-5"): [device(1)]}},
            {"devices": {runtime("26-0"): [device(1, available="true")]}},
            {"devices": {runtime("26-0"): [device(1, udid="bad\ninjected=output")]}},
        ]:
            with self.subTest(document=document), self.assertRaises(ValueError):
                select_device(document)


class ResultVerificationTests(unittest.TestCase):
    def test_required_suites_have_executed_passed_tests(self):
        self.assertEqual(verify_results(result_tree()), {
            suite: len(cases) for suite, cases in declared_share_cases().items()
        })

    def test_one_passing_case_per_suite_does_not_prove_full_discovery(self):
        # The real Swift files declare more than one case in every suite.
        # The old oracle accepted this partial xcresult as a green run.
        tree = result_tree()
        for suite in tree["testNodes"][0]["children"]:
            suite["children"] = suite["children"][:1]
        with self.assertRaisesRegex(ValueError, "missing"):
            verify_results(tree)

    def test_nested_destination_and_module_qualified_suite_names(self):
        tree = result_tree()
        for suite in tree["testNodes"][0]["children"]:
            suite["name"] = "RunnerTests." + suite["name"]
            del suite["children"][0]["nodeIdentifier"]
        self.assertEqual(verify_results({"testNodes": [{"nodeType": "Destination", "children": tree["testNodes"]}]}), {
            suite: len(cases) for suite, cases in declared_share_cases().items()
        })

    def test_missing_empty_or_skipped_suite_fails_instead_of_false_green(self):
        baseline = result_tree()
        for mutation in ("missing", "empty", "one omitted", "skipped", "failed", "unknown"):
            tree = copy.deepcopy(baseline)
            suites = tree["testNodes"][0]["children"]
            if mutation == "missing":
                suites.pop()
            elif mutation == "empty":
                suites[-1]["children"] = []
            elif mutation == "one omitted":
                suites[-1]["children"].pop()
            else:
                suites[-1]["children"][0]["result"] = mutation.title()
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                verify_results(tree)

    def test_duplicate_unexpected_and_ambiguous_cases_fail(self):
        for mutation in ("duplicate", "unexpected", "ambiguous"):
            tree = result_tree()
            suite = tree["testNodes"][0]["children"][-1]
            if mutation == "duplicate":
                suite["children"].append(copy.deepcopy(suite["children"][0]))
            elif mutation == "unexpected":
                suite["children"].append({
                    "nodeType": "Test Case", "name": "testNotDeclared()", "result": "Passed",
                })
            else:
                suite["children"][0]["name"] = "testOne() testTwo()"
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                verify_results(tree)

    def test_declaration_parser_ignores_comments_strings_and_other_classes(self):
        source = '''
        // func testCommentedOut() {}
        /* outer /* func testNestedComment() {} */ still comment */
        final class OtherTests: XCTestCase { func testOther() {} }
        final class RecipeShareWakeTests: XCTestCase {
          let example = "func testString() {}"
          let multiline = """func testMultilineString() {}"""
          func
            testFirst
            () throws { func testNestedFunction() {} }
          @MainActor func testSecond() async throws {}
        }
        '''
        self.assertEqual(declared_test_methods(source, "RecipeShareWakeTests"), {
            "testFirst", "testSecond",
        })
        for bad in ("class RecipeShareWakeTests: XCTestCase {}",
                    "class RecipeShareWakeTests: XCTestCase { func testA() {} func testA() {} }",
                    "class RecipeShareWakeTests: XCTestCase { func testA(value: Int) {} }",
                    "class RecipeShareWakeTests: XCTestCase { func testA() {} } "
                    "extension RecipeShareWakeTests { func testB() {} }"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                declared_test_methods(bad, "RecipeShareWakeTests")

    def test_malformed_result_schema_fails(self):
        for tree in ({}, {"testNodes": []}, {"testNodes": [None]}, {"testNodes": [{"children": None}]}):
            with self.subTest(tree=tree), self.assertRaises(ValueError):
                verify_results(tree)

    def test_cli_fails_on_invalid_json_and_emits_only_uuid_for_valid_input(self):
        script = Path(__file__).with_name("ios_test_support.py")
        valid = subprocess.run([sys.executable, str(script), "select-device"], input=json.dumps({"devices": {runtime("26-0"): [device(1)]}}), capture_output=True, text=True)
        self.assertEqual(valid.returncode, 0)
        self.assertEqual(valid.stdout.strip(), device(1)["udid"])
        invalid = subprocess.run([sys.executable, str(script), "verify-results"], input="not JSON", capture_output=True, text=True)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertEqual(invalid.stdout, "")


if __name__ == "__main__":
    unittest.main()
