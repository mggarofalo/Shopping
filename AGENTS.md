# AGENTS.md

This file provides guidance to AI agents working with code in this repository.

## Prerequisites

- **Xcode 16+** — build, test, and run the app (macOS only)
- **iOS 17+ deployment target** — required for SwiftData
- **Swift 5.9+** — included with Xcode 16
- **Apple Developer Account** ($99/yr) — required for CloudKit and TestFlight (Phase 4+)

## Development Workflow

When working on tasks that are expected to result in code changes, follow this standard process:

1. **Linear Issue Management**
   - Check if a Linear issue exists for the work
   - If no issue exists, create one with:
     - Clear title describing the work
     - Description with acceptance criteria
     - Appropriate labels (see LINEAR.md)
     - Team assignment to "Mggarofalo"
   - Link the issue ID to your work
   - **See [LINEAR.md](LINEAR.md)** for full workspace structure, milestone phases, priority semantics, and how to determine "what's next"

   **Linear MCP Access:**
   - Linear is available via MCP server - you can directly create/update issues
   - Team is "Mggarofalo" (team ID: `a4aff05d-41e6-45dc-b670-cdb485fef765`)
   - **Do not check for teams** - the team information is stable and documented here
   - Use the team name "Mggarofalo" directly when creating issues
   - All issues should be assigned to project "Shopping" and an appropriate milestone

2. **Branch Strategy (Two-Tier)**

   This project uses a hierarchical branching model: **milestone branches** for CI/PR gating, optional **parent branches** for epics, and **issue branches** for individual work items.

   **Milestone branches** (one per phase):
   - Created when work on a milestone begins, named `milestone/phase-N` (e.g., `milestone/phase-0`)
   - All issue work within that phase merges locally into the milestone branch
   - When the milestone is complete, open a **PR from the milestone branch to `main`**
   - The PR triggers CI — this is the safety net that catches issues the agent may have missed
   - After PR merge, delete the milestone branch

   **Parent branches** (for epics with multiple children):
   - When an epic has multiple child issues, create a parent branch using the epic's `gitBranchName`
   - Parent branch is created off `main` (or the milestone branch if one exists)
   - Child issue branches are created off the parent branch and squash-merge back into it
   - When all children are complete, the parent branch gets a PR to `main`
   - This keeps related changes grouped and avoids polluting `main` with intermediate work

   **Issue branches** (one per Linear issue):
   - Branch off the parent branch (if epic) or milestone branch, NOT `main`
   - Use the `gitBranchName` from the Linear issue
   - Merge locally into the parent/milestone branch via squash merge (no PR needed)
   - Delete the issue branch after merge

   ```
   main
     ├── milestone/phase-1                              (PR → main)
     │     ├── mggarofalo/mgg-135-create-xcode-...     (squash-merge into milestone)
     │     └── mggarofalo/mgg-136-swiftdata-models-... (squash-merge into milestone)
     │
     └── mggarofalo/mgg-144-item-catalog-view-...      (epic parent, PR → main)
           ├── mggarofalo/mgg-145-list-builder-...      (squash-merge into parent)
           └── mggarofalo/mgg-146-shopping-checklist... (squash-merge into parent)
   ```

   **Worktrees (mandatory for all branch work):**
   - **ALWAYS** use worktrees for issue and milestone branches — do NOT checkout branches in the main repo
   - The main repo at `Source/Shopping` must **always stay on `main`** and never be switched to another branch
   - Use `/worktree <issue-id>` to create an isolated working directory in `.worktrees/`
   - **ALWAYS** create worktrees in `.worktrees/` at the repo root — NEVER as sibling directories
   - This gives agents full filesystem control in their worktree without affecting the main repo

3. **Merging Issue Work into Parent/Milestone Branch**
   - All merges happen inside worktrees — never checkout branches in the main repo
   - Remove the issue worktree, then merge from the parent (or milestone) worktree:
     ```bash
     git worktree remove .worktrees/mggarofalo-mgg-135-create-xcode
     cd .worktrees/milestone-phase-1
     git merge --squash mggarofalo/mgg-135-create-xcode-project-structure
     git commit -m "chore: create Xcode project structure (MGG-135)"
     git branch -D mggarofalo/mgg-135-create-xcode-project-structure
     ```
   - If no parent/milestone worktree exists yet, create one:
     ```bash
     git branch milestone/phase-1 main
     git worktree add .worktrees/milestone-phase-1 milestone/phase-1
     ```

