# Routine CI startup measurement (SHOPPING-207)

The simulator's readiness and the acceptance compilation have separate owners in
`prepare-ci-tests.py`. After creating one pinned simulator, the coordinator runs
the existing timing wrapper for each concurrently. Tests begin only after both
succeed. Simulator readiness retains a five-minute bound; the preparation step
has a 16-minute bound inside the unchanged 30-minute job. Failures and cancellation
stop remaining child process groups. Separate temporary phase files are merged
into `FastPhases.jsonl`, including failures, without concurrent file writes.
The simulator log and unmerged records join the existing failure artifact.

The shared build still targets the same simulator UDID, `ShoppingAcceptance`, and
`DerivedData`. Fast and the six selected acceptance UI tests still run separately;
the existing built/result selection checks and Fast-only coverage gate are unchanged.
The build command may internally wait for simulator readiness; only hosted evidence
can establish how much useful overlap Xcode actually performs.

## Baseline

[Successful run 37334150448](https://github.com/mggarofalo/Shopping/actions/runs/37334150448),
October 5, 2026, used commit `9b5007b5279615c96d5268c8da42894ce0ec5b07`.
GitHub job/step timestamps give:

| Measurement | Wall time |
| --- | ---: |
| Build & Test job | 18m 14s |
| Simulator startup | 3m 20s |
| Acceptance compilation | 6m 24s |
| Startup plus compilation (serial) | 9m 44s |
| Fast tests | 2m 20s |
| Acceptance UI | 5m 03s |

These are Actions timestamps, rounded to seconds, not the finer phase records.
The pinned environment is macOS 15, Xcode 16.4, iOS 18.5, iPhone 16 Pro, with a fresh
simulator and no DerivedData cache. This historical run is context, not a controlled
before/after experiment if application source or hosted images differ.

## Candidate experiment

Run ordinary Swift CI on the committed candidate, preserving its exact SHA, run URL,
run attempt, job timestamps, and `fast-summary-*` artifact. Do not dispatch
`ShoppingFull` for this experiment. No shared local simulator is needed.

For a controlled comparison, use a second commit that changes only the coordinator
to wait for simulator readiness before launching the same build command, then run
ordinary Swift CI under the same pinned environment. Compare the same application
source and test inventory; retain failed runs as well as successful ones. Compare
job wall time and the startup/build interval from earliest `started_at` to latest
`finished_at`; overlapping phase durations must not be added. Keep Fast and UI
execution times separate so their variance cannot masquerade as startup savings.
Check exact passing acceptance identifiers, Fast inventory and coverage, and both
phase exit codes. A further repeat is justified if observed savings are smaller
than run-to-run variation. Retain overlap only if it improves elapsed time without
new failures. Record the final hosted result here before merge.

Caching is deferred until this measurement identifies remaining build cost.
DerivedData caching would require measured restore/save cost and a correctness key
covering toolchain, SDK, architecture, build settings and source/dependencies. There
is no evidence yet that its added complexity buys a reliable improvement.

## Local validation

The preparation unit tests substitute temporary executables for `xcrun` and
`xcodebuild`. They require both branches to start before either can finish, check
exact build arguments, preserve build and boot failures, and bound hung startup.
The existing acceptance contract and timing reporter tests also pass. These tests
exercise orchestration only; they do not prove real Xcode overlap or simulator
readiness. No local simulator or compiler was used for this change.
