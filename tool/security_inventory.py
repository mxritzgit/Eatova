"""Convert public Swift pins and the Gradle wrapper into OSV's custom lockfile."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SWIFT_LOCKS = (
    "ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
)
# Review new origins before sending their coordinates to a public scanner.
PUBLIC_SWIFT_REPOSITORIES = {
    "https://github.com/google/app-check.git",
    "https://github.com/openid/AppAuth-iOS.git",
    "https://github.com/google/GoogleSignIn-iOS.git",
    "https://github.com/google/GoogleUtilities.git",
    "https://github.com/google/gtm-session-fetcher.git",
    "https://github.com/google/GTMAppAuth.git",
    "https://github.com/google/interop-ios-for-google-sdks.git",
    "https://github.com/google/promises.git",
    "https://github.com/getsentry/sentry-cocoa",
}


def swift_packages(path):
    lock = json.loads(path.read_text(encoding="utf-8"))
    if lock.get("version") != 2 or not lock.get("pins"):
        raise ValueError("Expected nonempty Swift lockfile version 2")
    packages = {}
    for pin in lock["pins"]:
        location = pin.get("location", "")
        revision = pin.get("state", {}).get("revision", "")
        if (pin.get("kind") != "remoteSourceControl"
                or location not in PUBLIC_SWIFT_REPOSITORIES):
            raise ValueError("Swift dependency origin needs public-source review")
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise ValueError("Swift dependency needs an exact Git revision")
        if location in packages:
            raise ValueError("Duplicate Swift dependency origin")
        packages[location] = revision
    return packages


def inventory(root):
    swift = [swift_packages(root / path) for path in SWIFT_LOCKS]
    if swift[0] != swift[1]:
        raise ValueError("Workspace and project Swift locks disagree")
    wrapper = (root / "android/gradle/wrapper/gradle-wrapper.properties").read_text()
    versions = re.findall(
        r"^distributionUrl=https\\://services\.gradle\.org/distributions/"
        r"gradle-([0-9]+\.[0-9]+(?:\.[0-9]+)?)-(?:all|bin)\.zip$",
        wrapper, re.MULTILINE,
    )
    if len(versions) != 1:
        raise ValueError("Expected one official stable Gradle distribution")
    packages = [{"package": {"name": url.removeprefix("https://"), "commit": commit}}
                for url, commit in sorted(swift[0].items())]
    packages.append({"package": {
        "name": "org.gradle:gradle-core", "version": versions[0], "ecosystem": "Maven",
    }})
    return {"results": [{"packages": packages}]}


if __name__ == "__main__":
    result = inventory(ROOT)
    output = ROOT / "build/security/osv-scanner-custom.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"Inventoried {len(result['results'][0]['packages'])} public Swift/build dependencies")
