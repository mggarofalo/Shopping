# List presentation

SHOPPING-138 extends the compact grocery/cart treatment across the iPhone and Watch apps. Rows use the system surface: dark gray in dark appearance and the native light equivalent. The app's existing appearance preference remains authoritative.

## Native surfaces

| Platform / surface | Treatment |
| --- | --- |
| iPhone groceries, catalog, add browser, legacy/personal cart | Native inset-grouped List; category headers use small caption text outside the row surface. |
| iPhone stores, categories and people | Inset-grouped List in both ordinary and native selection/reordering modes. |
| iPhone Settings, setup, category-fill suggestions | Inset-grouped List. |
| iPhone checkout, purchases, saved carts, old-cart review and earlier cleared groceries | Inset-grouped List. |
| iPhone editors and filters | Native Form supplies grouped rows. This includes catalog, grocery, one-time, personal-cart item, store/category creation, management name, and both filters. |
| Watch groceries, cart, store chooser, item card, checkout, recovery, result and unavailable/setup state | Native plain List supplies the standard Watch row surface. |

Catalog's recently-added tint remains a temporary highlight; ordinary rows use the native background. Empty-state illustrations, section headings, store/filter bars and floating action bars are not item rows and may remain transparent or use the surrounding screen background. No row clips, custom selection painting or gesture recognizers replace native List behavior.

## Content sizing

Rows have a minimum touch target, not a fixed height. SHOPPING-140 places equal vertical padding around the intrinsic text container, so additional lines grow the row instead of consuming the space left by a minimum-height row. Grocery and personal-cart text use 12-point top/bottom padding; Catalog combines 10-point content padding with its 2-point row insets. SHOPPING-144 reserves two thirds of Catalog row content for its one-line, tail-truncated title and multiline notes, and one third for a top-aligned, trailing-aligned store summary. An 8-point gap separates the columns. A small private SwiftUI Layout supplies this explicit ratio and measures intrinsic heights; standard stacks do not express unequal proportional columns. ViewThatFits selects complete store-name prefixes plus the number omitted. The final count can wrap at accessibility sizes; omitted archived restrictions retain an archived annotation, unresolved rules remain explicit, and full names and rules remain in VoiceOver and the editor. Supporting notes grow vertically with the same padding. Assigned people appear in small parenthesized text immediately after the grocery title, without a person icon; the full “For …” accessibility value and native row actions are retained. Short metadata shares horizontal space where it fits and falls back to a vertical arrangement at constrained widths or larger text sizes. Grocery quantity buttons remain independent controls; their actions must never trigger Edit. Personal-cart rows use metadata already present in their snapshot; layout changes do not add fields to the sync model.

## Validation ownership

Existing appearance, accessibility, catalog add, management selection and checkout tests own native behavior. Watch UI tests own swipe actions, store selection, item cards, checkout/recovery and floating-button clearance. Inspect their screenshots as well as their interaction results: a passing tap does not establish visual consistency.

Apple APIs: [Layout](https://developer.apple.com/documentation/swiftui/layout), [insetGrouped](https://developer.apple.com/documentation/swiftui/liststyle/insetgrouped), [listRowBackground](https://developer.apple.com/documentation/swiftui/view/listrowbackground(_:)), and [ViewThatFits](https://developer.apple.com/documentation/swiftui/viewthatfits).

Catalog swipe and accessibility actions reflect the current grocery occurrence: Add when absent, Remove from list when present. Removal uses the captured occurrence/revision and the existing recoverable removal command, stays in Catalog, and does not delete the catalog record or private cart membership. Undo remains available through the standard feedback action and reports when newer changes prevent restoration. Ambiguous imported duplicate needs expose Review duplicates while healthy catalog rows retain their normal actions. A stale Add action that discovers an existing occurrence stays in Catalog and explains the current state.
