# Routine CI startup measurement (SHOPPING-207)

Keep simulator boot and compilation serial. The hosted overlap experiment did not
show an elapsed-time improvement, so the candidate coordinator and its dedicated
unit tests were removed. App tests, plans, coverage and acceptance assertions did
not change. No cache was added.

## Hosted comparison, October 6, 2026

| Run | Source | Simulator/build scheduling | Startup and build elapsed |
| --- | --- | --- | ---: |
| [Fresh baseline 37452316585](https://github.com/mggarofalo/Shopping/actions/runs/37452316585) | `9b5007b5279615c96d5268c8da42894ce0ec5b07` | Serial: 2m 29s boot, 4m 57s build | **7m 26s** |
| [Candidate 37452503258](https://github.com/mggarofalo/Shopping/actions/runs/37452503258) | `179d0b0` | Boot and build started together; both required to succeed | **9m 35s** |

GitHub Actions step timestamps give these wall times, rounded to seconds. The
baseline interval was 10:49:44–10:57:10 UTC; the candidate preparation interval
was 10:51:36–11:01:11 UTC. The candidate was 2m 09s slower in this sample. The
candidate interval includes runtime listing and simulator creation. Use the
combined elapsed interval, not the sum of overlapping phase durations.

Both runs used macOS 15, Xcode 16.4, an iPhone 16 Pro/iOS 18.5 simulator, cold
DerivedData, one acceptance build, independent Fast coverage and the same six
acceptance UI methods. App source, project and test-plan inventory were unchanged.
The candidate also had additional script checks and immutable Action refs; those
checks execute outside the measured preparation interval. Hosted machine
variation remains a limitation: this single pair does not establish a general
causal slowdown. It does establish that the proposed optimization lacked the
positive evidence required to retain its extra concurrency and cleanup logic.
A second candidate PR run was already in progress when this result became
available; it is not used as a completed comparison. The final PR validates the
retained serial approach.

The earlier [October 5 run 37334150448](https://github.com/mggarofalo/Shopping/actions/runs/37334150448)
used 9m 44s for serial startup/build and 18m 14s for the whole job. That variation
reinforces why the fresh comparison matters and why neither one sample nor the
historical difference should be presented as a reliable speedup.

## Evidence and future decisions

The linked runs retain `fast-summary-*` artifacts with exact toolchain metadata,
phase records, result counts, test identifiers and coverage. The PR records final
conclusions and post-merge validation. Failed or canceled runs remain visible;
no test retries or reduced assertions were introduced.

Build caching remains a separate measured hypothesis. A correct DerivedData
cache would need keys covering toolchain, SDK, architecture, build settings and
source/dependencies, plus measurements of restore/save cost. This investigation
provides no evidence that this added complexity would improve feedback time.

This phase changes CI/release tooling rather than app behavior. Focused fake-tool
tests and hosted ordinary CI validate the relevant boundaries; no local or hosted
ShoppingFull dispatch was used for this experiment. The existing exact-commit
ShoppingFull attestation gate remains unchanged.

## Current critical path and instrumentation (SHOPPING-253)

The October 29 analysis reused two successful October 28 runs; it launched no
new build or simulator experiment. [PR run 40786036765](https://github.com/mggarofalo/Shopping/actions/runs/40786036765)
tested GitHub's merge `05a92004`; [main run 40788317225](https://github.com/mggarofalo/Shopping/actions/runs/40788317225)
tested `bbfddc6`. Their Git tree is identical (`2373cd54`), also matching PR head
`940739f`. This establishes source equivalence, not equivalent host conditions
or an exact-SHA manual Full attestation. Both passed 827 Fast, six acceptance
and 22 Siri tests without skips, plus unchanged coverage gates.

The pinned job used Xcode 16.4/iOS 18.5 on macOS 15.7.9. Monotonic phase records
in each `fast-summary-*` artifact give these durations:

| Phase | PR run (seconds) | Main run (seconds) |
| --- | ---: | ---: |
| Simulator preparation | 199.251 | 115.828 |
| Shared acceptance build | 368.432 | 288.211 |
| Fast command | 143.415 | 254.546 |
| Acceptance command | 319.800 | 252.103 |
| Coverage and two summary commands combined | 19.463 | 10.734 |

The faster build in the main run coincided with a slower Fast command. Fast's
summed test durations were 183.118 seconds in the PR run but 158.969 seconds on
main; those sums cannot be subtracted from wall time to derive startup overhead
because tests can overlap. Successful Fast artifacts retain timing reports but
not the raw result bundle needed to reconstruct its host-startup activities.
This pair does not establish a code speedup or regression.

GitHub job timestamps also show that the limiting job changes: Build & Test
(native) took 18m42s versus Release SDK Build (native)'s 14m42s in the PR run;
on main they took 16m10s and 18m16s respectively. Jobs run concurrently, so
improving only the pinned build cannot guarantee faster completion of both gates.
The release job includes the required unsigned archive and modern Siri proof;
its time must not be added to the concurrent pinned job's time.

### What the retained logs establish

- `simctl bootstatus` reports data migration in both pinned runs. Its terminal
  elapsed value is 1m22s in the PR run and 1m07s on main, while the enclosing
  preparation phases take 199.251 and 115.828 seconds. That phase also lists
  runtimes, creates and boots the simulator, then writes the keyboard tutorial
  preference. It is not all boot time. Individual commands lack timing records;
  log arrival timestamps do not safely attribute the residual time to one command.
- The shared build ran with `-quiet`. Its retained Actions log has warnings and
  notes, but no per-command build timing summary. It cannot identify a Swift
  file, linking, asset compilation or dependency scanning as the bottleneck.
- Main's Siri phase records separate its build (143.682 seconds), hosted run
  (355.062 seconds), and native UI run (211.120 seconds). The hosted session
  begins at 23:43:15.763 and reports its runner ready at 23:48:19.464: a
  303.701-second interval containing installation, launch and service setup.
  It records an interrupted `DTServiceHubClient` connection at 23:47:33.580.
  The native session begins at 23:49:20.385; its selected suite begins at
  23:51:23.690, 123.305 seconds later. These are startup/control observations,
  not proof of an app-code cause. SHOPPING-249 owns that investigation.

Raw source-located extracts and downloaded job metadata are retained locally
under the Git common directory at `shopping-test-timings/shopping-253-analysis/`.
The linked Actions runs remain the hosted source; local copies are evidence,
not a substitute for hosted authentication.

### Next measurement and decision

1. Emit Xcode's native `-showBuildTimingSummary` for the existing acceptance
   build and include its existing `FastBuild.log` in the normal summary artifact.
   Remove `-quiet` so it cannot suppress informational timing output. The timing
   wrapper already captures both output streams and preserves the command status;
   no new collector, parser, build setting, scheduling change or native run is
   needed. The next ordinary CI run must confirm the summary is emitted and
   retained on the pinned toolchain. Command totals can overlap and are not a
   critical-path profile; use them to select a narrower follow-up, not to claim
   elapsed savings.
2. Investigate service-startup recurrence under SHOPPING-249 using its retained
   session logs before changing simulator lifecycle or timeouts. The main run
   demonstrates that this job can determine overall feedback time even when the
   pinned build is faster.
3. If pinned simulator preparation remains a target, measure its existing
   commands separately before changing their ordering. Do not infer a safe
   command removal from aggregate phase time.

Keep serial scheduling and omit build caching. Neither new sample overturns
SHOPPING-207's measured decision or establishes cache restore/save benefit.
The instrumentation changes observability only; it claims no runtime reduction.
