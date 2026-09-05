# Grocery domain model

This document describes the local model as it grows toward the shared MVP. The [architecture decision](architecture/0001-managed-household-persistence.md) defines the managed CloudKit direction and separates local evidence from the required live two-account proof. The application currently displays the shell; these commands run through tests until persistence and views are connected.

## Household metadata — SHOPPING-23

A household owns its grocery list, reusable catalog, stores, and optional categories. Relationships are optional in storage for incomplete imports, but local writes must resolve valid household membership. Related objects must also belong to the same persistent store; sharing permissions and actual share-zone association are additional responsibilities of the later container/sharing work.

Stores and categories have stable UUIDs, trimmed nonblank names, and explicit display order. Ordering uses the UUID as a final tie-breaker so equal positions do not jump between fetches. A display name is not identity; similarly named stores or categories are not silently merged.

Archiving a store preserves its catalog memberships and every grocery occurrence. Only active stores count when determining current purchase availability. A Costco-only grocery whose store is archived has no active eligible store: it belongs in All with Needs store, and must not become available at another retailer. Restoring Costco restores the remembered purchase eligibility without recreating tags. Any store continues to mean eligible at any active selected store.

Removing a category uncategorizes its catalog items. It does not remove the items, their store tags, or their grocery needs. No category setup is required, and there are no cascading deletes from metadata into groceries.

## Next model layers

SHOPPING-22 adds complete catalog editing, suggestions, and shared purchase-rule predicates for Available, Must buy here, Tagged and Not tagged. SHOPPING-21 completes quantities, urgency, one-time purchase details, and re-add/recovery semantics. SHOPPING-20 establishes the versioned application schema, migrations, persistent history consumption and production store setup. The current programmatic schema remains experimental until that work; model version identifiers alone are not a migration strategy.
