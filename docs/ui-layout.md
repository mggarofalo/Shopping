# Shared list and selection UI

Catalog is the reference for item rows. Stores is the reference for selection and creation controls. Read this with the [responsiveness contract](ui-responsiveness.md) before changing these screens.

## Item rows

- Catalog uses `ShoppingItemColumns` for 2:1 description/store columns. Groceries consistently place store metadata below the leading name, with inline person assignment. Adding or clearing quantity must not move the store summary to a different column.
- Keep the grocery edit button at least 44 points tall, including the space beside short titles. `ShoppingItemColumns` aligns the first text baselines so the smaller store label stays aligned when that hit area grows.
- Use `ShoppingItemStoreSummary` for store-name fitting and omitted-store counts. The row must still announce the complete store summary, including archived restrictions and unresolved identities. Keep selected-store purchase-rule symbols accessible through the row value.
- Apply `shoppingItemRow()` to the entire row: measure the content, enforce the 44-point minimum, then apply four points of vertical padding on each side. Apply `shoppingListRowInsets()` once. Applying padding before the minimum produces a shorter row and was the source of Grocery/Catalog drift.
- Use the same `shoppingItemRow()` padding order for personal-cart and Stores/Categories/People management rows, including native selection mode. Do not apply the padding again inside a nested button label.
- `ShoppingManagementRowLabel` keeps archived status beside short names at standard sizes and below the full-width name at accessibility sizes.
- Native lists and forms inherit a 56-point row minimum from the iPhone app root. Settings uses native insets throughout; do not mix thin item insets into native navigation or picker rows. Controls, supporting copy and multiline fields retain their intrinsic height.
- Catalog names wrap vertically, just like grocery names; never force one line to normalize row heights.
- Quantities use quiet, unboxed `6×` typography in a native button beside the main grocery content. Keep its 44-point hit region inside the label. At accessibility sizes the name gets the full width, followed by metadata and quantity side by side; long notes must not push quantity to the end of the row. The name announces the complete summary once.
- Quantity entry uses a compact native form that grows with text size with a full wrapping item name, numeric keyboard, inline clear button, Cancel and Done. At accessibility sizes, show full context before opening the keyboard. The item editor places labeled Quantity immediately after the name, with an Optional placeholder. Show range guidance only for invalid input. Accept blank or whole ASCII digits from 1 through 99; invalid text must not silently clear a quantity. Preserve other retained draft fields using the last valid quantity.
- Capture quantity and revision together when presenting the quick editor. Unchanged Done performs no mutation; an observed item change blocks submission until the editor is reopened. Existing parent command/pending guards still apply.
- Minimum height is not fixed height. Notes, quantity controls and accessibility-sized text may expand a row. Keep the quantity entry button at least 44 points in each direction and allow their layout to adapt at accessibility sizes. Never clip supporting text to force equal heights for different content.

## Store and filter controls

Use `ShoppingScopeLabel` for Store and Filters, including menus. Resolve the unselected Store placeholder at the caller; never replace a matching saved store name. It owns the font, symbol scale, multiline fitting and minimum label height. Keep the store picker left and Filters right in the scrolling list header; stack them at accessibility sizes. Keep the X to clear store scope. Do not add a redundant All control.

## Home selection

Settings owns the home picker, placed at the start of its native scrolling list.
Keep the current home name, local-device distinction, and accessible selection
value on that control. Groceries, Catalog and carts show only read-only home
context when multiple homes or a retained local home make it useful. Keep the
onboarding, unavailable-home and invitation routes in `PersistenceRootView` so
home selection remains reachable before the tab interface is available.

## Select and Add controls

Use `ShoppingCollectionToolbar` for Catalog, Stores, Categories and People. It owns the native toolbar placements and shared normal/selection states:

- Normal: Select text and the plus control together.
- Selection: Done clears the selected IDs and returns to normal mode; Select All toggles all visible records and becomes Deselect All.
- Use native `List(selection:)`, stable identity tags and `EditMode` for multiselection and reordering. Keep selected-row actions separate from rename-on-tap.

Use `ShoppingAddButton` for navigation creation controls, including the grocery plus. It owns the symbol font and scale, icon-only presentation and full accessible action label. Do not substitute an `EditButton` or a checkmark-only Select control on individual Settings screens.

Selected commands capture IDs/revisions and run through the background management worker. Deletion previews must retain referenced records, skip newer changes and preserve the promised disposition. A changed assignment must not escalate a preview from archive to permanent deletion.

## Accent and semantic colors

Use `Color.groceryAccent` or the inherited tint for affirmative actions and selected
states. The adaptive `AccentColor` asset is also configured as the iPhone app's
global accent, so native controls and `Color.accentColor` use the same palette.
Apply tint above the persistence root so onboarding, home sheets and recovery
share the tab UI's accent. Preserve urgent-item styling (`groceryUrgent`), orange
warning/removal-from-cart/archive actions and red destructive actions.

`AppPresentationTests/testGroceryAccentSharesTheGlobalAdaptivePalette` checks the
global asset and explicit accent resolve to the same light and dark colors.
Appearance screenshot review must still verify native controls, selections,
quantity buttons and swipe actions; the palette test alone cannot prove rendered
color consistency or contrast.

## Verification

`ShoppingAppearanceUITests/testGroceryAndCatalogShareRowHeightAndFilterControlDimensions` checks equal bare-row heights, scope-control dimensions and plus dimensions. The existing column and content-sized table tests retain long notes, large text, assignment and quantity/cart proof. `CategoryManagementUITests` checks native selection across management screens, People selection/reset and safe removal. Review their screenshot attachments as well as geometry assertions. `StoreManagementTests` owns the person-batch safety rules.
