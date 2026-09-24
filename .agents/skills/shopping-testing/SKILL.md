---
name: shopping-testing
description: Implement, diagnose, review, and measure Shopping tests and test CI while preserving fixture isolation, recovery coverage, and exact-commit validation. Use for Shopping test failures, new test coverage, or runtime investigations.
---

# Shopping testing

Read the repository's `AGENTS.md` and [test strategy](../../../docs/test-strategy.md). For CI, full-suite validation, or runtime work, also read [continuous integration](../../../docs/continuous-integration.md). These maintained documents own commands, environments, plan contents, and required gates. Follow the requested task's scope and authorization; this skill adds no permission to dispatch workflows or change policy.

## Implement or repair a test

- Choose the smallest layer that proves the behavior: deterministic rules belong in unit tests; persistence, rollback, replica ordering, and recovery belong in integration tests; user interaction and accessibility belong in UI tests. Keep a UI assertion when its proof depends on the user workflow.
- Each test that needs persistence gets its own store identity. UI fixtures use a fresh UUID path through `SHOPPING_UI_TEST_STORE_PATH`. A deliberate relaunch within that test reuses its store and removes `SHOPPING_UI_TEST_FIXTURE` so recovery is observed without reseeding. Do not share a store across tests to save launch time.
- UI element existence does not establish visibility or hittability. Use stable identifiers, bounded waits, and bounded scrolling or filtering to bring the intended control onscreen before tapping. Preserve the assertion that follows the interaction; coordinate taps must not conceal a missing target.
- For positive UI existence assertions, use the shared `existsOrAppears(timeout:)` helper to check the current hierarchy before polling. Keep the timeout fallback. Do not substitute it for negative assertions, optional probes, disappearance waits, or visibility and hittability checks.
- Removing polling delay can expose a transient overlay that earlier waits incidentally outlasted. Before tapping an obscured control, assert that the specific obstructing feedback has disappeared within a bound; an always-present toast host and `isHittable` alone cannot prove the tap will reach a circular button. Preserve the single action and its resulting-state assertions instead of adding sleeps or retries.
- A destination navigation title can exist while the outgoing and incoming content both remain in the accessibility tree. Before resolving a control shared by both screens, wait boundedly for an unambiguous query or scope it to a proven destination container. Keep the expected-value assertion separate; do not use `firstMatch` or filter by the expected value to conceal duplicates or wrong state.
- Review expensive automation in helpers as well as test bodies. Repeated hierarchy queries and individual `typeText` calls cross the automation boundary. Batch contiguous typing when intermediate input behavior is not under test, and verify the resulting field value. Preserve deliberate launches, terminations, and UI steps that establish persistence or recovery behavior.
- Diagnose the failed assertion and result-bundle evidence before changing waits. A slow or failed UI interaction is not by itself an app performance regression. Keep failures visible: no success-on-error wrappers, retries, disabled assertions, expected-failure annotations, or baseline reductions as a runtime fix. Use the documented capability-skip rules only for a genuinely unavailable capability.

Run the affected test selection first, then the validation required by the change and repository workflow. A small unrelated edit does not acquire a full-suite requirement merely by loading this skill.

## Investigate runtime

Use the [runtime measurement commands](../../../docs/test-strategy.md#runtime-measurements) and [measured investigation](../../../docs/shopping-full-runtime.md). Reuse their reporting framework rather than adding another timer or parser.

1. Capture source revision and dirty state, toolchain/runtime, test plan and selection, worker count, simulator, and build conditions before the baseline. Preserve the raw result bundle, logs, phase records, and report.
2. Find the largest measured cost. Separate simulator startup, build, test, coverage, and reporting wall time. Inspect slow tests and their activities to distinguish setup, launch, waits, hierarchy queries, typing, and assertions. Summed test duration is not elapsed wall time when tests overlap.
3. Make one focused change and run a targeted comparison with the same test inventory and environment. A changed toolchain, test selection, cold/warm build, or worker count must be stated. Do not infer a suite-wide saving from a small sample. Stop repeating an experiment when gains are unclear or correctness is unresolved.
4. For sharding or process reuse, verify fixture isolation, runner/app ownership, recovery boundaries, and the merged test inventory and results. Compare elapsed time and resource cost; do not assume more workers are faster. Coordinate simulator use so independent agent runs do not contaminate measurements.
5. Retain failed measurements and their exit status. Record before/after evidence and remaining bottlenecks in the investigation document. Separate measured results from hypotheses and policy recommendations.

Use focused benchmarks during exploration. When the final candidate requires remote `ShoppingFull`, follow the existing sequence: commit the candidate, pass [the local full runner](../../../.github/scripts/run-local-shopping-full.sh), push that exact unchanged commit, then use [the dispatch helper](../../../.github/scripts/dispatch-remote-shopping-full.sh). Edits after attestation invalidate that candidate's proof. Preserve the hosted exact-SHA preflight, coverage collection, coverage baselines, and exhaustive test inventory. Workflow-policy changes need their own authorization.

For an independent evidence review when delegation is authorized, use the repository's `shopping-test-reviewer` agent. Supply the diff and artifact paths; it reviews without launching tests or dispatching workflows.
