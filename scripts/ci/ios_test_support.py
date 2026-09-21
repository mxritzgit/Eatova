"""Select a simulator and require executed recipe-share XCTest suites in CI."""

import argparse
import json
import re
import sys


SHARE_SUITES = (
    "RecipeShareInboxTests",
    "RecipeShareHandoffTests",
    "RecipeShareWakeTests",
)


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


def verify_results(document: dict) -> dict[str, int]:
    """Read xcresulttool's test tree; fail if a required suite did not pass."""
    counts = dict.fromkeys(SHARE_SUITES, 0)

    def walk(nodes: list, parent_suite: str | None = None) -> None:
        for node in nodes:
            if not isinstance(node, dict):
                raise ValueError("Malformed xcresult test node")
            suite = parent_suite
            if node.get("nodeType") == "Test Suite":
                name = str(node.get("name", "")).rsplit(".", 1)[-1]
                if name in counts:
                    suite = name
            if node.get("nodeType") == "Test Case":
                identifier = str(node.get("nodeIdentifier", ""))
                identifiers = {part.rsplit(".", 1)[-1] for part in identifier.split("/")}
                suite = next((name for name in counts if name in identifiers), suite)
                if suite in counts:
                    if node.get("result") != "Passed":
                        raise ValueError(f"{suite} contains a test that did not pass")
                    counts[suite] += 1
            children = node.get("children", [])
            if not isinstance(children, list):
                raise ValueError("Malformed xcresult child nodes")
            walk(children, suite)

    nodes = document.get("testNodes")
    if not isinstance(nodes, list):
        raise ValueError("xcresult output has no testNodes list")
    walk(nodes)
    missing = [suite for suite, count in counts.items() if count == 0]
    if missing:
        raise ValueError("No executed tests found for: " + ", ".join(missing))
    return counts


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
