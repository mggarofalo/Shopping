#!/usr/bin/env python3
"""Independent always-step fallback. No command runs unless state file exists."""
import json
from pathlib import Path
import subprocess
import sys
state = Path(sys.argv[1])
if state.exists():
    original = json.loads(state.read_text())
    prefix = ["xcrun", "simctl", "ui", original["simulator"], "content_size"]
    subprocess.run(prefix + [original["contentSize"]], check=True, timeout=10)
    observed = subprocess.run(prefix, check=True, timeout=10, capture_output=True, text=True).stdout.strip()
    if observed != original["contentSize"]:
        raise SystemExit("System content size restoration readback failed")
