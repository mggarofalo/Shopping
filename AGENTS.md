# AGENTS.md

## Source of truth

Use [PLANE.md](PLANE.md) for issue tracking. New work belongs in Plane project `SHOPPING` (`b25c0cea-908f-4021-948f-434274ce2998`) in workspace `dev`; do not create new Linear issues. [LINEAR.md](LINEAR.md) preserves old links only.

Before implementation, read the full Plane issue, its dependencies, and its acceptance criteria. Work only an issue that is ready under the rules in `PLANE.md`, then update its state through Plane. Keep the issue identifier in the branch and commit provenance.

## Repository and branch workflow

- The repository root at `Source/Shopping` always remains checked out on `main`.
- All branch work uses a worktree under `.worktrees/` at the repository root. This includes milestone, epic, and issue branches.
- Create issue branches using an appropriate conventional prefix, such as `feat/`, `fix/`, `docs/`, or `chore/`, followed by `shopping-<number>-<short-description>`. Plane has no `gitBranchName` requirement.
- A milestone branch (`milestone/phase-N`) is the integration target for all work in that phase. An optional epic branch within a milestone is based on, and merges back into, that milestone branch; it does not independently target `main`.
- Squash-merge each completed issue into its milestone or epic worktree, using a Conventional Commit message that includes the Plane issue, then remove the issue worktree and branch when safe.
- At phase completion, open one PR from the milestone branch to `main`. CI and the required PR approval must pass before merge. Do not merge or force-push without the authorization required by the active workflow.

Example:

```text
main
  └── milestone/phase-1  (PR → main after approval)
        ├── chore/shopping-24-app-shell
        └── docs/shopping-28-plane-guidance
```

## Product constraints

The MVP has one shared household grocery-demand list, projected through store filters. It does not create per-store trip lists or use a Finish/Reopen workflow.

Catalog store tags are saved purchase constraints, not retailer inventory. A store view first applies `Any store OR tagged for the selected store`; text, category, urgency, and advanced tag filters can only narrow that eligible set. Urgent never makes an ineligible item available at a store.

Reusable catalog items retain their tags when re-added. A normal flow maintains one active remembered need per catalog item. One-time needs have independent identities, stay available for sync and recovery, and never seed catalog suggestions or templates without explicit user action. Current-need urgency is `Normal` or `Urgent` and is never remembered on the catalog item.

Clear-carted behavior must be scoped, confirmed, and recoverable after relaunch. It must use the captured occurrences and revisions rather than rerunning a broad query, and must preserve catalog data and newer changes.

## Sharing architecture and validation

Use SwiftUI with Core Data and `NSPersistentCloudKitContainer` as the intended baseline for managed private/shared CloudKit sharing. Do not describe household sharing as implemented or proven until SHOPPING-30 demonstrates it on both iPhones. SwiftData private-device sync is not evidence of household sharing.

SHOPPING-10 enrollment blocks real sharing proof, not local architecture, models, UI, or simulated two-replica tests. The observed environment is Xcode 26.6 (17F113) with an iOS 26.5 iPhone 17 Pro runtime; the app targets iOS 17. Run local validation with `xcodebuild test -project Shopping.xcodeproj -scheme Shopping -destination 'platform=iOS Simulator,id=15066BE0-662A-4573-AA67-12E84FA0C39C'`. CI pins `macos-15`, `/Applications/Xcode_16.4.app`, and iOS 18.5 on an iPhone 16 Pro. Do not carry forward the old acquire-a-Mac or code-without-building assumptions.

## Code conventions

- Use SwiftUI and the architecture selected by SHOPPING-27.
- Use 4-space indentation, `let` where possible, `guard` for early exits, and Swift naming conventions.
- Add focused tests for behavior with persistence, recovery, filtering, or sharing consequences.
- Add `#Preview` blocks to SwiftUI views.
- Use Conventional Commits: `feat`, `fix`, `docs`, `refactor`, `test`, or `chore`, with an optional scope.
