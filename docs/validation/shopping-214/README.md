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

## Remaining quantity gate

The supplied reference PNG and its replacement both failed supported Library
materialization with HTTP 403, including one bounded retry each. Their actual
pixels have not been viewed. The screenshot-dependent quantity redesign is
still pending. Existing quantity placement, actions, bounds and pending-state
behavior are unchanged in this draft. Simulator captures below establish
independent layout evidence; they do not replace the requested reference.

## Before and after

Captured using isolated fixtures on iPhone 17 Pro, iOS 26.5, Xcode 27.0
(27A266a). Before images use the clean base; after images use the uncommitted
spacing implementation before the marketing-version edit, so Settings still
shows 1.5.3 and a dirty source identifier.

| Screen | Before | After |
| --- | --- | --- |
| Settings, standard text | [Before](before-settings.png) | [After](after-settings.png) |
| Store control, accessibility XXXL | [Before](before-scope-accessibility.png) | [After](after-scope-accessibility.png) |

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

Final `ShoppingFast` passed **747 tests**, with zero failures or skips
(709 XCTest and 38 Swift Testing). This run includes the final adaptive-label
source. Result bundle: `FinalFast.xcresult`; focused final bundles:
`FinalManagementCorrected.xcresult` and `SpacingLongTitle.xcresult`.

Two independent read-only adversarial reviews found no confirmed code defects.
Their validation feedback added an enabled-selection assertion, long-title
scroll-reachability proof and a test ownership entry.

## Release gate

Both iPhone and Watch Debug/Release marketing versions are prepared as 1.5.4.
The parent must resolve the remaining reference/quantity design and confirm the
release gate before merge or upload. Recheck required CI on the exact merged
main SHA, use the established read-only inventory/audience preflight, and choose
an unused build number. The previous tag identifies 1.5.3 (33); a proposed next
number is not a reservation. Existing publication intent remains Michael's
internal Garofalo Home and Beka's external Household Testers. External beta
review submission must be reported separately from availability.
