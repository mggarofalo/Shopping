# Grocery domain model

This document describes the local model as it grows toward the shared MVP. The [architecture decision](architecture/0001-managed-household-persistence.md) defines the managed CloudKit direction and separates local evidence from the required live two-account proof. The application currently displays the shell; these commands run through tests until persistence and views are connected.

## Household metadata — SHOPPING-23

A household owns its grocery list, reusable catalog, stores, and optional categories. Relationships are optional in storage for incomplete imports, but local writes must resolve valid household membership. Related objects must also belong to the same persistent store; sharing permissions and actual share-zone association are additional responsibilities of the later container/sharing work.

Stores and categories have stable UUIDs, trimmed nonblank names, and explicit display order. Ordering uses the UUID as a final tie-breaker so equal positions do not jump between fetches. A display name is not identity; similarly named stores or categories are not silently merged.

Archiving a store preserves its catalog memberships and every grocery occurrence. Only active stores count when determining current purchase availability. A Costco-only grocery whose store is archived has no active eligible store: it belongs in All with Needs store, and must not become available at another retailer. Restoring Costco restores the remembered purchase eligibility without recreating tags. Any store continues to mean eligible at any active selected store.

Removing a category uncategorizes its catalog items. It does not remove the items, their store tags, or their grocery needs. No category setup is required, and there are no cascading deletes from metadata into groceries.

## Catalog and purchase filters — SHOPPING-22

A catalog item retains its name, general notes, optional category, explicit store memberships and Any store setting between purchases. Names are trimmed and must not be blank. Case and whitespace normalization can suggest existing names; it does not merge distinct brands/sizes or impose distributed uniqueness. Current grocery urgency belongs to a need, not the catalog.

Catalog archival removes an item from the reusable catalog and suggestions, while its existing active grocery demand keeps its identity and retained buying rules. Archiving a catalog entry must not make an existing grocery disappear from a store where it is otherwise eligible. A tag edit changes the same need's filtered presentation; it must not change quantity, carted state, or create a store-specific copy.

For an active selected store S and the explicit active store-tag set T:

| Rule | Match |
|---|---|
| Available at S | Any store, or S is in T. |
| Must buy here | Not Any store, and T contains only S. |
| Flexible here | Available, but not Must buy here. |
| Needs store | Not Any store, and T is empty. Remains visible in All. |
| Tagged with I | I is empty, or at least one included tag is in T. |
| Not tagged with E | None of the excluded tags is in T. |

Apply selected-store eligibility first. Tagged, Not tagged, text, category and other optional filters combine with AND and can only narrow the result. Exclusion wins if the same tag is included and excluded. Any store establishes availability without inventing explicit memberships: an untagged Any-store item can match Not tagged Costco while still being available at Costco. Archived store memberships remain stored but are excluded from T, and an archived selected store is not a shopping destination.

Both catalog rows and one-time grocery rows use the same purchase-rule inputs. A missing catalog reference never means Any store. All catalog contains non-archived reusable items; All groceries contains active needs, including one-time and Needs store rows. Suggestions only use reusable catalog data.

New catalog entry commands require at least one active store or Any store. Needs store remains a supported recovery state after a store is archived or relationships arrive incompletely. Restoring an archived store revives the same saved tag; it does not create new buying preferences.

## Next model layers

SHOPPING-21 completes quantities, urgency, one-time purchase details, and re-add/recovery semantics, using these purchase predicates. SHOPPING-20 establishes the versioned application schema, migrations, persistent history consumption and production store setup. The current programmatic schema remains experimental until that work; model version identifiers alone are not a migration strategy.
