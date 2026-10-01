#!/usr/bin/env python3
"""Check sharing capabilities in every app configuration and exported signed app."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SHARE_ACCESS = "com.apple.developer.icloud-extended-share-access"
ONE_TIME_LINKS = "InProcessOneTimeLinks"


def output(*command):
    return subprocess.run(command, check=True, capture_output=True).stdout


def require_share_access(entitlements, label):
    access = entitlements.get(SHARE_ACCESS)
    if not isinstance(access, list) or ONE_TIME_LINKS not in access:
        raise ValueError(f"{label}: {SHARE_ACCESS} must include {ONE_TIME_LINKS}")


def source_applications():
    project = json.loads(output("plutil", "-convert", "json", "-o", "-",
                                str(ROOT / "Shopping.xcodeproj/project.pbxproj")))
    objects = project["objects"]
    applications = {}
    for target in objects.values():
        if target.get("isa") != "PBXNativeTarget" or target.get("productType") != "com.apple.product-type.application":
            continue
        configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
        for identifier in configurations:
            configuration = objects[identifier]
            settings = configuration["buildSettings"]
            label = f"{target['name']} {configuration['name']}"
            with (ROOT / settings["CODE_SIGN_ENTITLEMENTS"]).open("rb") as file:
                require_share_access(plistlib.load(file), label)
            applications[settings["PRODUCT_BUNDLE_IDENTIFIER"]] = target["name"]
            print(f"Verified source sharing capability: {label}")
    if not applications:
        raise ValueError("No application targets found")
    return applications


def signed_applications(app, expected):
    found = set()
    for bundle in [app, *sorted(app.rglob("*.app"))]:
        with (bundle / "Info.plist").open("rb") as file:
            info = plistlib.load(file)
        identifier = info["CFBundleIdentifier"]
        if identifier not in expected:
            raise ValueError(f"Unexpected signed application: {identifier}")
        if identifier in found:
            raise ValueError(f"Duplicate signed application: {identifier}")
        found.add(identifier)
        entitlements = plistlib.loads(output("codesign", "--display", "--entitlements", ":-", str(bundle)))
        require_share_access(entitlements, f"{identifier} signed app")
        if entitlements.get("com.apple.developer.icloud-container-environment") != "Production":
            raise ValueError(f"{identifier}: signed CloudKit environment must be Production")
        if entitlements.get("aps-environment") != "production":
            raise ValueError(f"{identifier}: signed push environment must be production")
        if "CloudKit" not in entitlements.get("com.apple.developer.icloud-services", []):
            raise ValueError(f"{identifier}: signed app must enable CloudKit")
        container = info["ShoppingCloudKitContainerIdentifier"]
        if container not in entitlements.get("com.apple.developer.icloud-container-identifiers", []):
            raise ValueError(f"{identifier}: signed app must grant its configured CloudKit container")
        profile = plistlib.loads(output("security", "cms", "-D", "-i", str(bundle / "embedded.mobileprovision")))
        require_share_access(profile["Entitlements"], f"{identifier} provisioning profile")
        print(f"Verified signed sharing capability and provisioning: {identifier}")
    missing = set(expected) - found
    if missing:
        raise ValueError(f"Missing signed applications: {', '.join(sorted(missing))}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    artifact = parser.add_mutually_exclusive_group()
    artifact.add_argument("--ipa", type=Path, help="Validate an exported TestFlight IPA")
    artifact.add_argument("--app", type=Path, help="Validate an already extracted exported app")
    arguments = parser.parse_args()
    expected = source_applications()
    if arguments.app:
        signed_applications(arguments.app, expected)
    if arguments.ipa:
        with tempfile.TemporaryDirectory(prefix="shopping-sharing-signing-") as temporary:
            with zipfile.ZipFile(arguments.ipa) as archive:
                archive.extractall(temporary)
            applications = list((Path(temporary) / "Payload").glob("*.app"))
            if len(applications) != 1:
                raise ValueError(f"Expected one Payload app, found {len(applications)}")
            signed_applications(applications[0], expected)


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, ValueError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print(f"CloudKit sharing validation failed: {error}", file=sys.stderr)
        sys.exit(1)
