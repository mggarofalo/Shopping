# Personal-cart positive waits — SHOPPING-229

Nine complete PersonalCart workflows passed before and after replacing 38 positive polling calls with the existing `existsOrAppears(timeout:)` helper. Test-command time fell from **281.915s to 241.134s**, saving **40.781s (14.5%)** in this one paired sample. Every selected method was faster. The [benchmark record](benchmarks/shopping-229.json) retains both complete reports, exact selections, commands, source revisions, environments and results.

The helper checks the current accessibility hierarchy, then falls back to the original timeout. It does not establish visibility, hittability, uniqueness or settled navigation. Those separate checks, expected values, negative windows, deliberate launches, UUID stores, same-store recovery without reseeding, and native Settings text-size transitions remain. No test or assertion was retired; the [ownership ledger](test-ownership.md) records the retained boundaries.

The legacy-discard workflow previously asserted immediate row absence after observing feedback, while `LegacyCartReviewView` displays that feedback before awaiting its refresh. The retained test waits boundedly for that exact row to disappear (three seconds), preserving both the feedback assertion and the subsequent relaunch/history checks. This states the asynchronous completion condition explicitly instead of relying on incidental polling delay. There are no sleeps, retries, expected failures, reduced timeouts or fixture substitutions.

| Complete workflow | Before seconds | After seconds |
| --- | ---: | ---: |
| testHouseholdSetupAccountFailureKeepsVisibleGroceriesAfterRelaunch | 19.822 | 17.531 |
| testLegacyCartRequiresExplicitClaim | 18.203 | 13.848 |
| testLegacyDiscardRemovesPendingCardAfterRelaunchAndKeepsEarlierHistoryRoute | 29.624 | 25.999 |
| testOtherPurchaseKeepsOwnEntryUntilExplicitBuyAnyway | 17.434 | 11.728 |
| testPersonalCheckoutAndRecoverySurviveRelaunch | 28.697 | 19.440 |
| testPurchasedRememberedItemCanBeRequestedAgain | 13.432 | 10.386 |
| testRetainedCartCanBeRemovedAfterHouseholdDisappears | 15.228 | 10.724 |
| testStorePickerCountsAtSystemLargeAndAccessibilityXXXL | 88.802 | 83.892 |
| testStorePickerCountsIgnoreSelectionAndSearchThenRefreshAfterCarting | 47.125 | 43.588 |

Both runs used Xcode 27.0 (27A266a), iOS 26.5, the same iPhone 17 Pro destination, serial execution and the coverage-enabled ShoppingFull plan narrowed to the same nine exact identifiers. The result audit required all nine to be unique, present and Passed, with no extras, skips or failures. Baseline source was clean `39026e31478945fbf149585992f1946c89f24e3c`; candidate source was clean `064e465`, whose only changes were the test file and ownership documentation.

Each run used a fresh separate DerivedData build, recorded separately from the test command. Before ran first, then after, with no concurrent local test workload. This single local pair is not a reliability distribution or evidence of hosted-runtime speedup. It does not establish the earlier hypothetical three-to-eight-minute full-suite saving. Do not add its 14.5% to the separate full-suite parallelism percentage: these measurements concern different scopes, and parallel scheduling changes the critical path.

Raw logs, phases, metadata and result bundles are retained in `/tmp/shopping-229-before/` and `/tmp/shopping-229-after/`. Final integrated-source validation remains required; these focused results do not attest a later phase SHA.
