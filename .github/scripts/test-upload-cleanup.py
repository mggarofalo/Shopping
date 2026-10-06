#!/usr/bin/env python3
"""Exercise the real upload shell through archive failures with fake signing tools."""
import base64
import importlib.util
import json
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
    def scenario(self, collision=False, failure="archive"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); scripts = root / "scripts"; scripts.mkdir()
            tools = root / "bin"; tools.mkdir()
            home = root / "home"; profiles = home / "Library/Developer/Xcode/UserData/Provisioning Profiles"; profiles.mkdir(parents=True)
            for filename in ["upload-testflight.sh", "validate-release-profiles.py", "release-evidence.py"]:
                shutil.copy(ROOT / filename, scripts / filename)
            (scripts / "validate-release-source.sh").write_text("exit 0\n")
            (scripts / "require-release-ci.py").write_text("pass\n")
            for name in ("validate-cloudkit-sharing.py", "validate-release-identity.py"):
                (scripts / name).write_text("pass\n")
            (scripts / "preflight-testflight.rb").write_text("exit 0\n")
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
stage=archive
[[ "$1" == -exportArchive ]] && stage=export
if [[ "$stage" == archive ]]; then printf '%s\\n' "$@" > "$FIXTURE_ROOT/archive-args"; fi
if [[ "$FAILURE" == "$stage" ]]; then echo 'error: canary-secret'; exit 9; fi
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -archivePath) archive="$2"; shift;;
        -exportPath) destination="$2"; shift;;
    esac
    shift
done
if [[ "$stage" == archive ]]; then
    mkdir -p "$archive/dSYMs/Shopping.app.dSYM/Contents/Resources/DWARF"
    echo symbols > "$archive/dSYMs/Shopping.app.dSYM/Contents/Resources/DWARF/Shopping"
    echo forbidden-profile > "$archive/embedded.mobileprovision"
else
    mkdir -p "$destination"
    echo fake-ipa > "$destination/Shopping.ipa"
fi
''')
            (tools / "xcrun").write_text('''#!/bin/bash
if [[ "$2" == --upload-app ]]; then
    echo upload-called > "$FIXTURE_ROOT/upload-called"
    [[ "$FAILURE" != upload ]] || exit 23
fi
exit 0
''')
            for tool in tools.iterdir(): tool.chmod(0o755)
            env = dict(os.environ, HOME=str(home), RUNNER_TEMP=str(root), FIXTURE_ROOT=str(root), PATH=f"{tools}:{os.environ['PATH']}", BUILD_NUMBER="28", MARKETING_VERSION="1.4.0", RELEASE_EVIDENCE_DIR=str(root / "evidence"), FAILURE=failure)
            for key, value in {"APP_STORE_CONNECT_API_ISSUER_ID":"fixture", "APP_STORE_CONNECT_API_KEY_ID":"fixture", "APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD":"fixture", "APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64":"fixture", "APPLE_DISTRIBUTION_CERTIFICATE_BASE64":"fixture", "APP_STORE_PROVISIONING_PROFILE_BASE64":"iphone", "APP_STORE_WATCH_PROVISIONING_PROFILE_BASE64":"watch"}.items():
                env[key] = base64.b64encode(value.encode()).decode() if key.endswith("BASE64") else value
            result = subprocess.run(["bash", str(scripts / "upload-testflight.sh")], env=env, capture_output=True, text=True)
            expected_code = 1 if collision else 9 if failure in ("archive", "export") else 23 if failure == "upload" else 0
            self.assertEqual(result.returncode, expected_code, result.stdout + result.stderr)
            self.assertEqual(existing.read_bytes(), b"collision" if collision else b"iphone")
            self.assertFalse((profiles / (pair["watch"]["UUID"] + ".mobileprovision")).exists())
            self.assertFalse(list(root.glob("shopping-testflight.*")))
            self.assertTrue((root / "deleted").exists())
            self.assertEqual((root / "upload-called").exists(), not collision and failure in ("upload", "none"))
            evidence_files = list((root / "evidence").rglob("*"))
            for file in evidence_files:
                if file.is_file():
                    self.assertNotIn("canary-secret", file.read_text())
                    self.assertNotIn("forbidden-profile", file.read_text())
                    self.assertNotIn("fake-ipa", file.read_text())
            if collision:
                self.assertFalse((root / "archive-args").exists())
                self.assertIn("Refusing to replace", result.stderr)
            else:
                evidence = json.loads((root / "evidence" / "manifest.json").read_text())
                self.assertEqual(evidence["archive"], "failed" if failure == "archive" else "succeeded")
                self.assertEqual(evidence["upload_script_exit_code"], expected_code)
                self.assertTrue((root / "evidence" / "archive.log").exists())
                self.assertEqual((root / "evidence" / "dSYMs").exists(), failure != "archive")
                self.assertEqual(evidence["upload"], "unconfirmed" if failure == "upload" else "succeeded" if failure == "none" else "not_attempted")
                args = (root / "archive-args").read_text()
                self.assertIn("SHOPPING_IPHONE_PROFILE_UUID=" + pair["iphone"]["UUID"], args)
                self.assertIn("SHOPPING_WATCH_PROFILE_UUID=" + pair["watch"]["UUID"], args)
                self.assertNotIn("PROVISIONING_PROFILE_SPECIFIER=", args)
                self.assertEqual((root / "search-list").read_text().splitlines()[-1], "/original/login.keychain-db")
    def test_archive_failure_restores_keychain_and_preserves_preexisting_profile(self): self.scenario()
    def test_conflicting_profile_is_never_overwritten(self): self.scenario(collision=True)
    def test_export_failure_preserves_symbols_and_cleans_credentials(self): self.scenario(failure="export")
    def test_upload_failure_preserves_symbols_and_cleans_credentials(self): self.scenario(failure="upload")
    def test_success_preserves_symbols_and_cleans_credentials(self): self.scenario(failure="none")

if __name__ == "__main__": unittest.main()
