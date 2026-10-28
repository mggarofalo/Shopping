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
when exporting the inventory succeeds. Wrong class counts, duplicate identifiers,
failed or skipped cases, unexpected test classes, and a different native UI method
cannot produce a passing manifest. The selected tests remain
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

## October 28 probe result

[Diagnostic run 40714864040](https://github.com/mggarofalo/Shopping/actions/runs/40714864040)
on `e8ecf35` passed all 22 selected cases and the manifest check. Automation setup
completed before the twenty-second sampling threshold, so no stack sample was
triggered. Final state was `Shutdown`; capture observed it without booting and
completed in approximately three seconds by GitHub step timestamps. Raw evidence
is retained at `/tmp/shopping-249-launch-probe/`.

This confirms that the post-test collector need not restart a simulator that
Xcode has shut down. It does not reproduce or explain the intermittent launch
timeout, and it is not a controlled whole-job speed comparison.

Subsequent review fixed bounded draining when a descendant retains stdout after
its parent exits, and added runner contracts to normal release CI before archive.
Those changes have dedicated local process tests; this earlier probe is not
exact-source CI proof for them. The final integrated candidate still requires its
own required checks. SHOPPING-249 remains open for the native launch cause.

## Recurrence during phase integration

[PR CI run 40748443094](https://github.com/mggarofalo/Shopping/actions/runs/40748443094)
for milestone head `23f1176` again passed the 21 app-backed contracts and failed
the native UI case at `XCUIApplication.launch()`. The test exit remained 65 and
the exact-inventory check failed. The exported
`Session-ShoppingSiriTests-2026-10-28_185814-h0DTyY.log` records:

| UTC | Evidence |
| --- | --- |
| 19:00:07.952 | Runner creates the 60-second launch future (line 696). |
| 19:00:12.796 | Xcode receives the launch request (line 698). |
| 19:01:08.348 | Runner times out after 60.396 seconds (lines 1963–1966). |
| 19:01:34.372 | Xcode invokes the token receipt, 26.024 seconds after timeout (line 713). |
| 19:01:36.566 | Xcode submits the native application launch (line 2089). |
| 19:01:37.551 | Runner observes PID 61647 running in the foreground (line 2148). |
| 19:03:27.595 | Spindump collection finishes after 139.240 seconds (lines 2360–2363). |

The failed case lasted 226.810 seconds. This repeats the launch acknowledgement
failure, before intent execution; late app startup evidence does not explain
the earlier delay. The post-test collector observed `Shutdown`, did not boot,
and successfully deleted only its owned simulator. Its state inspection and
cleanup commands totaled 2.607 seconds. Evidence is retained locally under
`/tmp/shopping-phase-18-ci-40748443094/` and in that run's `siri-schema-results` artifact.

Routine `Release SDK Build (native)` now enables the same bounded launch observer
as the diagnostic job. The next actual routine stall can therefore retain
pre-timeout evidence without requiring another diagnostic-only attempt. The
existing artifact upload includes `LaunchObservation.json` and `LaunchSample`
under `SiriRegistration`. Quick launches add log parsing and a small observation
receipt, with no sampling subprocess or deliberate wait. A launch still pending
after twenty seconds triggers two discovery commands and at most five one-second
process samples on the background thread. Each command has a five-second timeout
and up to five seconds to reap a killed process: 35 seconds of command timeouts,
or a conservative 70 seconds including all timeout cleanup waits, excluding
host scheduling and file I/O. Collection overlaps the native wait, but final
thread cleanup can add the remaining collection time. Sampling can also perturb
a slow host; this is an observation cost, not a measured speedup.

Selection, launch ordering, native timeout and assertions are unchanged. Runner
contracts cover routine observer wiring and preserve the native failure even
when process discovery or sampling fails. The failed CI run stays failed, and
the launch cause remains open pending evidence captured during the delay.

## UI runner bootstrap and runtime-cache readiness experiment

[Run 40757515880](https://github.com/mggarofalo/Shopping/actions/runs/40757515880)
passed the 21 app-backed contracts, then failed before the native UI test began.
The exported `Session-ShoppingSiriTests-2026-10-28_195721-ppCsXe.log` records the
runner loading its test bundle at 19:57:43.166–43.242 UTC (lines 146–148), entering
UI automation initialization (line 290), and starting the 70-second
`loading Accessibility` wait at 19:57:43.262 (lines 301–302). The waiter watchdog
triggered at 19:58:57.024 (line 304). Xcode observed SIGABRT at 19:59:14.964
(line 307), then spent another 95.927 seconds synchronizing the crash report.

The crash attachment `88FC33D3-4F9A-4B0C-BAB4-AFA9E961DB51.ips` shows the runner's
main thread traversing dyld dependencies while `NSBundle` loads UIKit's
accessibility bundle. Its call stack reaches `XCAXClient_iOS.loadAccessibility`
and XCTest's pre-test initialization; the abort comes from XCTest's stalled-wait
thread. No Shopping test body or application-startup code ran at this boundary.
The snapshot does not prove how long dependency loading occupied the wait or why
it was slow. Retained logs contain no explicit cache-creation error, missing
runtime cache, lock wait, or host-pressure measurement. The crash's shared-cache
field and individual runtime image paths do not establish cache readiness.

The simulator was already Booted at 19:54:17.959, before the successful app-backed
contracts. Thus a generic preboot is not the evidence-backed change. The existing
observer correctly records no app-launch marker and no sample for this earlier
failure. Raw evidence remains under `/tmp/shopping-phase-18-ci-40757515880/`; the
original native exit 65 and failed selection remain failures.

Apple's [Xcode 26.4 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_4-release-notes)
identify runtime scanning/cache construction as a temporary performance cost and
provide a command to wait for caching completion. An [Apple Developer Tools engineer](https://developer.apple.com/forums/thread/807025)
likewise describes library-load delays during runtime scans and recommends cache
readiness before another launch. These sources support a targeted experiment;
they do not diagnose this Xcode 27 failure.

Before creating its owned simulator, the runner now executes exactly:

```sh
xcrun simctl runtime dyld_shared_cache update com.apple.CoreSimulator.SimRuntime.iOS-27-0
```

This scopes preparation to the selected runtime. It neither forces recreation
nor removes caches, and it does not boot a simulator or retry a test. The command
must succeed within a separate 300-second setup bound before simulator creation
or testing can proceed. That bound allows a finite setup experiment; it is not
an observed readiness target or a change to the native test's timeout. The
existing 25-minute job limit remains unchanged.

`SiriRegistration/RuntimeReadiness.log` and `RuntimeReadiness.json` retain the
command, start time, exit status, timeout/cancellation status, and wall time. The
shared command supervisor streams output and owns its child process group. On
SIGINT/SIGTERM it forwards the signal, allows five seconds, then attempts to kill
remaining owned processes. Timeout likewise attempts to kill the group and
returns 124. A separate five-second post-kill deadline bounds reaping/draining,
including a leader that closed stdout but has not exited. Incomplete cleanup is
reported without replacing an established timeout/cancellation. Real process
contracts cover stubborn descendants and closed output pipes; a deterministic
unreapable-process case verifies the final supervision bound. Cleanup cannot
guarantee termination if the OS refuses the signal, and it does not cancel work
already enqueued in CoreSimulator's system daemon.
A timeout remains failed readiness even if that daemon later finishes its cache.

The controlled hosted result must retain all 22 passing cases and measure the
setup cost separately. A green run alone will not prove the cache was previously
missing or that the intermittent cause is cured. No test selection, assertion,
application behavior, native timeout, or retry policy changes in this experiment.