4. **PR: Parent/Milestone → Main**
   - When all issues are complete, push the branch and open a PR:
     ```bash
     cd .worktrees/milestone-phase-1
     git push -u origin milestone/phase-1
     gh pr create --title "Phase 1: Project Scaffold & Models" --body "..."
     ```
   - The PR triggers CI (build + test) — this is the checkpoint that surfaces issues
   - After CI passes and the PR is approved, merge into `main`
   - Clean up worktree and branches:
     ```bash
     cd <repo-root>
     git worktree remove .worktrees/milestone-phase-1
     git branch -d milestone/phase-1
     git push origin --delete milestone/phase-1
     git pull   # update main with the merged PR
     ```

5. **Direct Commits to Main**
   - Only use for non-Linear work like:
     - Trivial typo fixes
     - Documentation updates
     - Tooling/build configuration
   - **NEVER** commit Linear-based work directly to main
   - When in doubt, create a branch

## Build and Test Commands

```bash
# Build (requires Xcode on macOS)
xcodebuild build -scheme Shopping -destination 'platform=iOS Simulator,name=iPhone 16 Pro'

# Run all tests
xcodebuild test -scheme Shopping -destination 'platform=iOS Simulator,name=iPhone 16 Pro'

# Clean build
xcodebuild clean -scheme Shopping

# Build from Xcode
# Cmd+B (build), Cmd+R (run), Cmd+U (test), Cmd+Shift+K (clean)
```

## Architecture

This is a SwiftUI + SwiftData iOS app with CloudKit sync and sharing.

### Tech Stack

| Layer | Technology | Notes |
|-------|-----------|-------|
| UI | SwiftUI | Declarative, modern iOS UI framework |
| Persistence | SwiftData | Apple's native ORM for Swift types |
| Sync & Sharing | CloudKit (via SwiftData) | Built-in sync and multi-user sharing |
| Distribution | TestFlight | Internal beta distribution |

### Project Structure

```
Shopping/
  App/
    ShoppingApp.swift              # @main, SwiftData container setup
  Models/
    Store.swift                    # Store entity
    Category.swift                 # Category entity (managed list)
    Item.swift                     # Item entity (core catalog)
    ShoppingList.swift             # Shopping list (trip to a store)
    ShoppingListItem.swift         # Item on a list (quantity + checked)
  Views/
    ContentView.swift              # TabView root
    StoreListView.swift            # Store management
    CategoryListView.swift         # Category management
    ItemCatalogView.swift          # Browse/edit master item list
    ItemDetailView.swift           # Edit single item
    ShoppingListsTab.swift         # All shopping lists
    ListBuilderView.swift          # Build a list for a store trip
    ShoppingChecklistView.swift    # In-store checklist
  CloudKit/
    SharingController.swift        # CloudKit share invitation UI
  Preview Content/
    PreviewSampleData.swift        # In-memory sample data for previews
```

### Key Patterns

- **SwiftData `@Model`** — persistence via class annotations (like EF Core entities)
- **`@Query`** — live database queries that drive UI updates (like reactive DbSet)
- **`@Bindable`** — two-way binding to model properties (like Blazor `@bind`)
- **`@Environment(\.modelContext)`** — dependency injection for data access
- **View modifiers** — SwiftUI's composition pattern (`.searchable()`, `.sheet()`, etc.)

### Data Model

- **Store** — where you shop (Costco, Aldi, Publix, etc.)
- **Category** — managed list of groupings (Produce, Dairy, Canned Goods)
- **Item** — master catalog entry, tagged with stores + category + anyStore flag
- **ShoppingList** — a trip to a specific store on a date
- **ShoppingListItem** — an item on a list with quantity and checked state

Key relationship: Item ↔ Store is many-to-many. ShoppingListItem references the master catalog Item (not a copy).

## Swift Coding Standards

- Use `let` over `var` unless mutation is needed
- Use 4-space indentation (Apple convention)
- Use `final class` for `@Model` types
- Prefer `String` over `String?` unless nil is semantically meaningful
- Use trailing closure syntax for the last closure parameter
- Use `guard` for early returns instead of nested `if`
- Use Swift naming conventions: `camelCase` for properties/methods, `PascalCase` for types
- Add `#Preview` blocks to all views for Xcode previews

## Commit Message Convention

Use [Conventional Commits](https://www.conventionalcommits.org/) format:

```
<type>(<scope>): <description>

[optional body]
```

**Types:**
- `feat` - New feature
- `fix` - Bug fix
- `docs` - Documentation only
- `refactor` - Code change that neither fixes a bug nor adds a feature
- `test` - Adding or updating tests
- `chore` - Maintenance tasks, dependencies, build config

**Scopes** (optional): `models`, `views`, `cloudkit`, `ui`

**Examples:**
- `feat(models): add SwiftData models for Store and Category`
- `feat(views): implement shopping checklist with check-off animations`
- `chore: configure CloudKit container and entitlements`
- `docs: update agent guidance documentation`
