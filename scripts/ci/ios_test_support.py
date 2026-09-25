"""Select a simulator and require every declared recipe-share XCTest in CI."""

import argparse
import json
from pathlib import Path
import re
import sys


SHARE_SUITES = (
    "RecipeShareInboxTests",
    "RecipeShareHandoffTests",
    "RecipeShareWakeTests",
)
ROOT = Path(__file__).resolve().parents[2]


def _swift_code(source: str) -> str:
    """Mask comments and strings while preserving braces and line positions."""
    out = list(source)
    index = 0
    while index < len(source):
        start = index
        if source.startswith("//", index):
            end = source.find("\n", index)
            index = len(source) if end < 0 else end
        elif source.startswith("/*", index):
            depth = 1
            index += 2
            while index < len(source) and depth:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            if depth:
                raise ValueError("Unclosed Swift block comment")
        elif source.startswith('"""', index):
            index += 3
            while index < len(source) and not source.startswith('"""', index):
                index += 2 if source[index] == "\\" else 1
            if index >= len(source):
                raise ValueError("Unclosed Swift multiline string")
            index += 3
        elif source[index] == '"':
            index += 1
            while index < len(source) and source[index] != '"':
                index += 2 if source[index] == "\\" else 1
            if index >= len(source):
                raise ValueError("Unclosed Swift string")
            index += 1
        else:
            index += 1
            continue
        for position in range(start, min(index, len(source))):
            if out[position] != "\n":
                out[position] = " "
    return "".join(out)


def declared_test_methods(source: str, suite: str) -> set[str]:
    """Read zero-argument tests in one class; reject unsupported extensions/forms."""
    code = _swift_code(source)
    if re.search(rf"\bextension\s+{re.escape(suite)}\b", code):
        raise ValueError(f"{suite} XCTest extension needs discovery parser review")
    classes = [match for match in re.finditer(
        r"\bclass\s+([A-Za-z_]\w*)\s*:\s*XCTestCase\s*\{", code
    ) if match[1] == suite]
    if len(classes) != 1:
        raise ValueError(f"Expected one {suite} XCTestCase class")
    start = classes[0].end()
    depth = 1
    end = start
    while end < len(code) and depth:
        if code[end] == "{":
            depth += 1
        elif code[end] == "}":
            depth -= 1
        end += 1
    if depth:
        raise ValueError(f"Unclosed {suite} XCTestCase class")
    body = code[start:end - 1]
    methods = []
    for match in re.finditer(r"\bfunc\s+(test[A-Za-z0-9_]+)\b", body):
        if body[:match.start()].count("{") != body[:match.start()].count("}"):
            continue
        if not re.match(r"\s*\(\s*\)", body[match.end():]):
            raise ValueError(f"{suite} has an unsupported XCTest method declaration")
        methods.append(match[1])
    if not methods or len(methods) != len(set(methods)):
        raise ValueError(f"{suite} has no unique XCTest methods")
    return set(methods)


def declared_share_cases(root: Path = ROOT) -> dict[str, set[str]]:
    return {
        suite: declared_test_methods(
            (root / "ios" / "RunnerTests" / f"{suite}.swift").read_text(encoding="utf-8"),
            suite,
        ) for suite in SHARE_SUITES
    }


def select_device(document: dict) -> str:
    """Prefer the newest available iOS runtime, then an already booted iPhone."""
    devices = document.get("devices")
    if not isinstance(devices, dict):
        raise ValueError("simctl output has no devices map")
    candidates = []
    for runtime, entries in devices.items():
        match = re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+(?:-\d+)*)", runtime)
        if not match or not isinstance(entries, list):
            continue
        version = tuple(int(part) for part in match[1].split("-"))
        if version[0] < 15:
            continue
        for device in entries:
            if not isinstance(device, dict) or device.get("isAvailable") is not True:
                continue
            name, udid = device.get("name"), device.get("udid")
            device_type = device.get("deviceTypeIdentifier", "")
            is_iphone = (
                device_type.startswith("com.apple.CoreSimulator.SimDeviceType.iPhone-")
                if isinstance(device_type, str) and device_type
                else isinstance(name, str) and name.startswith("iPhone ")
            )
            if not is_iphone or not isinstance(udid, str) or not re.fullmatch(
                r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", udid
            ):
                continue
            candidates.append((version, device.get("state") == "Booted", udid))
    if not candidates:
        raise ValueError("No available iPhone simulator with iOS 15 or newer")
    return max(candidates)[2]


def verify_results(
    document: dict, expected_cases: dict[str, set[str]] | None = None
) -> dict[str, int]:
    """Require every declared share XCTest to appear once and pass."""
    expected = expected_cases if expected_cases is not None else declared_share_cases()
    seen = {suite: set() for suite in SHARE_SUITES}

    def walk(nodes: list, parent_suite: str | None = None) -> None:
        for node in nodes:
            if not isinstance(node, dict):
                raise ValueError("Malformed xcresult test node")
            suite = parent_suite
            if node.get("nodeType") == "Test Suite":
                name = str(node.get("name", "")).rsplit(".", 1)[-1]
                if name in seen:
                    suite = name
            if node.get("nodeType") == "Test Case":
                identifier = str(node.get("nodeIdentifier", ""))
                identifiers = {part.rsplit(".", 1)[-1] for part in identifier.split("/")}
                named_suites = [name for name in seen if name in identifiers]
                if len(named_suites) > 1 or (named_suites and suite in seen and named_suites[0] != suite):
                    raise ValueError("Ambiguous share XCTest suite")
                suite = named_suites[0] if named_suites else suite
                if suite in seen:
                    names = set(re.findall(
                        r"\btest[A-Za-z0-9_]+\b", identifier + " " + str(node.get("name", ""))
                    ))
                    if len(names) != 1:
                        raise ValueError(f"{suite} has an ambiguous XCTest case name")
                    case = names.pop()
                    if case not in expected[suite] or case in seen[suite]:
                        raise ValueError(f"{suite} has an unexpected or duplicate XCTest case: {case}")
                    if node.get("result") != "Passed":
                        raise ValueError(f"{suite} contains a test that did not pass")
                    seen[suite].add(case)
            children = node.get("children", [])
            if not isinstance(children, list):
                raise ValueError("Malformed xcresult child nodes")
            walk(children, suite)

    nodes = document.get("testNodes")
    if not isinstance(nodes, list):
        raise ValueError("xcresult output has no testNodes list")
    walk(nodes)
    missing = [
        f"{suite}: {', '.join(sorted(expected[suite] - seen[suite]))}"
        for suite in SHARE_SUITES if expected[suite] - seen[suite]
    ]
    if missing:
        raise ValueError("Declared share XCTest cases missing from xcresult: " + "; ".join(missing))
    return {suite: len(cases) for suite, cases in seen.items()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("select-device", "verify-results"))
    args = parser.parse_args()
    try:
        document = json.load(sys.stdin)
        if not isinstance(document, dict):
            raise ValueError("Expected a JSON object")
        if args.command == "select-device":
            print(select_device(document))
        else:
            print(json.dumps(verify_results(document), sort_keys=True))
        return 0
    except (ValueError, TypeError) as error:
        print(f"iOS test verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
