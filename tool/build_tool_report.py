"""Report build-tool advisories without confusing findings with scanner failures."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/security/build-tools"


def summarize(returncode, inventory, report):
    expected = {(item["group"] + ":" + item["name"], item["version"])
                for item in inventory["components"]}
    if not expected:
        raise ValueError("Build-tool inventory is empty")
    if returncode not in (0, 1):
        raise ValueError(f"Build-tool scanner failed (exit {returncode})")
    packages = [package for result in report["results"] for package in result["packages"]]
    actual = {(item["package"]["name"], item["package"]["version"]) for item in packages}
    if actual != expected:
        raise ValueError("Build-tool scanner did not report the complete inventory")
    findings = sorted({(item["package"]["name"], item["package"]["version"], vuln["id"])
                       for item in packages for vuln in item.get("vulnerabilities", [])})
    if bool(findings) != (returncode == 1):
        raise ValueError("Build-tool scanner status contradicts its advisory report")
    return expected, findings


def main(scanner):
    inventory_path = OUTPUT / "android-build-tools.cdx.json"
    report_path = OUTPUT / "osv-build-tools.json"
    inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    # Do not accept a stale result if the scanner cannot start or write output.
    report_path.unlink(missing_ok=True)
    result = subprocess.run([
        str(scanner), "scan", "source", "--no-ignore", f"--lockfile={inventory_path}",
        "--all-packages", "--format=json", f"--output-file={report_path}",
    ], check=False, timeout=300)
    packages, findings = summarize(
        result.returncode, inventory, json.loads(report_path.read_text(encoding="utf-8")))
    heading = (f"{len(findings)} build-tool package/advisory matches across {len(packages)} components. "
               "These are separate from the strictly gated app-runtime scan.")
    if findings:
        print(f"::warning::{heading} See the build-tool-security artifact and android/BUILD_TOOL_SECURITY.md.")
    else:
        print(f"No currently indexed build-tool advisory matches across {len(packages)} components.")
    revision = os.environ.get("GITHUB_SHA", "main")
    if not re.fullmatch(r"(?:[0-9a-f]{40}|main)", revision):
        raise ValueError("Invalid CI revision for the triage link")
    triage = f"https://github.com/mxritzgit/Eatova/blob/{revision}/android/BUILD_TOOL_SECURITY.md"
    lines = ["# Android build-tool advisory report", "", heading, "",
             f"Review [the dated reachability triage]({triage}); a snapshot is included in this artifact. "
             "Zero matches does not establish complete vulnerability coverage.", "",
             "| Package | Version | Advisory |", "| --- | --- | --- |"]
    lines += [f"| {name} | {version} | [{advisory}](https://osv.dev/vulnerability/{advisory}) |"
              for name, version, advisory in findings]
    (OUTPUT / "advisories.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (OUTPUT / "BUILD_TOOL_SECURITY.md").write_text(
        (ROOT / "android/BUILD_TOOL_SECURITY.md").read_text(encoding="utf-8"), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--scanner", type=Path, required=True)
    main(parser.parse_args().scanner.resolve())
