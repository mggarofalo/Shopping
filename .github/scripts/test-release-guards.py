#!/usr/bin/env python3
import copy
import datetime
import hashlib
import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parent

def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f"{name}.py")
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

profiles = module("validate-release-profiles")
identity = module("validate-release-identity")
ci = module("require-release-ci")
CERT = b"fixture certificate bytes"
FINGERPRINT = hashlib.sha1(CERT).hexdigest().upper()

def profile(bundle, uuid):
    return {"UUID": uuid, "TeamIdentifier": [profiles.TEAM], "ApplicationIdentifierPrefix": [profiles.TEAM],
            "ExpirationDate": datetime.datetime(2099, 1, 1), "DeveloperCertificates": [CERT],
            "Entitlements": {"application-identifier": f"{profiles.TEAM}.{bundle}", "com.apple.developer.team-identifier": profiles.TEAM,
                "get-task-allow": False, "aps-environment": "production", "com.apple.developer.icloud-container-environment": "Production",
                "com.apple.developer.icloud-services": ["CloudKit"], "com.apple.developer.icloud-container-identifiers": ["iCloud.com.mggarofalo.shopping"],
                "com.apple.developer.icloud-extended-share-access": ["InProcessOneTimeLinks"]}}

class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.pair = {target: profile(bundle, f"00000000-0000-0000-0000-00000000000{index}") for index, (target, bundle) in enumerate(profiles.TARGETS.items())}
    def test_valid_distinct_pair(self):
        uuids, certificate = profiles.configuration(self.pair, {FINGERPRINT})
        self.assertEqual(len(set(uuids.values())), 2)
        self.assertEqual(certificate, FINGERPRINT)
        self.pair["watch"]["Entitlements"]["com.apple.developer.icloud-container-environment"] = ["Development", "Production"]
        self.pair["watch"]["Entitlements"]["com.apple.developer.icloud-services"] = "*"
        profiles.configuration(self.pair, {FINGERPRINT})
    def test_wrong_bundle_team_expiration_or_app_store_shape(self):
        changes = [("UUID", "bad"), ("TeamIdentifier", ["wrong"]), ("ExpirationDate", datetime.datetime(2020, 1, 1)), ("ProvisionedDevices", []), ("ProvisionsAllDevices", True), ("IsXcodeManaged", True)]
        for key, value in changes:
            with self.subTest(key=key):
                pair = copy.deepcopy(self.pair); pair["watch"][key] = value
                with self.assertRaises(ValueError): profiles.configuration(pair, {FINGERPRINT})
        for key, value in [("application-identifier", "wrong"), ("com.apple.developer.team-identifier", "wrong"), ("get-task-allow", True), ("aps-environment", "development"), ("com.apple.developer.icloud-container-environment", "Development"), ("com.apple.developer.icloud-services", []), ("com.apple.developer.icloud-container-identifiers", []), ("com.apple.developer.icloud-extended-share-access", [])]:
            with self.subTest(entitlement=key):
                pair = copy.deepcopy(self.pair); pair["watch"]["Entitlements"][key] = value
                with self.assertRaises(ValueError): profiles.configuration(pair, {FINGERPRINT})
    def test_mismatched_certificate_and_duplicate_profile(self):
        with self.assertRaises(ValueError): profiles.configuration(self.pair, {"0" * 40})
        self.pair["watch"]["DeveloperCertificates"] = [b"other"]
        with self.assertRaises(ValueError): profiles.configuration(self.pair, {FINGERPRINT})
        self.pair["watch"]["DeveloperCertificates"] = [CERT]
        self.pair["watch"]["UUID"] = self.pair["iphone"]["UUID"]
        with self.assertRaises(ValueError): profiles.configuration(self.pair, {FINGERPRINT})

class IdentityTests(unittest.TestCase):
    def test_export_metadata_and_clean_sha(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Shopping.app"
            bundles = [app, app / "Watch/ShoppingWatch.app"]
            for bundle, identifier in zip(bundles, sorted(identity.EXPECTED)):
                bundle.mkdir(parents=True)
                with (bundle / "Info.plist").open("wb") as file:
                    plistlib.dump({"CFBundleIdentifier": identifier, "CFBundleShortVersionString": "1.4.0", "CFBundleVersion": "28"}, file)
            (app / "BuildCommit.txt").write_text("a" * 40)
            identity.validate(app, "1.4.0", "28", "a" * 40)
            for version, build, commit in [("1.3.0", "28", "a"*40), ("1.4.0", "29", "a"*40), ("1.4.0", "28", "b"*40)]:
                with self.assertRaises(ValueError): identity.validate(app, version, build, commit)
            (app / "BuildCommit.txt").write_text("a" * 40 + "-dirty")
            with self.assertRaises(ValueError): identity.validate(app, "1.4.0", "28", "a"*40)

class CITests(unittest.TestCase):
    def test_latest_exact_source_and_required_jobs(self):
        sha = "a" * 40
        run = {"id": 1, "head_sha": sha, "head_branch": "main", "event": "push", "status": "completed", "conclusion": "success"}
        jobs = [{"name": name, "status": "completed", "conclusion": "success"} for name in ["Release SDK Build", "Build & Test"]]
        self.assertEqual(ci.require_ci([run], jobs, sha), run)
        for key, value in [("head_sha", "b"*40), ("head_branch", "feature"), ("event", "pull_request"), ("status", "in_progress"), ("conclusion", "failure")]:
            bad = dict(run, **{key: value})
            with self.assertRaises(ValueError): ci.require_ci([bad], jobs, sha)
        with self.assertRaises(ValueError): ci.require_ci([run, dict(run, id=2, conclusion="failure")], jobs, sha)
        for conclusion in ["skipped", "failure", None]:
            with self.assertRaises(ValueError): ci.require_ci([run], [jobs[0], dict(jobs[1], conclusion=conclusion)], sha)
        with self.assertRaises(ValueError): ci.require_ci([run], jobs[:1], sha)

if __name__ == "__main__": unittest.main()
