"""Protect evidence retention and bounded reporting when hosted Full stops early."""
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ExhaustiveContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = json.loads(subprocess.check_output([
            "ruby", "-rjson", "-ryaml", "-e",
            "puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true))",
            str(ROOT / ".github/workflows/swift-exhaustive.yml")]))
        cls.job = cls.workflow["jobs"]["exhaustive"]
        cls.steps = cls.job["steps"]
        cls.named = {s.get("name"): s for s in cls.steps}

    def test_all_steps_fit_job_with_orchestration_headroom(self):
        self.assertEqual(self.job["timeout-minutes"], 90)
        limits = [s["timeout-minutes"] for s in self.steps]
        self.assertTrue(all(isinstance(n, int) and n > 0 for n in limits))
        self.assertLessEqual(sum(limits), self.job["timeout-minutes"] - 3)
        self.assertEqual(self.named["Run exhaustive tests"]["timeout-minutes"], 60)

    def test_logs_and_incomplete_bundle_survive_before_any_result_reader(self):
        logs = self.named["Upload exhaustive raw logs"]
        bundle = self.named["Upload exhaustive raw results"]
        # Unconditional status expression handles success, failure and cancellation;
        # a valid/complete bundle must never be required to retain raw evidence.
        for step in (logs, bundle):
            self.assertEqual(step["if"], "always()")
            self.assertNotIn("continue-on-error", step)
            self.assertEqual(step["with"]["retention-days"], 14)
        self.assertLess(self.steps.index(logs), self.steps.index(bundle))
        for name in ("Export full-plan coverage", "Publish exhaustive test summary",
                     "Publish exhaustive timing report"):
            self.assertLess(self.steps.index(bundle), self.steps.index(self.named[name]))
            self.assertLessEqual(self.named[name]["timeout-minutes"], 1)
        self.assertIn("ExhaustiveTest.log", logs["with"]["path"])
        self.assertIn("ExhaustiveBuild.log", logs["with"]["path"])
        self.assertEqual(bundle["with"]["path"], "ExhaustiveResults.xcresult")
        self.assertEqual(bundle["with"]["compression-level"], 0)

    def test_test_progress_and_original_full_proof_are_preserved(self):
        command = self.named["Run exhaustive tests"]["run"]
        self.assertIn("test-without-building", command)
        self.assertIn('-testPlan "$TEST_PLAN"', command)
        self.assertIn("--log ExhaustiveTest.log", command)
        for forbidden in ("-quiet", "-only-testing", "-skip-testing", "-retry", "|| true",
                          "-parallel-testing-worker-count"):
            self.assertNotIn(forbidden, command)
        self.assertEqual(self.job["needs"], "preflight")
        preflight = self.workflow["jobs"]["preflight"]["steps"][-1]
        self.assertIn('"$GITHUB_SHA"', preflight["run"])
        self.assertIn("verify-shopping-full-attestation.sh", preflight["run"])
        coverage = self.named["Export full-plan coverage"]["run"]
        self.assertIn(".github/coverage-baseline.json", coverage)
        self.assertIn('exit "$exit_code"', coverage)
        self.assertTrue(all(not s.get("continue-on-error", False) for s in self.steps))


if __name__ == "__main__":
    unittest.main()
