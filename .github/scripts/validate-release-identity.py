#!/usr/bin/env python3
"""Check exported iPhone/Watch metadata and the embedded clean source SHA."""
import argparse
import plistlib
import tempfile
import zipfile
from pathlib import Path

EXPECTED = {"com.mggarofalo.shopping", "com.mggarofalo.shopping.watchkitapp"}


def validate(app, version, build, commit):
    found = set()
    for bundle in [app, *app.rglob("*.app")]:
        with (bundle / "Info.plist").open("rb") as file:
            info = plistlib.load(file)
        identifier = info["CFBundleIdentifier"]
        if identifier not in EXPECTED or identifier in found:
            raise ValueError("Unexpected or duplicate application identity")
        found.add(identifier)
        if info["CFBundleShortVersionString"] != version or info["CFBundleVersion"] != build:
            raise ValueError(f"{identifier}: exported version/build differs from release intent")
        if identifier == "com.mggarofalo.shopping" and (bundle / "BuildCommit.txt").read_text().strip() != commit:
            raise ValueError("Exported source identity differs from the clean release commit")
    if found != EXPECTED:
        raise ValueError("Export must contain both iPhone and Watch apps")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["ipa", "version", "build", "commit"]:
        parser.add_argument(f"--{name}", required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="shopping-release-identity-") as directory:
        with zipfile.ZipFile(args.ipa) as archive:
            archive.extractall(directory)
        apps = list((Path(directory) / "Payload").glob("*.app"))
        if len(apps) != 1:
            raise ValueError("Expected one iPhone Payload app")
        validate(apps[0], args.version, args.build, args.commit)
    print("Verified exported iPhone/Watch version, build number and clean source identity.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, zipfile.BadZipFile) as error:
        raise SystemExit(f"Release identity validation failed: {error}")
