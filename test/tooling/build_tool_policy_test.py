"""Exercise the build-tool exposure policy before any Gradle task executes."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
GRADLE = ROOT / "android" / ("gradlew.bat" if os.name == "nt" else "gradlew")
POLICY = ROOT / "android/build_tool_policy.gradle"


class BuildToolPolicyTests(unittest.TestCase):
    def run_build(self, *, property_value=None, source="", arguments=()):
        with tempfile.TemporaryDirectory(prefix="eatova-build-policy-") as temporary:
            project = Path(temporary)
            (project / "settings.gradle").write_text(
                "rootProject.name = 'synthetic'\ninclude ':child'\n", encoding="utf-8")
            (project / "child").mkdir()
            (project / "build.gradle").write_text(
                f"apply from: '{POLICY.as_posix()}'\n" + source + "\n"
                "tasks.register('probe') { doLast { file('executed').text = 'yes' } }\n",
                encoding="utf-8")
            if property_value is not None:
                (project / "gradle.properties").write_text(
                    f"android.enableJetifier={property_value}\n", encoding="utf-8")
            result = subprocess.run(
                [str(GRADLE), "-p", str(project), "probe", "--console=plain", "--offline",
                 "--max-workers=1", *arguments],
                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)
            return result, (project / "executed").exists()

    def assert_blocked(self, result, executed, reason):
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn(reason, output)
        self.assertFalse(executed, "Rejected build executed a task before validation")

    def test_default_and_explicit_false_allow_normal_build(self):
        for value in (None, "false"):
            with self.subTest(value=value):
                result, executed = self.run_build(property_value=value)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(executed)

    def test_jetifier_enabled_and_unknown_value_fail_before_execution(self):
        for value in ("true", "invalid"):
            with self.subTest(value=value):
                self.assert_blocked(*self.run_build(property_value=value), "Jetifier")

    def test_command_line_override_cannot_reenable_jetifier(self):
        self.assert_blocked(*self.run_build(
            property_value="false", arguments=("-Pandroid.enableJetifier=true",)), "Jetifier")

    def test_subproject_extra_does_not_override_agp_build_option(self):
        result, executed = self.run_build(property_value="false", source="""
project(':child') { ext.set('android.enableJetifier', 'true') }
assert project(':child').providers.gradleProperty('android.enableJetifier').get() == 'false'
""")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(executed)

    def test_system_property_override_cannot_reenable_jetifier(self):
        self.assert_blocked(*self.run_build(property_value="false", arguments=(
            "-Dorg.gradle.project.android.enableJetifier=true",)), "Jetifier")

    def test_unselected_lazy_kapt_task_requires_review(self):
        self.assert_blocked(*self.run_build(
            source="project(':child') { tasks.register('kaptDebugKotlin') }"), "KAPT")

    def test_kapt_registered_after_project_evaluation_requires_review(self):
        self.assert_blocked(*self.run_build(source="""
gradle.projectsEvaluated {
    project(':child').tasks.register('kaptDebugKotlin')
}
"""), "KAPT")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--gradle", type=Path, default=GRADLE)
    parser.add_argument("--policy", type=Path, default=POLICY)
    options, remaining = parser.parse_known_args()
    GRADLE = options.gradle.resolve()
    POLICY = options.policy.resolve()
    unittest.main(argv=[__file__, *remaining])
