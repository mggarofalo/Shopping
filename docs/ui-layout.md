# Shared list and selection UI

Catalog is the reference for item rows. Stores is the reference for selection and creation controls. Read this with the [responsiveness contract](ui-responsiveness.md) before changing these screens.

## Item rows

- Use `ShoppingItemColumns` for the same 2:1 description/store columns in Catalog and Grocery List. Keep the title and notes on the left, with inline person assignment on groceries. Keep store summaries on the right, within the row's symmetric insets.
- Keep the grocery edit button at least 44 points tall, including the space beside short titles. `ShoppingItemColumns` aligns the first text baselines so the smaller store label stays aligned when that hit area grows.
- Use `ShoppingItemStoreSummary` for store-name fitting and omitted-store counts. The row must still announce the complete store summary, including archived restrictions and unresolved identities. Keep selected-store purchase-rule symbols accessible through the row value.
- Apply `shoppingItemRow()` to the entire row: measure the content, enforce the 44-point minimum, then apply four points of vertical padding on each side. Apply `shoppingListRowInsets()` once. Applying padding before the minimum produces a shorter row and was the source of Grocery/Catalog drift.
- Minimum height is not fixed height. Notes, quantity controls and accessibility-sized text may expand a row. Keep independent quantity buttons at least 44 points in each direction and allow their layout to adapt at accessibility sizes. Never clip supporting text to force equal heights for different content.

## Store and filter controls

Use `ShoppingScopeLabel` for both Choose store and Filters, including menus. It owns the font, symbol scale, multiline fitting and minimum label height. Keep the store picker left and Filters right in the scrolling list header; stack them at accessibility sizes. Keep the X to clear store scope. Do not add a redundant All control.

## Select and Add controls

Use `ShoppingCollectionToolbar` for Catalog, Stores, Categories and People. It owns the native toolbar placements and shared normal/selection states:

- Normal: Select text and the plus control together.
- Selection: Done clears the selected IDs and returns to normal mode; Select All toggles all visible records and becomes Deselect All.
- Use native `List(selection:)`, stable identity tags and `EditMode` for multiselection and reordering. Keep selected-row actions separate from rename-on-tap.

Use `ShoppingAddButton` for navigation creation controls, including the grocery plus. It owns the symbol font and scale, icon-only presentation and full accessible action label. Do not substitute an `EditButton` or a checkmark-only Select control on individual Settings screens.

Selected commands capture IDs/revisions and run through the background management worker. Deletion previews must retain referenced records, skip newer changes and preserve the promised disposition. A changed assignment must not escalate a preview from archive to permanent deletion.

## Verification

`ShoppingAppearanceUITests/testGroceryAndCatalogShareRowHeightAndFilterControlDimensions` checks equal bare-row heights, scope-control dimensions and plus dimensions. The existing column and content-sized table tests retain long notes, large text, assignment and quantity/cart proof. `CategoryManagementUITests` checks native selection across management screens, People selection/reset and safe removal. Review their screenshot attachments as well as geometry assertions. `StoreManagementTests` owns the person-batch safety rules.
