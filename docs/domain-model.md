# Grocery domain model

This document describes the local model as it grows toward the shared MVP. The [architecture decision](architecture/0001-managed-household-persistence.md) defines the managed CloudKit direction and separates local evidence from the required live two-account proof. The application loads a disk-backed local store and displays the shell while the shopping views are developed. Commands also run through isolated SQLite tests.

## Household metadata — SHOPPING-23

A household owns its grocery list, reusable catalog, stores, and optional categories. Relationships are optional in storage for incomplete imports, but local writes must resolve valid household membership. Related objects must also belong to the same persistent store; sharing permissions and actual share-zone association are additional responsibilities of the later container/sharing work.

Stores and categories have stable UUIDs, trimmed nonblank names, and explicit display order. Ordering uses the UUID as a final tie-breaker so equal positions do not jump between fetches. A display name is not identity; similarly named stores or categories are not silently merged.

Archiving a store preserves its catalog memberships and every grocery occurrence. Only active stores count when determining current purchase availability. A Costco-only grocery whose store is archived has no active eligible store: it belongs in All with Needs store, and must not become available at another retailer. Restoring Costco restores the remembered purchase eligibility without recreating tags. Any store continues to mean eligible at any active selected store.

Removing a category uncategorizes its catalog items and one-time needs. It does not remove the items, their store tags, or their grocery needs. No category setup is required, and there are no cascading deletes from metadata into groceries.

## Catalog and purchase filters — SHOPPING-22

A catalog item retains its name, general notes, optional category, explicit store memberships and Any store setting between purchases. Names are trimmed and must not be blank. Case and whitespace normalization can suggest existing names; it does not merge distinct brands/sizes or impose distributed uniqueness. Current grocery urgency belongs to a need, not the catalog.

Catalog archival removes an item from the reusable catalog and suggestions, while its existing active grocery demand keeps its identity and retained buying rules. Archiving a catalog entry must not make an existing grocery disappear from a store where it is otherwise eligible. An archived catalog ID cannot create new grocery demand, although an existing active need remains accessible. A tag edit changes the same need's filtered presentation; it must not change quantity, carted state, or create a store-specific copy.

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

## Current grocery needs — SHOPPING-21

Each need has a stable occurrence UUID, quantity from 1 through 99, carted state, a purchase-specific note, and Normal or Urgent urgency. Checking and unchecking edit the same occurrence. They never delete catalog knowledge or change purchase eligibility.

An explicit remembered-item add returns an existing active occurrence to needed state and resets urgency to Normal unless the caller explicitly requests Urgent. It preserves quantity and purchase-specific notes unless the user adjusts them. Browsing or focusing an existing need is a read and does not reset urgency. After clearing, adding the catalog item creates a new occurrence with fresh current-need defaults and the same remembered purchase rules. An older captured clear cannot target this new UUID.

One-time groceries have their own name, category and store rules, plus the same quantity, notes, carted and urgency fields as other needs. Their catalog relationship is absent, and an explicit persisted lifecycle marker distinguishes them from a remembered need whose catalog relationship has not arrived. Incomplete imported rows remain recoverable and unavailable in store views until their purchase rules resolve; they cannot masquerade as one-time groceries or be promoted accidentally. Equal names do not merge occurrences. Copying catalog details into a one-time need leaves the catalog unchanged; editing the copy does not teach future defaults. Only explicit remembering may create or link a catalog entry, after validating the chosen match and any existing active demand.

A clear capture may be restricted to the visible view’s occurrence IDs. That restriction is an allowlist: capture selects only rows still active and carted within it. Confirmation must use the returned token’s actual count, not the earlier view count. Clearing retains the original occurrences for recovery and records the exact captured IDs and revisions in one atomic save. A changed or uncarted row is skipped, and retries cannot widen the captured set. Undo can restore an unchanged archived occurrence after relaunch, including a one-time need with all its details; it never overwrites a newer edit or restores a second active occurrence for a remembered item. Recovery does not make a one-time item a future suggestion.

Concurrent imported remembered needs are grouped by household/list and catalog UUID, never by name. A normal serialized add creates or reuses one active occurrence. If several active candidates already exist, the command exposes their IDs, revisions and current values without mutating any candidate. Quantities are not summed and divergent edits remain intact. Candidate snapshots include purchase notes so differing instructions are visible as well as retained. Zero or duplicated occurrence identities cause a typed validation error instead of a usable row ID or a write to an arbitrary occurrence. Cross-account canonicalization and a recoverable resolution workflow remain required sharing integration work; local detection is not proof of distributed uniqueness.

## Persistence — SHOPPING-20

The [persistence guide](persistence.md) describes the initial versioned application schema, saved-data fixture, persistent history consumption, store routing and recovery. V1 is the first production schema; a later version must prove migration from the retained fixture. A clear operation’s binary snapshot is optional in storage for incomplete imports, but undo requires the payload and makes no changes while it is missing.
