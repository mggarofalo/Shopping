# Store-list text sharing

Choose a store in Groceries, then use **Share store list** in the navigation bar.
The native iOS share sheet receives plain text with one item name per line. It
opens a choice of destinations; the app never selects a recipient or sends a
message automatically.

The export includes all outstanding, uncarted grocery occurrences eligible for
the selected store. It deliberately ignores search, category, urgency and
advanced include/exclude filters, so a narrowed on-screen view cannot omit part
of the store list. It uses the existing grocery category order and item order,
without printing category headings, quantities, notes, people or store labels.
Remembered items use the current catalog name; one-time items use their title.
Embedded line breaks collapse to spaces and duplicate occurrence names remain.

Archived-only restrictions and unresolved catalog identities retain the existing
purchase-rule behavior. Only an active selected store enables export. An empty
store list disables the action. Home scope and personal-cart fulfillment use the
same authority and occurrence rules as Groceries. Other shoppers' advisory cart
presence does not hide their items from this shopper's list.

## Proof ownership

- `GroceryNavigationStateTests` owns store eligibility, flattened category order,
  plain-text formatting and independence from search/category narrowing.
- Existing purchase-rule and personal-cart tests retain authoritative filtering,
  fulfillment and account/home isolation proof.
- `ChecklistUITests/testStoreListShareCanCancelAndReopenWithoutChangingGroceries`
  owns opening, cancelling and reopening the native sheet without changing items
  or cart state. It never selects a recipient or activity.
- `ChecklistUITests/testStoreListSharingIgnoresEmptyFilteredViewAndDisablesWhenAllItemsAreCarted`
  owns sharing from a category/urgency filter with no matching rows and disabling the action after
  carting every outstanding item in the selected store.

## Validation status

The initial implementation was prepared on Linux and handed to the laptop for
Xcode and simulator validation. The pull request records the final source SHA,
local test results, screenshots, hosted CI and any remaining device checks.
Static checks alone are not iOS build or interaction evidence. This work does
not change the remote full-suite attestation policy.
