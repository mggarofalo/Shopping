# Test redesign (SHOPPING-119)

This follow-up starts from the validated SHOPPING-108 candidate `e341831206907272a6314934619432e843100998`. It applies the user-approved reduction in redundant UI setup and routine CI scope. [Proof ownership](test-ownership.md) records every consolidated scenario and retained owner. The earlier [runtime investigation](shopping-full-runtime.md) contains the timing framework, toolchain research and prior optimization evidence.

## Design

Apple recommends a reduced pull-request plan with unit tests and key UI workflows on one platform, with broader regression testing separately. ShoppingAcceptance contains the unchanged Fast target and six explicit UI workflows. CI builds their products once, runs Fast independently to preserve its coverage baseline, and runs the selected UI workflows from the same products. Built-product and result guards verify the selection. [Apple WWDC22 guidance](https://developer.apple.com/videos/play/wwdc2022/110361/)

The six workflows cover catalog add, remembered draft cancel/save/relaunch, one-time creation, scoped checkout/undo, committed-clear interruption recovery and accessibility checklist controls. Broader interaction, appearance and recovery variants remain in ShoppingFull. Routine CI runs on PRs and main pushes; removing milestone-push runs avoids duplicate work for the same open PR. The exact-SHA local attestation remains mandatory before a manual hosted Full confirmation.

## Focused changes

- Seed the prerequisites for linking an existing catalog item and resolving a promotion conflict. UI still performs every promotion decision. The complete creation, cancellation, promotion and relaunch flow remains separate.
- Seed the inactive Café au lait catalog item before testing suggestion selection. Catalog creation retains its own UI owner.
- Change successive search queries in the same open editor while keeping urgency, store eligibility, one-time exclusion, editing and renewal assertions.
- Consolidate grocery, cart and checkout ordering into one scenario using the same three carted items. Both within-category and cross-category rendered ordering remain checked.
- Seed an archived catalog item before the separate dirty-restore cancellation scenario. Keep the complete archive/filter/restore UI route. Consolidate the duplicated existing-catalog-item editor route and retain its keyboard assertion in the existing owner.
- Check fixture state and identity at the fast layer, including SQLite reopen for promotion fixtures and archived-item isolation.

## Measurement method

Use serial test-without-building runs on the same local Xcode 27.0 / iOS 26.5 simulator. Baseline products were built from the clean, unchanged Phase 18 commit; candidate products use a separate DerivedData directory. Record build and test command time separately, alongside per-case result-bundle durations. Setup removed from one scenario is accounted for by its retained proof owner, rather than treating a lower test count as evidence of equal coverage.

The first baseline selection passed all eight tests. Its post-test CoreSimulator diagnostic collection stalled after test completion, consistent with the previously documented collector issue. Keep this command overhead visible and separate from the case-duration comparison. No diagnostics, failures or retries are suppressed.

## Validation and measured results

The [machine-readable benchmark evidence](benchmarks/shopping-119.json) includes every selected test, result, phase command, toolchain, source state and product-input manifest hash.

| Focused change | Before | After |
| --- | ---: | ---: |
| promotion conflict prerequisite | 87.06s | 42.25s |
| promotion link prerequisite | 85.60s | 33.69s |
| inactive suggestion prerequisite | 35.04s | 26.46s |
| active-match query reuse | 67.14s | 55.87s |
| store-default query reuse | 86.83s | 72.15s |
| archived catalog prerequisite | 36.25s | 27.98s |
| consolidated existing-item route including transferred assertion | 97.95s | 94.10s |
| ordering consolidation | 24.75s | 22.09s |

All compared tests passed without skips or retries. Loop 1 consolidates nine original scenarios into eight, reducing their summed case time from 478.24s to 342.90s (28.3%). The unchanged scoped-checkout control passed in 31.84s versus 30.33s, and the unchanged complete promotion/relaunch control passed in 59.99s versus 60.05s. Loop 2's three cases totaled 134.20s before and 122.09s after. These are single paired samples. The roughly four-second existing-item-route saving is modest; further exploration stopped as returns diminished.

The initial eight-test baseline command took 1083.88s including the 600-second diagnostic timeout, versus 357.76s for the first candidate command. Those command times are **not** a valid whole-suite speedup claim: the inventory consolidation is accounted for separately and diagnostic collection dominates the difference. The supplementary four-case baseline command and three-case second-loop command are recorded separately in the JSON; the unchanged ordering baseline is used only for its case duration.

An Acceptance build successfully supplied Fast, Full-targeted and Acceptance enumeration without rebuilding. The local UI enumeration enabled exactly the six canonical methods, and the executed-result guard verified six passes with no skips or extra methods. The selected UI command took 190.53s; the independent Fast command passed all 218 tests in 10.22s. These reuse the same Acceptance build. All 18 Python contracts and the unchanged Full-attestation/TestFlight shell checks passed; two independent whole-diff reviews found no actionable defect. Final inventory and exact-SHA local/hosted validation are recorded in [PR44](https://github.com/mggarofalo/Shopping/pull/44). The local runner retains final reports under `.git/shopping-test-timings/<SHA>/`; hosted reports are attached to their GitHub Actions run.

The configured coverage gate deliberately rejects local Xcode 27 because the repository has no baseline for it. Its exit status is retained, and raw local coverage remains available; no version override or baseline change is used. Required coverage enforcement stays on pinned hosted Xcode 16.4. This is a toolchain-baseline limitation, not a passing local coverage-gate claim.

## Remaining costs and policy

The serial UI regression suite remains the largest cost. Automation transactions, navigation, typing and independent app launches dominate the deterministic rules layer. Reusing built products is safe; sharing mutable app state or stores across scenarios would undermine isolation. Prior two-worker experiments did not establish reliable whole-command gains, so the serial default remains.

The approved quick acceptance plan and duplicate-run removal are implemented here. Automatic nightly Full runs, expanding the OS/device matrix, changing required checks, and enabling sharding remain separate policy decisions. Full retains its local exact-SHA gate; scheduling it automatically would require an explicit replacement authorization and validation design.
