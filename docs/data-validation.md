# Local data validation

These checks describe local Core Data and simulator behavior. They do not prove CloudKit transport, invitation handling, two-account convergence, or background notification timing. SHOPPING-10/30 remain the enrollment and live-sharing gates.

## Verified local behavior

- A remembered grocery retains purchase rules when re-added; one-time groceries remain independent unless explicitly remembered.
- Clear and individual removal use captured occurrence IDs and revisions, preserve catalog knowledge, skip stale changes, and retain durable recovery.
- Two local contexts exercise both save orders for competing quantity writes and independent store-tag additions. Resetting both contexts observes the last local scalar save and the union of independent relationship additions. These are local merge-policy observations, not a whole-set last-writer guarantee for CloudKit tags.
- Concurrent remembered occurrences are retained with their separate quantities, notes, urgency and carted states. Explicit per-occurrence removal chooses which current demand to keep; it does not sum quantities or discard the archived candidate's data. Undo refuses to recreate a conflicting active remembered occurrence.
- A DEBUG-only UI-test fault exits the app immediately after a clear transaction commits and before the UI acknowledges it. Relaunch restores the same one-time occurrence through Recently cleared, with its purchase notes intact and no catalog item created. The test uses `_exit(0)` to bypass graceful teardown; it tests abrupt termination at this boundary, not arbitrary disk corruption or live remote races.
- Schema fixture tests close their persistent stores before deleting temporary files. The first SHOPPING-29 run no longer emitted SQLite vnode-unlink warnings.

## Identity checks

Management screens resolve the selected list to its canonical household object and persistent store, rejecting globally ambiguous IDs. Staged store drafts retain their original household/list object identities. Writers revalidate the selected list inside the same transaction, so a duplicate imported after the UI renders cannot authorize a stale save.

## Evidence

- Core shopping loop: 119 persistence tests and 26 UI tests passed locally for Phase 2 at `10df0ed`.
- SHOPPING-29 final source: 130 persistence tests passed across `/tmp/Shopping29-final.xcresult` and the focused `/tmp/Shopping29-category-final.xcresult`. The final broad run passed 129/130; its sole failure was an old fixture expecting a duplicate household identity to remain usable. The fixture now uses a distinct foreign household to isolate duplicate-category behavior, and all category tests pass. Separate duplicate-household rejection coverage also passes.
- All 27 UI tests passed in `/tmp/Shopping29-full.xcresult`; the three Category/Catalog tests affected by the final scope changes passed again in `/tmp/Shopping29-final.xcresult`. Combined distinct local coverage is 157 tests.
- The full run initially exposed a new test reading managed objects off its private context queue. The corrected test exports immutable object IDs and evaluates its retained stale snapshot on-context; it passes with Core Data concurrency debugging enabled.
- The final service also rejects category removal when an imported one-time revision cannot be incremented, rolling back every relationship change; its new overflow regression passes.
- Independent Terra adversarial review and a root second pass found and resolved management scope gaps. Final follow-up review found no surviving issue. Additional reviewer threads were unavailable, so the second pass was performed by root.
- Phase 2 follow-up `e37934c` guards transient null accessibility geometry in promotion UI tests; its four focused UI tests pass. Both upstream Phase 2 CI runs passed: 34003424964 (PR) and 34003423916 (push), on `e37934c`.
- Physical readiness: `xcrun devicectl list devices` returned no connected devices on September 5, 2026. Simulator evidence remains separate from required two-iPhone acceptance.
