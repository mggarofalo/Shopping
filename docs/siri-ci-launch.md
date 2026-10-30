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
25-minute job limit was unchanged then; the
[readiness budget calibration](#readiness-budget-calibration-october-30) later raised it to 35 minutes.

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

## App Intents registration after install (SHOPPING-262)

Release SDK runs [40958113407](https://github.com/mggarofalo/Shopping/actions/runs/40958113407)
(attempt 1) and [40962628144](https://github.com/mggarofalo/Shopping/actions/runs/40962628144)
failed the first native case at its first `IntentDefinitions` lookup with
`AppIntentsServicesMetadataErrorDomain Code=400 "com.mggarofalo.shopping is not present"`.
Launch had already succeeded; this is neither the SHOPPING-249 launch-token stall
nor a stale PID. The first run predates SHOPPING-258, with one native case, so
the second native case is not the cause. In 40962628144 that second case passed
in the same runner process about 21 seconds after install.

Xcode installs Shopping.app during the native session's first `XCUIApplication.launch()`,
after the launch request. The exported session logs give the time from that install
to the first lookup:

| Run | Shopping.app installed (UTC) | First lookup | Gap | Result |
| --- | --- | --- | --- | --- |
| 40958113407 #1 | 21:43:17.557 | 21:43:26.443 | 8.9 s | failed |
| 40962628144 | 22:15:11.238 | 22:15:20.711 | 9.5 s | failed |
| 40957779036 | 21:36:25.744 | 21:36:38.139 | 12.4 s | passed |
| 40939541147 | 19:42:30.415 | 19:42:45.020 | 14.6 s | passed |
| 40958113407 #2 | 22:10:55.592 | 22:11:10.526 | 14.9 s | passed |
| 40949930887 | 20:54:07.510 | 20:54:26.716 | 19.2 s | passed |

Every failure looked up sooner after install than every pass. Six runs show a
correlation, not a threshold, but they are consistent with a fast launch beating
the system's asynchronous registration of the new bundle's metadata. The local
experiments below support the cause directly.

Local experiments on Xcode 27.1 and an owned iOS 27.0 simulator reproduced the
same error by querying with Shopping uninstalled. `AppEntityDefinition.isInstance`
succeeds either way, so it cannot detect registration. In-process polling sees the
state change: lookups returned 400 until about 0.5–1 seconds after
`simctl install` finished locally, then resolved. The runner caches no negative result.

Both native cases now call `registeredDefinitions()` after `launch()`. It polls
the read-only `GroceryListEntity` suggested-entities query every 250 ms while,
and only while, the lookup fails with that exact domain and code. Any other
result or error returns or propagates unchanged. If the bundle is still absent
after 30 seconds of that state, the test fails with "App Intents metadata was not
registered". The bound covers the not-present wait. A single lookup that never
returns stays unbounded, as the existing lookups already were.
When a wait occurred, the native log records its duration. Selection, assertions,
action bounds and launch timeouts are unchanged, and nothing is retried.

## Post-boot simulator work saturates the runner (October 29)

Main push run [40974416453](https://github.com/mggarofalo/Shopping/actions/runs/40974416453)
on `d5ebd18` failed the first native case at `app.launch()`
(`ModernSiriActionTests.swift:79`). SHOPPING-262's registration wait runs only
after `launch()` returns, so it cannot cause this timeout. The native session log
splits the 60-second launch window as follows:

| UTC | Evidence |
| --- | --- |
| 23:49:58–50:01 | The native xcodebuild boots the simulator. The hosted session had shut it down. |
| 23:50:50–51:47 | Installing the UI test runner takes 56.7 s. |
| 23:52:45.419 | The runner creates the 60-second launch future. |
| 23:52:48.121 | Xcode receives the launch request. Xcode then logs nothing for 56.8 s. |
| 23:53:07–30 | The routine observer's `simctl list devices` and `ps -axo` each exceed 5 s. The host itself is stalled. |
| 23:53:44.895 | Xcode stores launch token 1. It installs Shopping in 2.6 s. |
| 23:53:45.459 | The runner times out. |
| 23:55:08 | The restarted session's launch request receives its token in 15 ms. The app launches 0.3 s later. |

Across 30 retained runs since `40748443094`, the request-to-token interval of
the first launch in each xcodebuild process ranged from 0.9 s to 81.5 s
(median about 15 s). The second launch in the same process always took under 0.1 s. Both
failures (56.8 s and 81.5 s) and two near-misses (52.2 s, 49.4 s) were first
launches. Within minutes of a boot, simple device operations were 10–30 times
slower than later ones. Installing the runner took 30–91 s soon after a boot,
compared with 1.5–4 s in the old single-invocation layout. The hosted
cases waited 100–400 s for their runner. The earlier Accessibility-loading abort and
service-hub timeout in this issue occurred in that same window.

A local measurement on Xcode 27.1 explains the window. It used a fresh
iPhone 18 Pro on iOS 27.0, on a 10-core Mac, with no tests running.
`simctl bootstatus` reported Finished after 24 s. The device's own process tree
(its `launchd_sim` and descendants) then used 5–9 cores for another 90 s. Load
average peaked at 150. After its first boot the device had used 668 CPU-seconds,
spread across about 300 daemons, widgets and extensions. No single process
dominated. A second boot of the same device used 366 CPU-seconds in about
65 s. Once that work finished, the device used less than 0.01 core apart from
short single-daemon bursts. On a runner with a few vCPUs, the same work takes
several minutes. Neither "Booted" nor bootstatus marks its end.

The runner previously let each xcodebuild invocation boot the shut-down
simulator. The native invocation therefore started its runner install, first
launch request and Shopping install during a fresh post-boot storm. The 60-second
launch budget then covered whatever share of the host that work left. This is
the common cause of the launch-token timeout, the stalled Accessibility load and
the slow hosted startup. The stale-PID failure fixed by session isolation was
a separate defect.

### Owned boot and settled device

`siri-schema-ci.py` now owns the simulator lifecycle around each test session.
Before the hosted and native `test-without-building` invocations, it:

1. Runs `simctl bootstatus <device> -b`, bounded at 300 s. Before the hosted
   phase this boots the device the runner created. Before the native phase it
   would boot the device again if the hosted session had shut it down. The boot
   happens after the build, so the build and the post-boot work do not contend
   for the runner.
2. Samples `ps` every 5 s and sums CPU time across the device's `launchd_sim`
   tree. The phase starts only after three consecutive intervals at or below
   1.0 core.

One readiness budget, now 1080 seconds (see
[the budget calibration](#readiness-budget-calibration-october-30)), covers both
phases' bootstatus and settle waits. Only time spent in those waits counts against it; build and test time do
not. A spent budget returns exit 124 and the test never starts. A device with no
process tree fails immediately. SIGINT or SIGTERM during the wait returns 130 or
143 and keeps the evidence, as for the supervised commands. A PID whose CPU time
drops counts as a new process. Processes that exit between samples are not
counted, so a burst of short-lived work can be missed. The three-interval run
limits the effect of that.

`SiriRegistration/<Phase>BootStatus.*` and `<Phase>Settle.json` retain each
wait's samples, outcome and wall time. Each phase's `Verdict.json` record carries
`device_ready_exit_code`. The phase's `started_at` and `wall_seconds` now exclude
readiness. Selection, assertions, the 60-second XCTest launch budget, test
timeouts and retry policy are unchanged. Because Xcode did not boot the device,
it leaves it booted. The post-run capture therefore collects the live
registration logs and metadata before its owned shutdown and delete.

### Local and hosted calibration

A local end-to-end run passed all 25 cases and the merged manifest. It used
Xcode 27.1, an owned iOS 27.0 iPhone 18 Pro and a 10-core Mac, with the boot
overlapping the build and a 0.5-core threshold. The device was still using about
6 cores of post-boot work after the 97-second build, and the hosted phase
settled after 56 s. The native bootstatus reported "Device already booted,
nothing to do", and that phase settled in 26 s. Hosted startup took 7.6 s. The
native runner installed in 0.1 s, and its first launch request received a token
in 0.2 s.

Hosted [Siri diagnostic 40979677660](https://github.com/mggarofalo/Shopping/actions/runs/40979677660)
on that first candidate (`e77059a`) changed the design:

- Overlapping boot and build stretched the build to 532 s.
- The device then took another 386 s to settle. It ran at 1.3–3.0 cores, with
  one isolated 0.58 sample, before falling to 0.35–0.57. The largest sample of
  about 3 cores indicates a 3-core VM.
- The hosted phase found the device already booted. It reached its runner in
  21.9 s, compared with 100–400 s before, and all 23 hosted cases passed in 35 s.
- After the hosted tests, the device ran steadily at 1.2–1.7 cores. Its largest
  cumulative consumers were the simulator's `diagnosticd` (412 CPU-s) and `apsd`
  (238 CPU-s). Locally, neither is significant.
- That first candidate charged the hosted test time to the budget. The native
  phase therefore failed readiness with exit 124 and never started. That
  accounting error is fixed.

The current candidate therefore boots after the build and uses a 1.0-core
threshold. That is one third of the hosted VM: above the settled level
(0.35–0.57 core), and below the sustained post-boot load (mostly 1.3–3.0
cores). It sits below the 1.2–1.7 cores that run 40979677660 showed after its
hosted tests. If that load recurs, native readiness fails with 124 instead of
starting the test. It also raises the
budget to 660 s, because a burst that does not overlap the build still has to
finish inside the budget. Settling cannot remove contention from other tenants
on the hosted machine. If launch timeouts recur while `Settle.json` shows a
settled device, that is the next boundary to examine.

Hosted [Siri diagnostic 40982349173](https://github.com/mggarofalo/Shopping/actions/runs/40982349173)
on `2dcfff5` passed all 25 cases. The per-phase and merged manifests passed. The
build took 155.9 s without contention. Hosted readiness then spent 76.6 s in
bootstatus and 428.2 s settling. The device ran at 1.5–4.1 cores until it
dropped to 0.36–0.47. That used 505 s of the 660 s budget. The hosted session
reached its runner in 17.4 s, and its 23 cases took 29.2 s.

The native bootstatus found the device already booted, and the device settled
in 26.5 s. The native session installed its runner in 1.1 s, against 30–91 s in
the split-session runs. It reached the runner in 3.6 s, against 84–325 s. Its
first launch request received a token in 1.6 s, and the app launched 5.0 s
after the request. The launch observer took no sample. The test step lasted
13 min 59 s, about the same as before, because readiness takes the post-boot
time that the tests used to spend.

One pass does not prove that the intermittent failure is cured. The evidence to
watch is the `HostedSettle.json` and `NativeSettle.json` wall times against the
shared readiness budget, and whether the native samples stay above 1.0 core
after the hosted tests. A
budget exit 124 would be a readiness failure with its samples retained, not a
launch timeout.

## Readiness budget calibration (October 30)

The first main push after the settle gate merged,
[run 40989182159](https://github.com/mggarofalo/Shopping/actions/runs/40989182159)
on `f2d3919`, failed Release SDK Build with readiness exit 124. No test ran.
`HostedBootStatus.json` shows bootstatus took 98.6 s, against 54.9 s and 76.6 s on
the two passing runs. `HostedSettle.json` then holds 63 samples over 562 s, all
between 1.16 and 4.43 cores (median about 2.0), until the shared 660 s budget
ran out at 02:19:41. The first sample came 47.6 s after the wait began, and the
next twelve 12–30 s apart instead of 5 s, because `ps` itself was starved. The
passing runs' early samples were also 9–17 s apart.

The gate measured the right thing, but the budget was too small for that
runner. Hosted [Siri diagnostic 40992872404](https://github.com/mggarofalo/Shopping/actions/runs/40992872404)
on the first fix candidate (`9a07f2c`, 900 s budget) then passed all 25 cases,
and needed 790 s of readiness:

| Run | Bootstatus | Hosted settle | Busy samples | Settled samples | Native settle | Readiness |
| --- | --- | --- | --- | --- | --- | --- |
| [40982349173](https://github.com/mggarofalo/Shopping/actions/runs/40982349173) | 76.6 s | 428.2 s | 1.10–4.13 | 0.36–0.47 | 26.5 s (0.44–1.16) | 532 s |
| [40984757588](https://github.com/mggarofalo/Shopping/actions/runs/40984757588) | 54.9 s | 416.2 s | 1.05–3.40, one 0.59 | 0.67–0.74 | 22.3 s (0.61–1.48) | 495 s |
| [40989182159](https://github.com/mggarofalo/Shopping/actions/runs/40989182159) | 98.6 s | over 562 s | 1.16–4.43 | not reached | not reached | about 730 s (estimate) |
| [40992872404](https://github.com/mggarofalo/Shopping/actions/runs/40992872404) | 93.2 s | 549.1 s | 1.19–4.42 | 0.41–0.48 | 146.4 s (0.40–2.09) | 790 s |

- **The work is a fixed launch sequence.** The final `HostedSettleProcesses.log`
  of each run lists the device's processes in PID order. All four runs launch
  the same order of poster, widget, intelligence, Fitness and remote-management
  services. Near its end each run launches `AppSSODaemon` and `GSSCred`. The
  settled runs went quiet at 294–295 processes, within 16 s of reaching that
  count. The failing run had reached `GSSCred` and 291 processes when its budget
  expired, and had launched 18 of them in its last 47 s, so it was at the end
  of the same work.
- **The failing runner was slower, not stuck.** Its device's processes had used
  1103 CPU-s, against 790–866 CPU-s for the whole settled sequence on the two
  faster runners and 1044 CPU-s on 40992872404. The same daemons cost 1.26–1.47
  times as much CPU time: `launchd_sim` 14.8 s against 10.1–10.9 s, and
  `diagnosticd` 158.5 s against 109–126 s. Its boot was also 1.3–1.8 times
  slower. No single daemon dominated on any run. `diagnosticd`, `apsd`,
  `amsengagementd` and `STExtractionService` led, but none had more than 15% of
  the total.
- **The 1.0-core threshold separates the two states.** While the sequence ran,
  three consecutive samples never fell at or below 1.0 core. Once it finished,
  every hosted sample was at or below 0.74 core.
- **After the hosted tests, a second, shorter tail can follow.** On
  40992872404 the process count stayed at 306, so nothing new launched. The
  device still ran at 1.2–2.1 cores, mostly 1.2–1.5, for 120 s, then fell to
  0.40–0.76, apart from one 1.74 sample that restarted the quiet run. Of the
  270 CPU-s the device used between the hosted and native process listings,
  which also span the hosted tests, `diagnosticd` used 102 and `apsd` 61.
  The earlier runs settled in 22–27 s. The 1.2–1.7 cores the first candidate
  saw after its hosted tests (40979677660) were probably the same tail. On
  40992872404 the tail
  ended by itself, and the first native launch reached its automation session
  12.3 s after the request.
- **Other signals are weaker.** A gate that waited for named daemons would
  encode this runtime's process list. A probe launch would add its own launch
  to a starved device without measuring the starvation. Neither would see the
  `apsd` and `diagnosticd` tail.

### Budget

Scaling the slower runner's CPU ratio (1.35) to the faster runners' busy
period puts the end of its work near 578 s. The three quiet samples make that a
hosted settle near 595 s, consistent with the 5–16 s the settled runs needed
after their final process count. With its 98.6 s boot and a native settle near
36 s, its readiness would have been about 730 s. 40992872404 measured 790 s.
The slowest measured boot, hosted settle and native settle combined come to
about 840 s.

The runner now gives readiness 1080 s. That is 1.29 times the slowest
combination, 1.37 times the slowest complete run, and about twice the two
fastest. Before readiness, 40992872404 spent 519 s on runner contracts, a 290 s
archive and a 174 s Siri build (40989182159 spent 450 s). Tests, capture and
upload took at most 196 s, on 40984757588; 1.4 times that is 275 s. With
1080 s of readiness, the worst case is 520 + 1080 + 275 = 1875 s. Job setup and one last `ps` overrunning the deadline
add about 65 s. The Release SDK Build and Siri diagnostic jobs therefore allow
35 minutes instead of 25. 40992872404 took 24 min 42 s, so the old 25-minute
limit would have cancelled a run only slightly slower, before its evidence was
retained. Overlapping the boot with the build is not an alternative: in
40979677660 it stretched the build to 532 s and still left 386 s of settling.

A contract replays the slowest measured phases through the real settle loop and
its quiet-sample rule. The hosted trace runs at 2 cores until 578 s, then 0.5.
The native trace runs at 1.3 cores for 131 s, close to the measured 146 s settle.
Both must settle within the budget
left after the 98.6 s boot, and the budget must exceed their total by a quarter.
The same contract checks that every job running the suite has a limit that
holds the worst case. A budget of 900 s or a 30-minute job limit fails it;
the job-limit check has about 225 s of slack at 35 minutes.

The threshold, sample count, interval, test selection, 60-second launch budget
and retry policy are unchanged. A readiness exit 124 remains a failure with its
samples retained. If a runner needs more than 1080 s, compare its
`HostedSettleProcesses.log` with the sequence above, and the `apsd` and
`diagnosticd` time between the hosted and native listings, before changing the
budget again.
