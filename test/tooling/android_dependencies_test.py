"""Exercise Gradle resolution and inventory with synthetic localhost repositories."""
import argparse
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[2]
GRADLE = ROOT / "android" / ("gradlew.bat" if os.name == "nt" else "gradlew")


class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="eatova-gradle-")
        self.project = Path(self.temporary.name)
        self.requests = []
        requests = self.requests
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, "w"):
            pass
        jar = payload.getvalue()

        class Repository(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                requests.append(self.path)
                if self.path.startswith("/broken/"):
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                parts = self.path.split("/")
                if not self.path.startswith("/repo/example/") or "missing" in parts:
                    self.send_error(404)
                    return
                module, version = parts[-3:-1]
                if self.path.endswith(".pom"):
                    transitive = (
                        "<dependencies><dependency><groupId>example</groupId>"
                        "<artifactId>child</artifactId><version>1.0</version>"
                        "</dependency></dependencies>" if module == "parent" else ""
                    )
                    data = (
                        "<project><modelVersion>4.0.0</modelVersion><groupId>example</groupId>"
                        f"<artifactId>{module}</artifactId><version>{version}</version>"
                        f"{transitive}</project>"
                    ).encode()
                elif self.path.endswith(".jar"):
                    data = jar
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(data)

            do_HEAD = do_GET

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Repository)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        (self.project / "settings.gradle").write_text("rootProject.name = 'synthetic'\n")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temporary.cleanup()

    def run_gradle(self, source, task, extra_args=()):
        (self.project / "build.gradle").write_text(source, encoding="utf-8")
        return subprocess.run(
            [str(GRADLE), "-p", str(self.project), task, *extra_args, "--console=plain", "--no-daemon",
             "-Dorg.gradle.internal.http.socketTimeout=1500",
             "-Dorg.gradle.internal.http.connectionTimeout=1500"],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120,
        )

    def repositories(self, first="absent"):
        return "repositories {\n" + "\n".join(
            f"maven {{ url = uri('{self.url}/{path}'); allowInsecureProtocol = true }}"
            for path in [first, "repo"]
        ) + "\n}\n"

    def test_connection_failure_does_not_fall_through_to_another_repository(self):
        result = self.run_gradle(
            self.repositories("broken") + """
configurations { probe }
dependencies { probe 'example:parent:1.0' }
tasks.register('probeResolution') { doLast { configurations.probe.resolve() } }
""", "probeResolution")
        self.assertNotEqual(result.returncode, 0, "Unavailable repository must fail resolution")
        self.assertTrue(any(path.startswith("/broken/") for path in self.requests),
                        result.stdout + result.stderr)
        self.assertFalse(any(path.startswith("/repo/") for path in self.requests),
                         "Gradle silently resolved from a fallback repository after connection failure")

    def inventory(self, dependencies):
        script = (ROOT / "android/dependency_inventory.gradle").as_posix()
        return self.run_gradle(self.repositories() + f"""
configurations {{ releaseRuntimeClasspath; coreLibraryDesugaring }}
dependencies {{ {dependencies} }}
apply from: '{script}'
""", "writeDependencySbom")

    def test_inventory_uses_resolved_versions_transitives_and_desugaring(self):
        result = self.inventory("""
releaseRuntimeClasspath 'example:parent:1.0'
releaseRuntimeClasspath 'example:parent:2.0'
coreLibraryDesugaring 'example:desugar:1.0'
""")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = json.loads((self.project / "build/reports/dependencies/android-release.cdx.json").read_text())
        self.assertEqual(data["bomFormat"], "CycloneDX")
        self.assertEqual({item["purl"] for item in data["components"]}, {
            "pkg:maven/example/parent@2.0", "pkg:maven/example/child@1.0",
            "pkg:maven/example/desugar@1.0",
        })
        self.assertEqual(len(data["components"]), 3)
        self.assertTrue(any(path.startswith("/absent/") for path in self.requests))
        self.assertTrue(any(path.startswith("/repo/") for path in self.requests))

    def test_inventory_rejects_unresolved_dependencies(self):
        result = self.inventory("releaseRuntimeClasspath 'example:missing:1.0'")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot inventory unresolved", result.stdout + result.stderr)

    def test_inventory_rejects_empty_graph(self):
        result = self.inventory("")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("inventory must not be empty", result.stdout + result.stderr)

    def test_build_tool_inventory_rejects_empty_settings_graph(self):
        result = self.run_gradle("", "writeBuildToolSbom", [
            "-I", str(ROOT / "android/build_tool_inventory.init.gradle"),
        ])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build-tool inventory must not be empty", result.stdout + result.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--gradle", type=Path, default=GRADLE)
    args, remaining = parser.parse_known_args()
    GRADLE = args.gradle.resolve()
    unittest.main(argv=[__file__, *remaining])
