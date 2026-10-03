#!/usr/bin/env python3
"""Exercise the real upload shell through archive failures with fake signing tools."""
import base64
import importlib.util
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location("guards", ROOT / "test-release-guards.py")
guards = importlib.util.module_from_spec(spec); spec.loader.exec_module(guards)

class CleanupTests(unittest.TestCase):
    def scenario(self, collision=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); scripts = root / "scripts"; scripts.mkdir()
            tools = root / "bin"; tools.mkdir()
            home = root / "home"; profiles = home / "Library/Developer/Xcode/UserData/Provisioning Profiles"; profiles.mkdir(parents=True)
            for filename in ["upload-testflight.sh", "validate-release-profiles.py"]:
                shutil.copy(ROOT / filename, scripts / filename)
            (scripts / "validate-release-source.sh").write_text("exit 0\n")
            (scripts / "require-release-ci.py").write_text("pass\n")
            pair = {target: guards.profile(bundle, f"00000000-0000-0000-0000-00000000000{index}") for index, (target, bundle) in enumerate(guards.profiles.TARGETS.items())}
            for target, value in pair.items():
                with (root / f"{target}.plist").open("wb") as file: plistlib.dump(value, file)
            existing = profiles / (pair["iphone"]["UUID"] + ".mobileprovision")
            existing.write_bytes(b"collision" if collision else b"iphone")
            (tools / "security").write_text('''#!/bin/bash
case "$1" in
 cms) file="${@: -1}"; target=$(basename "$file" .mobileprovision); cat "$FIXTURE_ROOT/$target.plist";;
 find-identity) echo '1) ''' + guards.FINGERPRINT + ''' "Apple Distribution: Fixture (649367BDD4)"';;
 list-keychains) if [[ "$4" != -s ]]; then echo '    "/original/login.keychain-db"'; else printf '%s\\n' "${@:5}" >> "$FIXTURE_ROOT/search-list"; fi;;
 delete-keychain) echo deleted >> "$FIXTURE_ROOT/deleted";;
esac
''')
            (tools / "xcodebuild").write_text('''#!/bin/bash
printf '%s\\n' "$@" > "$FIXTURE_ROOT/archive-args"
exit 9
''')
            (tools / "xcrun").write_text('''#!/bin/bash
echo forbidden-upload > "$FIXTURE_ROOT/upload-called"
exit 99
''')
            for tool in tools.iterdir(): tool.chmod(0o755)
            env = dict(os.environ, HOME=str(home), RUNNER_TEMP=str(root), FIXTURE_ROOT=str(root), PATH=f"{tools}:{os.environ['PATH']}", BUILD_NUMBER="28", MARKETING_VERSION="1.4.0")
            for key, value in {"APP_STORE_CONNECT_API_ISSUER_ID":"fixture", "APP_STORE_CONNECT_API_KEY_ID":"fixture", "APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD":"fixture", "APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64":"fixture", "APPLE_DISTRIBUTION_CERTIFICATE_BASE64":"fixture", "APP_STORE_PROVISIONING_PROFILE_BASE64":"iphone", "APP_STORE_WATCH_PROVISIONING_PROFILE_BASE64":"watch"}.items():
                env[key] = base64.b64encode(value.encode()).decode() if key.endswith("BASE64") else value
            result = subprocess.run(["bash", str(scripts / "upload-testflight.sh")], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(existing.read_bytes(), b"collision" if collision else b"iphone")
            self.assertFalse((profiles / (pair["watch"]["UUID"] + ".mobileprovision")).exists())
            self.assertFalse(list(root.glob("shopping-testflight.*")))
            self.assertTrue((root / "deleted").exists())
            self.assertFalse((root / "upload-called").exists())
            if collision:
                self.assertFalse((root / "archive-args").exists())
                self.assertIn("Refusing to replace", result.stderr)
            else:
                args = (root / "archive-args").read_text()
                self.assertIn("SHOPPING_IPHONE_PROFILE_UUID=" + pair["iphone"]["UUID"], args)
                self.assertIn("SHOPPING_WATCH_PROFILE_UUID=" + pair["watch"]["UUID"], args)
                self.assertNotIn("PROVISIONING_PROFILE_SPECIFIER=", args)
                self.assertEqual((root / "search-list").read_text().splitlines()[-1], "/original/login.keychain-db")
    def test_archive_failure_restores_keychain_and_preserves_preexisting_profile(self): self.scenario()
    def test_conflicting_profile_is_never_overwritten(self): self.scenario(collision=True)

if __name__ == "__main__": unittest.main()
