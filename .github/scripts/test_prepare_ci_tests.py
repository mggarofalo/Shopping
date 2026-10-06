"""Exercise orchestration with fake tools; never use a simulator or compiler."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("prepare", Path(__file__).with_name("prepare-ci-tests.py"))
prepare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prepare)

FAKE = '''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
import time
if Path(sys.argv[0]).name == "xcodebuild":
    Path("build-started").touch()
    Path("build-args.json").write_text(__import__("json").dumps(sys.argv[1:]))
    for _ in range(200):
        if Path("boot-started").exists():
            break
        time.sleep(.01)
    else:
        sys.exit(99)
    sys.exit(int(os.environ.get("BUILD_EXIT", "0")))
if sys.argv[2] == "boot":
    Path("boot-started").touch()
    sys.exit(int(os.environ.get("BOOT_EXIT", "0")))
if sys.argv[2] == "bootstatus":
    if os.environ.get("HANG_BOOT"):
        time.sleep(60)
    for _ in range(200):
        if Path("build-started").exists():
            break
        time.sleep(.01)
    else:
        sys.exit(98)
if sys.argv[2] == "spawn":
    Path("keyboard-ready").touch()
'''


class PreparationTests(unittest.TestCase):
    def run_preparation(self, settings=None, timeout=5):
        with tempfile.TemporaryDirectory() as directory:
            original = Path.cwd()
            try:
                os.chdir(directory)
                for name in ("xcrun", "xcodebuild"):
                    path = Path(name)
                    path.write_text(FAKE)
                    path.chmod(0o755)
                env = {"PATH": directory + os.pathsep + os.environ["PATH"], **(settings or {})}
                with patch.dict(os.environ, env):
                    code = prepare.prepare("test-udid", boot_timeout=timeout)
                phases = [json.loads(line) for line in Path("FastPhases.jsonl").read_text().splitlines()]
                args = json.loads(Path("build-args.json").read_text())
                return code, phases, args, Path("keyboard-ready").exists()
            finally:
                os.chdir(original)

    def test_overlaps_both_branches_and_preserves_single_shared_build(self):
        code, phases, args, keyboard = self.run_preparation()
        self.assertEqual(code, 0)
        self.assertTrue(keyboard)
        self.assertEqual([p["phase"] for p in phases], ["simulator", "build"])
        self.assertTrue(all(p["exit_code"] == 0 for p in phases))
        self.assertEqual(args, ["build-for-testing", "-project", "Shopping.xcodeproj",
                               "-scheme", "Shopping", "-testPlan", "ShoppingAcceptance",
                               "-destination", "platform=iOS Simulator,id=test-udid",
                               "-derivedDataPath", "DerivedData", "-quiet"])

    def test_build_failure_is_preserved(self):
        code, phases, _, _ = self.run_preparation({"BUILD_EXIT": "42"})
        self.assertEqual(code, 42)
        self.assertEqual(phases[1]["exit_code"], 42)

    def test_boot_failure_prevents_success_and_records_both_phases(self):
        code, phases, _, keyboard = self.run_preparation({"BOOT_EXIT": "43"})
        self.assertEqual(code, 43)
        self.assertEqual(phases[0]["exit_code"], 43)
        self.assertFalse(keyboard)
        self.assertEqual(len(phases), 2)

    def test_boot_timeout_prevents_success_and_retains_failure_timing(self):
        code, phases, _, keyboard = self.run_preparation({"HANG_BOOT": "1"}, timeout=.5)
        self.assertEqual(code, 124)
        self.assertNotEqual(phases[0]["exit_code"], 0)
        self.assertFalse(keyboard)
        self.assertEqual(len(phases), 2)


if __name__ == "__main__":
    unittest.main()
