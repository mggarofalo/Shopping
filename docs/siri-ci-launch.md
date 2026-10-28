# Hosted Siri launch investigation — SHOPPING-249

The October 28 failure in [Swift CI 40691576008](https://github.com/mggarofalo/Shopping/actions/runs/40691576008)
is a launch-request acknowledgement timeout followed by diagnostic overhead.
It is not evidence that the Siri intent itself executed slowly. All 21 app-backed
contracts passed; the native UI case failed at `XCUIApplication.launch()` before
querying an entity or executing the action.

## Retained timeline

The exported `Session-ShoppingSiriTests-2026-10-28_130223-T6Sgys.log` establishes:

| UTC | Evidence |
| --- | --- |
| 13:02:58.579 | Runner creates a launch-request future with a 60-second timeout (line 522). |
| 13:02:59.405 | Xcode receives the application launch request (line 524). |
| 13:03:58.759 | Runner times out after 60.183 seconds, then requests a spindump (lines 4655–4660). |
| 13:04:09.588 | Xcode invokes its launch-token receipt (line 539). |
| 13:04:25.798–28.728 | Xcode submits the native launch and reports app PID 27485 (lines 5809, 5858). |
| 13:04:41.170 | Runner observes Shopping running in the foreground (line 6021). |
| 13:07:18.951 | Spindump wait finishes after 200.167 seconds (lines 6616–6619). |
| 13:07:21 | Original launch timeout is reported as the test failure. |

Thus the 264.936-second case contains roughly 60 seconds waiting for the launch
receipt and 200 seconds collecting failure evidence. The request's failure was
already established before the app reached the foreground.

The exported spindump was captured at 13:04:25.973–30.973, after the original
timeout. Xcode's simulator-launch thread waits in `host_support_mig_launch_app`
on CoreSimulatorBridge. The bridge receives the launch request and waits in
dispatch-group and semaphore operations. Shopping starts at 13:04:28.268 and is
suspended in its sampled startup frames. This late sample does not identify the
cause of the earlier launch-token delay.

Post-test `SiriRegistration/Boot.log` starts with **Booting device…** at 13:07:53.
The old capture command used `simctl bootstatus -b`, which boots a shut-down
device. Its 20-second timeout cannot establish that the original test simulator
remained frozen; the diagnostic command changed the state it was meant to inspect.

Raw evidence is retained locally under `/tmp/shopping-249-current-release/`,
`/tmp/shopping-249-current-diagnostics/` and
`/tmp/shopping-249-current-attachments/`. The original run remains failed.

## Narrow observation experiment

`.github/scripts/siri-schema-ci.py` owns the existing simulator creation, unchanged
22-test command and result manifest. It preserves the original test exit even
when exporting the inventory succeeds. Missing, duplicated, failed, skipped or
unexpected cases cannot produce a passing manifest. The selected tests remain
15 catalog contracts, six spoken-schema contracts and the one native UI method.

The manual `siri_launch_diagnostic` workflow input runs a separately named
**Siri launch diagnostic** job. Both ordinary required jobs are skipped in that
mode, so the probe cannot satisfy required-check or Full-preflight proof. Archive,
toolchain and initial simulator launch ordering match the ordinary release job.
The probe adds no preboot, retries, assertion changes or relaxed test timeout.

Twenty seconds after observing the native app launch marker, a background
observer captures read-only device/process state and bounded one-second process
samples if automation setup has not completed. It samples the known Xcode PID,
uniquely identifiable CoreSimulator/launch-services processes and the requested
device's Shopping process if present. It skips ambiguous service identities.
Sample collection does not block draining the test output pipe, owns no test
verdict and records each command's time, status and timeout separately.

Final capture records `simctl list devices --json` before cleanup. It collects
live app/registration evidence only if the device is still booted; it never boots
the device to collect logs. Shutdown/delete target only the simulator created by
this invocation. Ordinary xcresult evidence remains retained regardless of result.

This is diagnostic instrumentation, not a demonstrated startup cure. The first
probe should retain the baseline launch ordering so it changes one factor.
Explicit owned boot/readiness, host configuration or application changes require
the next evidence-backed decision. Do not infer that a green probe establishes
the original intermittent failure's cause.
