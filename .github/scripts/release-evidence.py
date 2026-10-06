#!/usr/bin/env python3
"""Release evidence is an allowlist, never a copy of the signing workspace."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

# Do not retain arbitrary tool output: it can include signing arguments, decoded
# credentials or developer contact information. Only fixed diagnostic categories
# survive. Full transient output remains in the private signing workspace.
DIAGNOSTICS = {
    "compiler_error": re.compile(r"\berror:", re.I),
    "compiler_warning": re.compile(r"\bwarning:", re.I),
    "signing": re.compile(r"codesign|provisioning|signing", re.I),
    "archive_succeeded": re.compile(r"\*\* ARCHIVE SUCCEEDED \*\*"),
    "archive_failed": re.compile(r"\*\* ARCHIVE FAILED \*\*"),
    "export_succeeded": re.compile(r"\*\* EXPORT SUCCEEDED \*\*"),
    "export_failed": re.compile(r"\*\* EXPORT FAILED \*\*"),
}


def directory():
    path = Path(os.environ["RELEASE_EVIDENCE_DIR"])
    path.mkdir(parents=True, exist_ok=True)
    return path


def write_manifest(data):
    path = directory() / "manifest.json"
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.replace(path)


def manifest():
    path = directory() / "manifest.json"
    return json.loads(path.read_text()) if path.exists() else {"schema_version": 1}


def initialize():
    write_manifest({"schema_version": 1, "source_sha": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], text=True).strip(),
        "marketing_version": os.environ["MARKETING_VERSION"],
        "build_number": os.environ["BUILD_NUMBER"], "upload": "not_attempted"})


def run(stage, raw_path, command):
    data = manifest()
    data[stage] = "unconfirmed" if stage == "upload" else "running"
    write_manifest(data)
    counts = dict.fromkeys(DIAGNOSTICS, 0)
    # Output is stored only under TEMP_ROOT; never print or upload it wholesale.
    with open(raw_path, "wb") as raw:
        result = subprocess.run(command, stdout=raw, stderr=subprocess.STDOUT)
    with open(raw_path, errors="replace") as raw:
        for line in raw:
            for name, pattern in DIAGNOSTICS.items():
                if pattern.search(line):
                    counts[name] += 1
    code = result.returncode if result.returncode >= 0 else 128 - result.returncode
    record = {"stage": stage, "exit_code": code, "diagnostic_counts": counts,
              "note": "Arbitrary command output excluded to protect signing credentials."}
    (directory() / f"{stage}.log").write_text(json.dumps(record, indent=2) + "\n")
    data = manifest()
    data[stage] = "succeeded" if code == 0 else "failed"
    if stage == "upload" and code != 0:
        data[stage] = "unconfirmed"  # A network error can follow Apple accepting it.
    write_manifest(data)
    print(f"Release {stage}: exit {code}; sanitized diagnostics retained.")
    return code


def collect(archive, exit_code):
    symbols = Path(archive) / "dSYMs"
    # Copy only regular files inside actual dSYM bundles; never follow links to
    # signing material or include the archive's embedded provisioning profiles.
    if symbols.is_dir() and not symbols.is_symlink():
        for bundle in symbols.glob("*.dSYM"):
            if not bundle.is_dir() or bundle.is_symlink():
                continue
            for source in bundle.rglob("*"):
                if source.is_symlink() or any(p.is_symlink() for p in source.parents if p != symbols and symbols in p.parents):
                    continue
                if source.is_file():
                    target = directory() / "dSYMs" / source.relative_to(symbols)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, target)
    data = manifest()
    data["upload_script_exit_code"] = int(exit_code)
    write_manifest(data)


def finalize():
    data = manifest()
    data["workflow_sha"] = os.environ["GITHUB_SHA"]
    # Verify-only may distribute an older build; current checkout is not proof
    # of the source that produced that build.
    data.setdefault("source_sha", None)
    data.setdefault("marketing_version", os.environ.get("RELEASE_VERSION") or None)
    data.setdefault("build_number", os.environ.get("RELEASE_BUILD") or None)
    data.setdefault("upload", "not_attempted")
    data["archive_upload_step"] = (os.environ.get("UPLOAD_OUTCOME") or "skipped")
    internal = (os.environ.get("INTERNAL_OUTCOME") or "skipped")
    external = (os.environ.get("EXTERNAL_OUTCOME") or "skipped")
    data["internal_distribution"] = "available" if internal == "success" else internal
    available = os.environ.get("EXTERNAL_AVAILABLE", "")
    data["external_distribution"] = (
        "available" if available == "true" else "pending_review" if available == "false"
        else "unconfirmed") if external == "success" else external
    data["recovery"] = (
        "Use verify_only for this version/build to confirm processing and distribution; do not upload a duplicate."
        if data["upload"] in ("succeeded", "unconfirmed") or os.environ.get("RELEASE_MODE") == "verify"
        else "Inspect the failed stage and confirm the version/build is unused before another upload.")
    write_manifest(data)
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write("\n### TestFlight release evidence\n\n```json\n" + json.dumps(data, indent=2) + "\n```\n")


if __name__ == "__main__":
    action, *args = sys.argv[1:]
    if action == "init":
        initialize()
    elif action == "run":
        sys.exit(run(args[0], args[1], args[2:]))
    elif action == "collect":
        collect(*args)
    elif action == "finalize":
        finalize()
    else:
        raise SystemExit("Unknown release evidence action")
