#!/usr/bin/env python3
"""Validate the two App Store profiles against the imported signing identity."""
import argparse
import datetime
import hashlib
import plistlib
import re
from pathlib import Path

TEAM = "649367BDD4"
TARGETS = {"iphone": "com.mggarofalo.shopping", "watch": "com.mggarofalo.shopping.watchkitapp"}


def validate(profile, bundle, fingerprints, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", profile.get("UUID", "")):
        raise ValueError("Invalid profile UUID")
    ent = profile.get("Entitlements", {})
    if profile.get("TeamIdentifier") != [TEAM] or ent.get("com.apple.developer.team-identifier") != TEAM:
        raise ValueError("Profile must belong to the established release team")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    if len(prefixes) != 1 or ent.get("application-identifier") != f"{prefixes[0]}.{bundle}":
        raise ValueError(f"Profile does not match {bundle}")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime.datetime) or expiry.replace(tzinfo=datetime.timezone.utc) <= now:
        raise ValueError("Profile expired or has no expiration date")
    if "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices") or ent.get("get-task-allow") is not False:
        raise ValueError("An App Store distribution profile is required")
    environments = ent.get("com.apple.developer.icloud-container-environment", [])
    if isinstance(environments, str):
        environments = [environments]
    if ent.get("aps-environment") != "production" or "Production" not in environments:
        raise ValueError("Profile must enable production push and CloudKit")
    services = ent.get("com.apple.developer.icloud-services", [])
    if isinstance(services, str):
        services = [services]
    if not ({"CloudKit", "*"} & set(services)) or "iCloud.com.mggarofalo.shopping" not in ent.get("com.apple.developer.icloud-container-identifiers", []):
        raise ValueError("Profile must grant the Shopping CloudKit container")
    if "InProcessOneTimeLinks" not in ent.get("com.apple.developer.icloud-extended-share-access", []):
        raise ValueError("Profile must enable InProcessOneTimeLinks sharing")
    matching = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get("DeveloperCertificates", [])} & fingerprints
    if not matching:
        raise ValueError("Profile does not include an imported valid distribution certificate")
    return matching


def configuration(profiles, fingerprints):
    matches = [validate(profiles[target], bundle, fingerprints) for target, bundle in TARGETS.items()]
    common = set.intersection(*matches)
    if not common:
        raise ValueError("Both profiles must use the same imported distribution identity")
    uuids = {target: profiles[target]["UUID"] for target in TARGETS}
    if len(set(uuids.values())) != 2:
        raise ValueError("iPhone and Watch require distinct profiles")
    return uuids, sorted(common)[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["iphone", "watch", "identities", "output"]:
        parser.add_argument(f"--{name}", required=True, type=Path)
    args = parser.parse_args()
    profiles = {}
    for target in TARGETS:
        with getattr(args, target).open("rb") as file:
            profiles[target] = plistlib.load(file)
    identities = args.identities.read_text()
    fingerprints = set(re.findall(r'\b([0-9A-F]{40})\s+"Apple Distribution:.*\(649367BDD4\)"', identities))
    uuids, certificate = configuration(profiles, fingerprints)
    args.output.mkdir(exist_ok=True)
    for target, uuid in uuids.items():
        (args.output / f"{target}.uuid").write_text(uuid)
    (args.output / "certificate.sha1").write_text(certificate)
    export = {"method": "app-store-connect", "destination": "export", "signingStyle": "manual",
              "signingCertificate": certificate, "teamID": TEAM, "manageAppVersionAndBuildNumber": False,
              "provisioningProfiles": {bundle: uuids[target] for target, bundle in TARGETS.items()}}
    with (args.output / "ExportOptions.plist").open("wb") as file:
        plistlib.dump(export, file)
    print("Validated separate iPhone/Watch App Store profiles, capabilities, expiry and shared signing identity.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, plistlib.InvalidFileException) as error:
        raise SystemExit(f"Release profile validation failed: {error}")
