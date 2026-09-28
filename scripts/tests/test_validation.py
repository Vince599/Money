"""Portable validation-scope and result-gate checks; does not invoke Apple tools."""
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
BASH = str(Path(shutil.which("git")).parent.parent / "bin" / "bash.exe") if os.name == "nt" else shutil.which("bash")
validate = runpy.run_path(str(ROOT / "scripts/check-test-summary.py"))["validate"]


class ValidationScopeTests(unittest.TestCase):
    def plan(self, scope=None, suite=None, ipa=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("LEDGER_")}
        for key, value in [("LEDGER_VALIDATION_SCOPE", scope), ("LEDGER_UI_SUITE", suite), ("LEDGER_PACKAGE_IPA", ipa)]:
            if value is not None:
                env[key] = value
        return subprocess.run([BASH, "-c", '''set -eu
source scripts/validation-scope.sh
configure_validation_scope
printf '%s\n' "$VALIDATION_SCOPE" "$PACKAGE_IPA" "$RUN_PACKAGE_TESTS" "$RUN_UI_TESTS" "$SIMULATOR_ACTION" "${SIMULATOR_TEST_ARGS[@]}"
'''], cwd=ROOT, env=env, capture_output=True, text=True, check=False)

    def test_default_runs_business_without_ui_or_packaging(self):
        result = self.plan()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[:5], ["business", "false", "true", "false", "test"])
        self.assertIn("-only-testing:LedgerAppTests", result.stdout)

    def test_compile_does_not_execute_tests(self):
        result = self.plan("compile")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[:5], ["compile", "false", "false", "false", "build-for-testing"])

    def test_ui_selections_resolve_to_real_tests(self):
        source = (ROOT / "AppUITests/LedgerUITests.swift").read_text(encoding="utf-8")
        for suite in ["calculator", "imports", "refunds", "categories", "tags", "accounts", "entries"]:
            with self.subTest(suite=suite):
                result = self.plan("ui", suite)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines()[:5], ["ui", "false", "false", "true", "test"])
                method = result.stdout.splitlines()[-1].split("/")[-1]
                self.assertIn(f"func {method}()", source)
        result = self.plan("ui", "all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-only-testing:LedgerUITests\n", result.stdout)

    def test_full_cannot_be_narrowed_by_ui_selection(self):
        result = self.plan("full", "calculator", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[:5], ["full", "true", "true", "true", "test"])
        self.assertNotIn("only-testing", result.stdout)
        self.assertEqual(self.plan("full").stdout.splitlines()[1], "false")

    def test_partial_scopes_reject_packaging_and_invalid_inputs(self):
        for scope in ["compile", "business", "ui", "calculator"]:
            with self.subTest(scope=scope):
                self.assertNotEqual(self.plan(scope, ipa="true").returncode, 0)
        for args in [("bogus", None, None), ("full", "bogus", None), ("full", None, "1")]:
            self.assertNotEqual(self.plan(*args).returncode, 0)

    def test_previous_calculator_scope_remains_a_targeted_alias(self):
        result = self.plan("calculator")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], "ui")
        self.assertIn("/testCalculatorCopyAndSearchFilters", result.stdout)


class TestResultGateTests(unittest.TestCase):
    def summary(self, **updates):
        result = dict(result="Passed", totalTestCount=7, passedTests=7, failedTests=0, skippedTests=0, expectedFailures=0)
        result.update(updates)
        return result

    def test_pass_accepts_single_target_or_full_run(self):
        validate(self.summary())
        validate(self.summary(totalTestCount=1, passedTests=1))

    def test_empty_failed_skipped_and_malformed_results_are_rejected(self):
        for summary in [self.summary(totalTestCount=0, passedTests=0), self.summary(result="Failed"),
                        self.summary(passedTests=6, failedTests=1), self.summary(passedTests=6, skippedTests=1),
                        self.summary(expectedFailures=1), self.summary(totalTestCount=True),
                        self.summary(passedTests="7"), {}]:
            with self.subTest(summary=summary), self.assertRaises(ValueError):
                validate(summary)


if __name__ == "__main__":
    unittest.main()
