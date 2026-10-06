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
