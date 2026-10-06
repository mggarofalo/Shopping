#!/usr/bin/env python3
"""Release evidence is an allowlist, never a copy of the signing workspace."""
import base64
from collections import deque
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

# Retain bounded error/warning reasons, never the complete command transcript.
# Scrub credentials before truncation so a partial secret cannot survive a limit.
DIAGNOSTICS = {
    "compiler_error": re.compile(r"\berror:", re.I),
    "compiler_warning": re.compile(r"\bwarning:", re.I),
    "signing": re.compile(r"codesign|provisioning|signing", re.I),
    "archive_succeeded": re.compile(r"\*\* ARCHIVE SUCCEEDED \*\*"),
    "archive_failed": re.compile(r"\*\* ARCHIVE FAILED \*\*"),
    "export_succeeded": re.compile(r"\*\* EXPORT SUCCEEDED \*\*"),
    "export_failed": re.compile(r"\*\* EXPORT FAILED \*\*"),
}


DIAGNOSTIC_TEXT = re.compile(r"\b(?:error|warning):|\bERROR (?:ITMS|ITC)-[0-9]+|Error Domain=|NSLocalizedDescription|\*\* (?:ARCHIVE|EXPORT) (?:SUCCEEDED|FAILED) \*\*", re.I)
SECRET_NAME = re.compile(r"SECRET|TOKEN|PASSWORD|PRIVATE_KEY|CERTIFICATE|PROVISIONING|API_KEY|ISSUER", re.I)


def secret_values(command):
    values = set()
    for name, value in os.environ.items():
        if value and SECRET_NAME.search(name):
            values.add(value)
            if name.endswith("BASE64"):
                try:
                    decoded = base64.b64decode(value, validate=True).decode("utf-8")
                    values.add(decoded)
                    values.update(decoded.splitlines())
                except (ValueError, UnicodeDecodeError):
                    pass
    for argument in command:
        if "=" in argument and re.search(r"PROFILE|CODE_SIGN|DEVELOPMENT_TEAM", argument.split("=", 1)[0]):
            values.add(argument.split("=", 1)[1])
    # Include escaped representations used by structured command diagnostics.
    values.update(json.dumps(value)[1:-1] for value in list(values))
    return sorted((value for value in values if value), key=len, reverse=True)


def sanitize(line, secrets):
    for value in secrets:
        line = line.replace(value, "[REDACTED]")
    line = re.sub(r"(?i)(?:Bearer\s+)[^\s\"']+", "Bearer [REDACTED]", line)
    line = re.sub(r"(?i)\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b|\b[0-9a-f]{40}\b", "[SIGNING-ID]", line)
    line = re.sub(r"Apple (?:Distribution|Development):[^\n]*?\([A-Z0-9]{10}\)", "[SIGNING-IDENTITY]", line)
    line = re.sub(r"[A-Za-z0-9+/=_-]{64,}", "[ENCODED-DATA]", line)
    line = re.sub(r"(?i)(?:password|token|apiKey|apiIssuer|CODE_SIGN_IDENTITY|PROVISIONING_PROFILE(?:_SPECIFIER)?)\s*[=:]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)", "[SIGNING-ARGUMENT]", line)
    for name in ("RUNNER_TEMP", "HOME"):
        if os.environ.get(name):
            line = line.replace(os.environ[name], f"[{name}]")
    line = re.sub(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", "[EMAIL]", line)
    return line.strip()[:2000]


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
    code = result.returncode if result.returncode >= 0 else 128 - result.returncode
    try:
        secrets = secret_values(command)
        errors = deque(maxlen=200)
        warnings = deque(maxlen=200)
        in_pem = False
        with open(raw_path, errors="replace") as raw:
            for line in raw:
                if "-----BEGIN " in line:
                    in_pem = True
                skip = in_pem
                if "-----END " in line:
                    in_pem = False
                if skip:
                    continue
                for name, pattern in DIAGNOSTICS.items():
                    if pattern.search(line):
                        counts[name] += 1
                if len(line) <= 65536 and DIAGNOSTIC_TEXT.search(line):
                    # Keep the failure tail even after a noisy compiler emits
                    # hundreds of warnings; errors take the bounded budget first.
                    target = warnings if re.search(r"\bwarning:", line, re.I) and not re.search(r"\berror:", line, re.I) else errors
                    target.append(sanitize(line, secrets))
        diagnostics = list(warnings)[-(200 - len(errors)):] if len(errors) < 200 else []
        diagnostics.extend(errors)
        record = {"stage": stage, "exit_code": code, "diagnostic_counts": counts,
                  "diagnostics": diagnostics,
                  "note": "At most 200 redacted error/warning lines; commands and raw output excluded."}
        (directory() / f"{stage}.log").write_text(json.dumps(record, indent=2) + "\n")
        data = manifest()
        data[stage] = "succeeded" if code == 0 else "failed"
        if stage == "upload" and code != 0:
            data[stage] = "unconfirmed"  # A network error can follow Apple accepting it.
        write_manifest(data)
        print(f"Release {stage}: exit {code}; sanitized diagnostics retained.")
    except Exception:
        # Never print an exception containing raw text or secret path values.
        print("Release evidence failed; command status preserved when nonzero.", file=sys.stderr)
        return code or 1
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
