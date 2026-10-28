#!/usr/bin/env python3
"""Own the existing Siri CI test and diagnostic shell orchestration."""
import argparse
import os
import subprocess
import sys

TEST_SCRIPT = r'''
simulator_id="$(xcrun simctl create 'Shopping Siri schema' com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0)"
echo "$simulator_id" > "$RUNNER_TEMP/SiriSimulatorID"
# Preserve ordinary results plus targeted registration evidence; a verbose
# post-failure sysdiagnose previously exhausted the job and lost Info.plist.
xcodebuild test -project Shopping.xcodeproj -scheme ShoppingSiri -testPlan ShoppingSiri \
  -collect-test-diagnostics never \
  -destination "platform=iOS Simulator,id=$simulator_id" -parallel-testing-enabled NO \
  -only-testing:ShoppingPersistenceTests/SpokenGrocerySchemaTests \
  -only-testing:ShoppingPersistenceTests/CatalogActionTests \
  -only-testing:ShoppingSiriTests/ModernSiriActionTests/testModernSiriActionReturnsSavedEntityThroughSystemExecution \
  -resultBundlePath "$RUNNER_TEMP/SiriSchema.xcresult"
xcrun xcresulttool get test-results tests --path "$RUNNER_TEMP/SiriSchema.xcresult" --format json > "$RUNNER_TEMP/SiriSchemaTests.json"
jq -e '
  [.. | objects | select(.nodeType? == "Test Case")] as $tests |
  ($tests | length == 22) and all($tests[]; .result == "Passed") and
  ([$tests[] | select(.nodeIdentifier | startswith("CatalogActionTests/"))] | length == 15) and
  ([$tests[] | select(.nodeIdentifier | startswith("SpokenGrocerySchemaTests/"))] | length == 6) and
  ([$tests[] | select(.nodeIdentifier == "ModernSiriActionTests/testModernSiriActionReturnsSavedEntityThroughSystemExecution()")] | length == 1)
' "$RUNNER_TEMP/SiriSchemaTests.json"
'''
CAPTURE_SCRIPT = r'''
if [[ ! -f "$RUNNER_TEMP/SiriSimulatorID" ]]; then
  echo "No Siri simulator was created."
  exit 0
fi
simulator_id="$(cat "$RUNNER_TEMP/SiriSimulatorID")"
evidence="$RUNNER_TEMP/SiriRegistration"
mkdir -p "$evidence"
date -u > "$evidence/CaptureTime.txt"
# Best-effort diagnostics never change the preceding test/manifest verdict.
set +e
bounded() { python3 -c 'import subprocess, sys; sys.exit(subprocess.run(sys.argv[1:], timeout=20).returncode)' "$@"; }
bounded xcrun simctl bootstatus "$simulator_id" -b > "$evidence/Boot.log" 2>&1
echo "boot=$?" >> "$evidence/ExitStatus.txt"
bounded xcrun simctl spawn "$simulator_id" log show --last 25m --style compact \
  --predicate 'subsystem BEGINSWITH[c] "com.apple.appintents" OR process == "linkd"' \
  > "$evidence/System.log" 2>&1
echo "log=$?" >> "$evidence/ExitStatus.txt"
app_path="$(bounded xcrun simctl get_app_container "$simulator_id" com.mggarofalo.shopping app 2> "$evidence/ContainerError.log")"
echo "container=$?" >> "$evidence/ExitStatus.txt"
if [[ -d "$app_path/Metadata.appintents" ]]; then
  cp -R "$app_path/Metadata.appintents" "$evidence/Metadata.appintents"
  echo "metadata_copy=$?" >> "$evidence/ExitStatus.txt"
  plutil -convert json -o "$evidence/AppInfo.json" "$app_path/Info.plist"
  echo "app_info=$?" >> "$evidence/ExitStatus.txt"
fi
bounded xcrun simctl shutdown "$simulator_id"
echo "shutdown=$?" >> "$evidence/ExitStatus.txt"
bounded xcrun simctl delete "$simulator_id"
echo "delete=$?" >> "$evidence/ExitStatus.txt"
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("test", "capture"))
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    script = TEST_SCRIPT if args.action == "test" else CAPTURE_SCRIPT
    return subprocess.run(["bash", "-euo", "pipefail", "-c", script],
                          env=dict(os.environ, RUNNER_TEMP=args.output)).returncode


if __name__ == "__main__":
    sys.exit(main())
