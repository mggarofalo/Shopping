#!/usr/bin/env python3
"""Evidence/secret boundaries without signing, Apple requests or a simulator."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("evidence", Path(__file__).with_name("release-evidence.py"))
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / "evidence"
        self.env = patch.dict(os.environ, {
            "RELEASE_EVIDENCE_DIR": str(self.output), "GITHUB_SHA": "a" * 40,
            "GITHUB_STEP_SUMMARY": str(self.root / "summary"),
            "RELEASE_VERSION": "1.4.0", "RELEASE_BUILD": "28",
            "UPLOAD_OUTCOME": "success", "INTERNAL_OUTCOME": "success",
            "EXTERNAL_OUTCOME": "success", "EXTERNAL_AVAILABLE": "false",
            "RELEASE_MODE": "upload",
        })
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_diagnostics_exclude_arbitrary_and_multiline_credentials(self):
        secret = "-----BEGIN PRIVATE KEY-----\ncanary-private-key\n-----END PRIVATE KEY-----"
        for stage in ("archive", "export", "upload"):
            raw = self.root / f"{stage}-raw"
            code = evidence.run(stage, raw, [sys.executable, "-c",
                "import sys; print(sys.argv[1]); print('error: ' + sys.argv[1]); sys.exit(19)", secret])
            self.assertEqual(code, 19)
            self.assertIn(secret, raw.read_text())
            log = (self.output / f"{stage}.log").read_text()
            self.assertNotIn("canary", log)
            self.assertNotIn("PRIVATE KEY", log)
            self.assertEqual(json.loads(log)["diagnostic_counts"]["compiler_error"], 0)
        self.assertEqual(evidence.manifest()["upload"], "unconfirmed")

    def test_useful_failure_reason_survives_secret_redaction(self):
        private_key = "decoded-private-key-canary"
        secret = "password-canary"
        profile = "profile-canary"
        message = ("error: Missing required module ShoppingDomain; password=" + secret +
                   "; signing " + private_key + "; profile " + profile)
        with patch.dict(os.environ, APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD=secret,
                        APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64=base64.b64encode(private_key.encode()).decode()):
            code = evidence.run("archive", self.root / "raw", [sys.executable, "-c",
                "import sys; print(sys.argv[1]); sys.exit(7)", message, "SHOPPING_IPHONE_PROFILE_UUID=" + profile])
        self.assertEqual(code, 7)
        log = (self.output / "archive.log").read_text()
        self.assertIn("Missing required module ShoppingDomain", log)
        for value in (secret, private_key, profile):
            self.assertNotIn(value, log)

    def test_evidence_failure_preserves_command_failure_but_fails_success(self):
        original = evidence.write_manifest
        for command_code in (0, 17):
            calls = 0
            def write(data):
                nonlocal calls
                calls += 1
                if calls > 1:
                    raise OSError("fake evidence failure")
                original(data)
            with patch.object(evidence, "write_manifest", side_effect=write):
                code = evidence.run("export", self.root / "raw", [sys.executable, "-c", f"raise SystemExit({command_code})"])
            self.assertEqual(code, command_code or 1)

    def test_diagnostic_text_is_bounded(self):
        evidence.run("export", self.root / "raw", [sys.executable, "-c",
            "print(('error: unavailable export destination ' + 'x ' * 2000 + '\\n') * 250)"])
        diagnostics = json.loads((self.output / "export.log").read_text())["diagnostics"]
        self.assertEqual(len(diagnostics), 200)
        self.assertTrue(all(len(line) <= 2000 for line in diagnostics))

    def test_success_and_failed_distribution_preserve_uploaded_identity(self):
        evidence.write_manifest({"source_sha": "b" * 40, "marketing_version": "1.3.0",
                                 "build_number": "27", "upload": "succeeded"})
        with patch.dict(os.environ, INTERNAL_OUTCOME="failure", EXTERNAL_OUTCOME="skipped"):
            evidence.finalize()
        result = evidence.manifest()
        self.assertEqual(result["upload"], "succeeded")
        self.assertEqual(result["source_sha"], "b" * 40)
        self.assertEqual(result["workflow_sha"], "a" * 40)
        self.assertEqual(result["internal_distribution"], "failure")
        self.assertEqual(result["external_distribution"], "skipped")
        self.assertIn("verify_only", result["recovery"])

    def test_verify_does_not_claim_current_checkout_built_old_release(self):
        with patch.dict(os.environ, RELEASE_MODE="verify"):
            evidence.finalize()
        self.assertIsNone(evidence.manifest()["source_sha"])
        self.assertEqual(evidence.manifest()["external_distribution"], "pending_review")
        with patch.dict(os.environ, EXTERNAL_AVAILABLE="true"):
            evidence.finalize()
        self.assertEqual(evidence.manifest()["external_distribution"], "available")

    def test_symbols_exclude_archive_credentials_and_symlink_escapes(self):
        archive = self.root / "archive"
        symbols = archive / "dSYMs" / "Shopping.app.dSYM" / "Contents"
        symbols.mkdir(parents=True)
        (symbols / "symbols").write_bytes(b"symbol fixture")
        secret = archive / "embedded.mobileprovision"
        secret.write_text("secret")
        (symbols / "escape").symlink_to(secret)
        (symbols / "escape-directory").symlink_to(self.root, target_is_directory=True)
        (archive / "dSYMs" / "escape.dSYM").symlink_to(archive, target_is_directory=True)
        evidence.collect(archive, "7")
        files = sorted(str(p.relative_to(self.output)) for p in self.output.rglob("*") if p.is_file())
        self.assertEqual(files, ["dSYMs/Shopping.app.dSYM/Contents/symbols", "manifest.json"])
        self.assertEqual(evidence.manifest()["upload_script_exit_code"], 7)

    def test_successful_command_records_success(self):
        self.assertEqual(evidence.run("upload", self.root / "raw", [sys.executable, "-c", "pass"]), 0)
        self.assertEqual(evidence.manifest()["upload"], "succeeded")


if __name__ == "__main__":
    unittest.main()
