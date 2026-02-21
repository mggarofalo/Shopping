# LINEAR.md

Guidance for AI agents working with the Linear workspace for this project.

## Workspace Structure

- **Team:** Mggarofalo (ID: `a4aff05d-41e6-45dc-b670-cdb485fef765`)
- **Project:** Shopping (ID: `3432e1df-65d8-4645-b206-3208b9429ba8`)

## Labels

Every issue should have appropriate labels. Labels tell agents what skills/tools are needed and what kind of work the issue represents.

### Type Labels

| Label | Meaning |
|-------|---------|
| `Feature` | New user-facing functionality |
| `Improvement` | Enhancement to existing functionality |
| `Bug` | Defect fix |
| `cleanup` | Removal, housekeeping, dead code |
| `dx` | Developer experience, tooling, local dev |
| `testing` | Test infrastructure, test suites |
| `epic` | **Parent issue — do NOT work directly, work its children** |
| `infra` | CI/CD, build config, deployment |
| `docs` | Documentation only — no code changes |

## Milestones (Execution Phases)

All active issues are assigned to a milestone. Milestones are ordered and represent sequential phases:

| Milestone | Description | Status |
|-----------|-------------|--------|
| **Phase 0: Planning** | Define app concept, data model, tech stack | **COMPLETE** |
| **Phase 0: Repository Setup** | GitHub repo, CI, guidance files, config | Ready to start |
| **Phase 1: Project Scaffold & Models** | Xcode project + SwiftData models (no Mac needed) | After repo setup |
| **Phase 2: Core UI** | All SwiftUI views (can write without Mac) | After models |
| **Phase 3: Mac Setup & First Build** | Acquire Mac, first Xcode build, device deploy | When Mac available |
| **Phase 4: CloudKit Sync & Sharing** | iCloud sync + multi-user sharing | Requires Mac + Dev Account |
| **Phase 5: Polish & TestFlight** | UI polish, app icon, TestFlight distribution | Pre-ship |
| **Phase 6: Data Seed** | Import catalog from Google Sheet or Receipts project | Future/optional |

## Priority Semantics

Priority reflects **execution readiness**, not importance:

| Priority | Meaning | Agent Action |
|----------|---------|--------------|
| **Urgent (1)** | Ready to start now, critical path | Pick these first |
| **High (2)** | Ready or blocked by one step | Pick when blockers clear |
| **Medium (3)** | Blocked by 2+ steps | Do not attempt yet |
| **Low (4)** | Far future | Ignore until predecessors are done |

## How to Determine "What's Next"

1. **Query:** `list_issues` with `project: "Shopping"`, `state: "backlog"` (or "todo")
2. **Filter:** Exclude Done, Canceled, and Duplicate statuses
3. **Skip epics:** If the issue has label `epic`, skip it and work its children instead
4. **Check blockers:** For each issue, use `get_issue` with `includeRelations: true` and inspect `blockedBy`. If ANY blocker is not Done, the issue cannot start.
5. **Sort:** Among unblocked issues, sort by priority (Urgent > High > Medium > Low)
6. **Pick:** The first unblocked issue at the highest priority is "what's next"
7. **Parallel work:** Multiple unblocked issues at the same priority can be worked in parallel

## Working with Linear Issues

### Before starting work
1. Find the issue using the decision rules above
2. Read the full issue description with `get_issue`
3. Check `blockedBy` relations — do not start blocked work
4. Move the issue status to "In Progress" with `update_issue`
5. Use the `gitBranchName` from the issue for your feature branch

### After completing work
1. Move the issue status to "Done" with `update_issue`
2. Check if completing this issue unblocks downstream work
3. Update any downstream issues if their blockers are now all resolved

### Creating new issues
- Always assign to team "Mggarofalo" and project "Shopping"
- Set milestone to the appropriate phase
- Set priority based on readiness (see Priority Semantics above)
- Add `blockedBy` relations if the issue depends on other work
- Add `blocks` relations if other issues depend on this one
