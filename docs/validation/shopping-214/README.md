# SHOPPING-214 layout evidence

This draft prepares visual patch 1.5.4 from 1.5.3 (33), source
`1eb751c130713875e8f957fe0429e1c57dfb7e82`. It preserves saved-data meaning
and existing product capabilities. No persistence, managed-model, CloudKit,
signing, permissions or audience changes are included.

## Design

Item and management rows share a 44-point content minimum, followed by four
points of vertical padding and two-point list insets. This produces a 56-point
minimum row, with intrinsic growth for multiline content. Personal-cart rows
now apply the same padding order. Stores, Categories and People apply padding
once in both normal and native selection modes.

Native lists and editor forms inherit the same 56-point floor. Settings uses
native insets consistently. Different semantic controls remain free to grow;
no fixed row height or text-size cap is introduced. Catalog names wrap, and
shared store/filter labels measure their text independently of the symbol.
Archived management status moves below the full-width name at accessibility
sizes rather than compressing the name into a narrow column.

## Quantity design

Michael clarified that the former number and plus/minus controls felt appended
below the redesigned row, and that adding a quantity in the editor was hard to
find. The replacement uses a compact native disclosure button (`6×`) beside the
main item content. Store metadata sits below the name for these rows, keeping a
simple quantity-bearing row at the shared 56-point minimum. The 44-point target
belongs to the button label and remains separate from the item-edit target.
Personal-cart quantity readouts use the same multiplication notation.

Tapping the quantity opens a native numeric-entry form with Clear quantity,
Cancel and Done. Quantity entry comes first; the complete item name remains
available below it even at accessibility sizes. Create/edit forms always show
a labeled Quantity field with an Optional placeholder, an explicit clear action
and the 1–99/blank guidance. No hidden gesture is required.

Raw text remains a draft. Blank means unspecified, valid input is a whole ASCII
number from 1 to 99, and invalid text disables saving. Cancel discards quick
edits, unchanged Done does not mutate, and an observed item revision change
blocks submission until the sheet is reopened. Existing command and pending
mutation guards remain in place. Other editor draft fields retain with the last
valid optional quantity while raw quantity text is invalid; no draft schema or
saved-data meaning changes.

Both Library references returned HTTP 403 after their bounded attempts, so their
pixels were never available. Michael subsequently authorized this design from
his description and actual simulator inspection; that access failure is no
longer an implementation blocker.

## Before and after

Captured using isolated fixtures on iPhone 17 Pro, iOS 26.5, Xcode 27.0
(27A266a). Before images use the clean base. Quantity images use the final uncommitted
1.5.4 candidate. Earlier Settings/scope images use the spacing implementation
before the version edit, so Settings shows 1.5.3 and a dirty source identifier.
Screenshots establish appearance; CI below establishes the committed candidate.

| Screen | Before | After |
| --- | --- | --- |
| Grocery quantity, standard text | [Before](before-quantity-rows.png) | [After](after-quantity-rows.png) |
| Create/edit quantity discovery | [Before](before-quantity-editor.png) | [After](after-quantity-editor.png) |
| Settings, standard text | [Before](before-settings.png) | [After](after-settings.png) |
| Store control, accessibility XXXL | [Before](before-scope-accessibility.png) | [After](after-scope-accessibility.png) |

[Native quantity entry](after-quantity-entry.png) and the
[largest-text numeric entry](after-quantity-entry-accessibility.png) show the
replacement interaction. [Largest-text rows](after-quantity-rows-accessibility.png)
show intrinsic growth and separate edit targets. The
[scrolled accessibility editor](after-quantity-editor-accessibility.png) keeps
the full label, value, clear action and guidance readable.
[Personal cart](after-cart-quantity.png) uses the matching readout.

[Catalog long title, standard text](after-catalog-long-title.png) shows the
complete wrapped title and supporting notes. Very large text can create a row
taller than the viewport; the [scrolled accessibility capture](after-catalog-notes-scrolled-accessibility.png)
shows the complete end of the supporting notes remains reachable. The
[archived store capture](after-archived-store-accessibility.png) shows its full
name and status below at accessibility XXXL. These two captures use the final
source implementation with 1.5.4 prepared.

## Validation record

The unchanged baseline build and two existing appearance workflows passed. The
first spacing run passed all six existing appearance methods; the new management
method exposed a test locator that searched only static text, while normal rows
are accessible buttons. The corrected locator accepts both native forms and
retains geometry assertions. The focused editor/inline-quantity, management
and People-selection run passed 3 tests. Final adaptive-management and People
checks passed 2 tests with no failures or skips; the strengthened long-title
scroll-reachability check passed separately. Failed local result bundles are
retained in the task workspace, including an invocation rejected before any
tests because it named a nonexistent test target.

The spacing candidate passed `ShoppingFast` with **747 tests**, zero failures
or skips. The final quantity candidate adds strict blank/ASCII/1–99 validation
coverage. The final five-workflow visual run passed with zero failures or skips
(`QuantityFinalVisuals.xcresult`). Final `ShoppingFast` passed **748 tests**, zero failures or skips
(710 XCTest and 38 Swift Testing; `QuantityFinalFast.xcresult`).

Quantity validation includes add/change/clear/cancel/save/reopen/relaunch,
invalid-input draft recovery with other edited fields, actual target-edge taps,
compact geometry, one-time promotion identity, filters, light/dark appearance,
and four Dynamic Type categories. Twelve focused UI methods passed in
`quantity-regression.log` before the final growth assertion failed: the
accessible quantity element has a 44-point touch floor, so its height need not
increase between every small text category. The corrected assertion preserves
nondecreasing height, requires growth beyond the standard target at the largest
size, and retains strict title/notes growth and touch-size checks. That process
was interrupted during the ChatGPT restart, leaving an incomplete result bundle;
its log is retained and is not reported as a completed suite.

`QuantityPresentation.xcresult` separately records passing catalog acceptance,
quantity lifecycle and long-name accessibility workflows. Earlier failed local
bundles are retained, including fixes for a legacy fixture lacking draft scope,
an input-helper cursor issue and an initial sheet-state capture issue. Final
screenshots are exported from successful workflows, not failure snapshots.

The first spacing-only CI run passed Fast and Release SDK Build but failed one
catalog readiness wait. Its retained hierarchy already showed “Oat milk”; the
wait now uses a native field predicate with the same timeout and expected-value
assertion. The affected workflow passed locally. Final exact-head CI is required
on the completed PR; no remote full-suite dispatch is claimed.

The final visual bundle retains three invalid-frame and two internal QoS
runtime warnings. The clean baseline also records an invalid-frame warning.
No warning was tied to a confirmed defect in this scoped review; this is not a
warning-free or physical-device performance claim.

Two independent read-only adversarial reviews covered both spacing and the
quantity follow-up. Findings in invalid-draft retention, captured revision
handling, stale test queries and actual touch-target sizing were resolved.
Validation feedback added enabled-selection, long-title scroll-reachability,
edge-tap and interrupted-draft checks. The final production review found no
remaining confirmed defect; it does not claim atomic cross-device conflict
handling beyond the existing writer contract.

## Release gate

Both iPhone and Watch Debug/Release marketing versions are prepared as 1.5.4.
The parent must confirm the design and release gate before merge or upload. Recheck required CI on the exact merged
main SHA, use the established read-only inventory/audience preflight, and choose
an unused build number. The previous tag identifies 1.5.3 (33); a proposed next
number is not a reservation. Existing publication intent remains Michael's
internal Garofalo Home and Beka's external Household Testers. External beta
review submission must be reported separately from availability.
