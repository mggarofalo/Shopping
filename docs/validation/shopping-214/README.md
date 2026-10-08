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

The quantity is quiet, unboxed `6×` typography in a native 44-point button.
Every grocery uses a leading name and store metadata below it, so adding or
clearing quantity never moves the store summary. Standard rows place quantity
beside the content; accessibility sizes give the name the full width and place
metadata and quantity on the next line. Long notes cannot push quantity to the
bottom. Personal-cart readouts use matching multiplication notation.

Tapping quantity opens a compact native sheet that grows with text size with the full wrapping
item name, a numeric field, inline clear, Cancel and Done. Accessibility sizes
show context before opening the keyboard. The item editor places the always-
visible optional Quantity field immediately after Name, ahead of remembrance
and notes. Invalid input alone reveals the range guidance.

The refinement drew from [Grocery's design rationale](https://conradstoll.com/blog/2022/5/22/grocery-30),
[Crouton's official product imagery](https://crouton.app/), and
[AnyList's quantity entry](https://help.anylist.com/articles/add-item-quantity/).
It uses system typography, native grouping and a restrained action tint; no
custom badge borders, extra pencils or persistent increment/decrement controls.
Crouton's image informed hierarchy, not an unverified claim about its interaction.

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
(27A266a). Before images use the clean 1.5.3 base. Refined images use the final
uncommitted 1.5.4 source; Settings therefore displays a dirty source identifier.
The standard compact sheet uses a text-scaled 260-point native detent; accessibility
sizes use the large sheet. Multiple native detents caused iOS to expand on keyboard
focus, so that behavior was rejected through actual simulator screenshot review.
The Form remains scrollable for long context and feedback. Screenshots establish
appearance; the PR's exact-head CI establishes the committed candidate.

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
the full label, value and clear action readable. Guidance appears for invalid input.
[Personal cart](after-cart-quantity.png) uses the matching readout.
[Full item context before the keyboard](after-quantity-context-accessibility.png)
remains readable at accessibility XXXL. The [scrolled end of a long grocery note](after-grocery-notes-scrolled-accessibility.png)
shows the final line clear of the tab bar. Pixel review also checked metadata
font growth and spacing across standard L, XXXL, accessibility M and XXXL.

[Catalog long title, standard text](after-catalog-long-title.png) shows the
complete wrapped title and supporting notes. Very large text can create a row
taller than the viewport; the [scrolled accessibility capture](after-catalog-notes-scrolled-accessibility.png)
shows the complete end of the supporting notes remains reachable. The
[archived store capture](after-archived-store-accessibility.png) shows its full
name and status below at accessibility XXXL. These two captures use the final
source implementation with 1.5.4 prepared.

## Validation record

The records below distinguish the original spacing/quantity candidate from the
refinement. The current PR head requires fresh CI; earlier green CI does not
validate a later design. Refined screenshots are captured from successful
workflows and inspected as actual pixels, including the full end of long notes.


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

## Refined candidate validation

`StudioFinalVisuals.xcresult` passed all **12 selected UI workflows**, zero
failures or skips: seven appearance/spacing workflows, notes and quantity editing,
cart quantity persistence, accessibility long notes, four-size growth and long-name
quantity/cart interactions. The subsequent compact-sheet correction passed its
focused keyboard/context/Cancel check in `StudioCompactSized.xcresult`.
`StudioFinalQuantity.xcresult` then passed all **3 final-presentation workflows**:
quantity add/change/clear/cancel/save/reopen/relaunch, four-size growth with XXXL
invalid-input feedback, and largest-text long-name quantity/cart interaction.
The final [XXXL validation screenshot](after-quantity-validation-large-text.png)
shows the field, inline clear and complete feedback above the keyboard.

Earlier refinement failures remain retained: the old notes/text-child UI queries
no longer matched the deliberate single-announcement accessibility layout;
quantity tests now establish visible keyboard bounds before interacting with the
presented field. The compact-sheet test exposed actual automatic expansion with
multiple native detents. A scaled compact detent plus a large accessibility sheet
resolved it, and the final field-value, persistence, geometry and Cancel assertions
remain intact. No failed result is reported as a passing completed suite.

`StudioFinalFast.xcresult` passed **748 tests**, zero failures or skips.

Independent source/test review found no outstanding substantive defect. Actual
pixel review verified normal and accessibility rows, full wrapping item context,
long-note final lines, standard and accessibility item forms, and keyboard-visible
compact/invalid entry. These are simulator results, not physical-device VoiceOver,
CloudKit convergence or performance proof. The required hosted checks must pass on
the exact current PR head; their results are recorded on PR #84.

## Release gate

Both iPhone and Watch Debug/Release marketing versions are prepared as 1.5.4.
The parent must confirm the design and release gate before merge or upload. Recheck required CI on the exact merged
main SHA, use the established read-only inventory/audience preflight, and choose
an unused build number. The previous tag identifies 1.5.3 (33); a proposed next
number is not a reservation. Existing publication intent remains Michael's
internal Garofalo Home and Beka's external Household Testers. External beta
review submission must be reported separately from availability.
