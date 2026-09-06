# Plane project guidance

## Project

- **Workspace:** `dev`
- **Project:** `SHOPPING`
- **Project ID:** `b25c0cea-908f-4021-948f-434274ce2998`
- **Design review:** [SHOPPING-26](https://plane.wallingford.me/dev/projects/b25c0cea-908f-4021-948f-434274ce2998/work-items/dc144997-592d-4da6-9b3f-b6b8a5e034f7)
- **Architecture spike:** [SHOPPING-27](https://plane.wallingford.me/dev/projects/b25c0cea-908f-4021-948f-434274ce2998/work-items/5e924f74-ae8e-49b0-ab02-1653ffa7ecbb)

SHOPPING-26 is the current product specification. Its design replaces the original per-store trip and SwiftData-sharing sketches.

## Modules and roadmap

| Module | ID | Purpose |
|---|---|
| Phase 0: Planning & Repository Setup | `e81e73f2-eba5-478c-a854-0f9ac1951b61` | Historical planning and the confirmed design review. |
| Phase 1: Build & Sharing Architecture | `bf737d6a-19f8-4cf9-8db6-82df0e831252` | Shell, CI, local architecture, and the eventual sharing foundation. |
| Phase 2: Core Shopping Loop | `56692a47-d86b-40e6-b82e-edf96ac5efff` | Household needs, catalog purchase rules, filters, urgency, and one-time behavior. |
| Phase 3: Device & Data Validation | `cd9f93f5-ad3a-4384-a776-14f2f0628f81` | Local/simulated validation and physical-device persistence checks. |
| Phase 4: Household Sync & Sharing | `0a510d14-9e73-4776-b7b5-1cf8bac607d0` | Mandatory managed Core Data private/shared CloudKit sharing and two-phone evidence. |
| Phase 5: Polish & TestFlight | `f9721e39-88e1-4e87-a10c-b3c66b4ed5ca` | Release preparation, including sharing and recoverable clearing validation. |
| Phase 6: Post-MVP Explorations | `86a96d53-07da-4c9b-aacf-816245c1358f` | Optional import and pull-to-refresh work. |

Pull-to-refresh is deferred to SHOPPING-31. Events are removed from the product scope.

## States

Use `Backlog` for unstarted work, `Todo` for selected ready work, `In Progress` while implementation is active, and `In Review` while awaiting integration or review. Move verified completed work to `Done`; use `Cancelled` or `Duplicate` only when that disposition is confirmed. Do not mark an issue done merely because its branch exists: issue work is complete after its local squash integration and validation. An issue-level PR is not required; the milestone branch receives the phase PR.

## Readiness and blockers

1. Read the complete issue and its dependency relations in Plane.
2. Do not start blocked work. Prioritize ready issues according to their Plane priority and phase dependencies.
3. SHOPPING-24 (app shell and CI) and SHOPPING-28 (this guidance) can start immediately.
4. SHOPPING-27 depends on SHOPPING-24 for the intended local architecture sequence. It establishes the Core Data architecture and local test harness before model work.
5. SHOPPING-10 enrollment is incomplete. It blocks live CloudKit proof, not local development.
6. SHOPPING-30 requires SHOPPING-27 and SHOPPING-10, and is the gate for real shared-MVP evidence. Simulations do not substitute for it.

An obsolete SHOPPING-27 blocked-by-SHOPPING-10 relation was identified during the design review. Its removal must be verified in an authenticated supported Plane UI. The public removal endpoint returned 404, so no state change is assumed here; record the stale edge narrowly until it is removed. The intended dependency remains SHOPPING-27 → SHOPPING-24 only.

## Product contract

The MVP uses one active household grocery-demand list. Store screens filter that shared set; they do not create store-owned trips. A catalog item remembers its explicit purchase tags or `Any store`; a current need stores quantity, carted state, and `Normal`/`Urgent` urgency.

For selected store `S`, availability is `Any store OR explicitly tagged S`. `Must buy here` means `S` is the only explicit active tag and the item is not `Any store`; other eligible items are flexible. Include/exclude filters work on explicit tag membership, exclusions win, and cannot widen availability. Tags express household buying rules, not retailer stock.

Ordinary re-add reuses the catalog item and its tags, focusing the existing active need rather than duplicating it. One-time needs are separate occurrences: they sync and recover safely, but do not create catalog items, templates, future hints, autocomplete candidates, or learned defaults. Explicit remembering is required to promote one.

Clear-carted operations must be confirmed and recoverable. They target exact captured occurrence IDs and revisions, skip rows changed since capture, and do not delete catalog knowledge or overwrite a later uncart/re-add.

## Architecture and evidence

The recommended baseline is SwiftUI + Core Data + `NSPersistentCloudKitContainer` managed private/shared stores. SwiftData private-device sync does not establish household sharing. Treat managed sharing, CloudKit schema readiness, convergence timing, and two-phone behavior as unproven until SHOPPING-30 records real evidence.

The observed developer environment is Xcode 26.6 (17F113) with the iOS 26.5 iPhone 17 Pro runtime; the app targets iOS 17. Local validation is `xcodebuild test -project Shopping.xcodeproj -scheme Shopping -destination 'platform=iOS Simulator,id=15066BE0-662A-4573-AA67-12E84FA0C39C'`. CI pins `macos-15`, `/Applications/Xcode_16.4.app`, and iOS 18.5 on an iPhone 16 Pro. Local work may proceed while enrollment is missing, but the app cannot claim release-ready shared MVP behavior without SHOPPING-10 and SHOPPING-30.

## Branching and release

Keep the root checkout on `main` and create every issue, epic, and milestone checkout inside `.worktrees/` at the repository root. Use Plane-derived branches with an appropriate conventional prefix, such as `docs/shopping-28-plane-guidance`; Plane does not supply or require a Linear `gitBranchName`.

The phase milestone branch is the integration target. Optional epic branches within a phase target the milestone branch, then completed issue branches are squash-merged locally into their parent or milestone. At phase completion, open the milestone-to-`main` PR; CI and required approval are mandatory before merging.

Phase 2 local UI work is currently stacked on `milestone/phase-1` at `82669cd`. This carries the validated local persistence and fixtures while Phase 1 enrollment/live sharing proof remains open. Keep both milestones distinct; reconcile the phase-2 base after the approved phase-1 merge. A stacked branch is not evidence that the sharing gate is complete.
