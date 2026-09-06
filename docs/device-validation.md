# Device validation

## Current evidence

| Area | Evidence | Status |
|---|---|---|
| Baseline persistence and UI | SHOPPING-29 baseline: 130 unit and 27 UI tests passed | Verified |
| Initial compact simulator suite | Initial SHOPPING-9 full compact run: 19 passed, 13 failed | Superseded by repaired regression below |
| Grocery editing | All 5 focused GroceryEditing UI tests pass | Verified |
| Checklist recovery | One-time clear, relaunch, and recovery focused test passes | Verified |
| Interrupted clear | Exit-before-acknowledgement focused test passes | Verified |
| Filters and catalog | Include/exclude, category/urgent, catalog accessibility reset, archive/restore, dirty archive cancellation, and one-time creation focused tests pass | Verified |
| Promotion and viewport bounds | Link-existing promotion passes in `/tmp/Shopping9-visible-insets.xcresult`, including original identity and saved rules | Verified |
| Full-row accessibility audit | Passed in the complete regression, but earlier identical-code runs reported contrast failures; separate diagnostics identify headings behind the navigation bar | Intermittent; remains open |
| Complete compact regression | iPhone SE (3rd generation), iOS 26.5: **32 passed, 0 failed, 0 skipped, 0 expected failures** in `/tmp/Shopping9-compact-regression.xcresult` | Passed September 6, 2026 |
| Compact audit after natural-scroll-end helper repair | `/tmp/Shopping9-compact-audit-followup.xcresult`: 1 passed | Passed |
| Larger iPhone, dark mode | iPhone 17 Pro, iOS 26.5: 4 device checks passed in `/tmp/Shopping9-large-dark.xcresult`; the initial fifth check stopped at an impossible preferred scroll position | Setup repaired |
| Larger dark-mode full audit after setup repair | `/tmp/Shopping9-large-audit-edge.xcresult`: audit runs and reports partially unsupported Dynamic Type on “Only buy at Costco” | Unresolved |

The current UI candidates use an inline Groceries title, active All styling and trait, adaptive colors, intrinsic quantity sizing, `AnyLayout`, omitted empty partitions, primary chip color, a 96pt accessibility bottom scroll margin, and accessibility containment IDs for pinned top and bottom groups. The five new SHOPPING-9 tests remain active; no failures are ignored. CI and further device evidence are recorded in the [SHOPPING-9 work item](https://plane.wallingford.me/dev/projects/b25c0cea-908f-4021-948f-434274ce2998/work-items/ec77ce14-de18-4a55-aad7-934c3eff749a).

The boundary audit found a Must buy here accessibility frame beginning above the navigation bar. That diagnostic is not proof that every nil accessibility query has the same cause. A later contrast-only diagnostic identified `Urgent · Pantry` at y=-43.5…103, partly behind the navigation bar. No unidentified failure is filtered based on these examples. The attempted hard scroll-edge and disabled-button styles were removed after failing to resolve the audit.

The complete default-text screen audit also reported Dynamic Type, clipping, and contrast findings during diagnosis. Those remain open. The maintained tests distinguish control audits (element detection, hit region, descriptions, and traits on All/Costco/Catalog/Settings) from the full-row audit. Separate tests measure body/caption/quantity growth across four system sizes, long-name quantity/cart/uncart at accessibility XXXL, and default-size quantity/filter controls. A passing control audit is not a full accessibility pass.

Independent Terra and root reviews found no concrete regression in the reviewed diff. A second independent subagent reviewer was unavailable because of the session thread limit. The audit setup accepts the natural scroll end only when the complete target cell remains visible; the full audit still runs without filtering. No temporary app diagnostic hooks remain. Both simulators are restored to light appearance. SHOPPING-9 stays In Progress; the work is isolated and has not been integrated into the milestone.

## Physical-device and live-sharing gates

No physical devices are currently available. Before release, verify on both household phones:

- VoiceOver order, labels, traits, focus movement, and 44pt controls on Groceries, Carted, recovery, add/edit, filters, and promotion.
- Default-size and larger-text typography, including compact-device truncation, pinned header/footer visibility, long names, long notes, and purchase-rule labels.
- Offline creation, carting, scoped clear/Undo, recovery after force-quit/relaunch, and reconnect behavior.
- Reduce Motion behavior during cart, clear, recovery, navigation, and confirmation.
- Real two-account household sharing: invitation acceptance, owner/participant writes, concurrent edits, store tags, recovery, revocation, and convergence.

Simulator checks do not validate VoiceOver behavior on hardware, airplane-mode persistence, or live CloudKit sharing.

Record device model, OS version, build, date, and pass/fail evidence for each physical check. SHOPPING-30 owns real invitation, transport, permissions, and convergence evidence; Apple Developer enrollment (SHOPPING-10) remains a prerequisite. The earlier request to connect a phone remains unanswered.
