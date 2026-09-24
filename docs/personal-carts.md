# Personal carts

SHOPPING-103 adds account-bound private carts alongside the existing household demand list. [ADR 0002](architecture/0002-personal-carts.md) defines the authority, conflict and recovery contract. Local tests and simulator workflows establish application behavior; they do not establish live CloudKit sharing.

## Activation and retained local data

Normal installations retain their original local workflow until Settings → Set up personal carts. The user chooses either existing iCloud groceries or explicitly copying this device’s local groceries. Only the first device should copy its local store; other devices import the existing cloud data. No account or household is invented to mask an unavailable account or an empty import cache.

The real account provider obtains CloudKit account status and user record identity. A scoped digest supplies a stable same-account identity; it is not an authorization credential. Records, account cache and captured commands remain bound to that account and CloudKit environment. Observed account changes immediately invalidate command access, detach the old account stores, and preserve their files. A verified cached identity is usable when the provider observes a network failure; signed-out or restricted accounts do not become offline authority.

The copy helper uses Core Data’s persistent-store replacement API with an intermediate store and a durable source/account ledger. It preserves the source, never replaces existing account data, and resumes an approved interrupted copy on relaunch. The source cannot silently migrate to another account. The original local cart flag does not establish an owner: review entries are kept until explicit Claim as mine or Discard old cart status. Legacy recovery payloads remain retained and never become automatic personal checkout commands.

## Storage and commands

V7 retains the released V1–V6 model versions. `PersonalCartRecord` is an unshared, account-bound immutable envelope with no relationships to the household graph. `HouseholdCartRecord` contains demand evidence, advisory presence and purchase/retraction envelopes associated only with its household. `LegacyCartReview` retains unattributed migration snapshots. These are physical representations of the logical records in ADR 0002.

`PersonalCartService` owns membership, independent optional quantities, captured checkout, recovery and outbox replay. The UI passes opaque entry/capture tokens and never supplies an authoritative shopper. Presence is read-only in the UI and untrusted at the household-share boundary. Another shopper’s purchase leaves the owner’s entry available with an explicit purchase notice and Remove or Buy anyway choice.

Checkout records a private intent before attempting a household receipt. Publication failures remain pending; retries reuse the logical operation ID. Demand fulfillment applies only to the exact captured occurrence and causal evidence. Newer edits and replacement occurrences survive delayed imports and undo. Private restore authority is separate from shared advisory receipt retractions.

The iPhone uses value snapshots for its personal cart, purchase history and recovery. The grocery list excludes only the current shopper’s cart entries. Saved personal carts remain reachable when their household is no longer available; cleanup must not recreate that household.

## Configuration and evidence gates

The configured container is `iCloud.com.mggarofalo.shopping`. Both signed app identifiers need its CloudKit capability and matching provisioning profiles. Debug uses the Development account namespace; Release uses Production. Provisioning, server schema deployment and actual account/share behavior must be verified in SHOPPING-30 before any claim of household sharing. Never reset a production schema to make a migration pass. Audit shipped entitlements before migrating any real legacy managed graph; the source used by the local activation path must be known to be local-only.

Watch bootstrap and command integration are SHOPPING-121. SHOPPING-122 verifies a Series 11 cold launch, independent cloud import/publication and later phone convergence while the paired phone is powered off. Simulator fixtures do not satisfy those gates.

`ShoppingFast` owns production domain, account-provider and activation tests. `PersonalCartUITests` owns the personal-cart UI routes and explicit migration review; the [ownership ledger](test-ownership.md) lists their exact boundaries. Test/preview identities require explicit isolated fixtures and are never selected by normal launch.
