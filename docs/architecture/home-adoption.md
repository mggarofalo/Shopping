# Keeping homes separate when joining

SHOPPING-127 separates accepting a CloudKit invitation from opening its home.
The invitation inbox may accept and import a share while the current home remains
selected. Once the exact imported graph is available, the UI names the current and
invited homes and offers **Open [home]** or **Not now**. The general home picker
cannot bypass an unresolved invitation decision. A decision closes the invitation
prompt; accepting a fresh grant can create a new decision for the same share.
Hidden in-flight progress reappears when the home is ready or the invitation needs
a retry, so hiding it cannot strand an unresolved accepted home.

Not now preserves the current selection. Without an active home, it also records a
local, account-scoped selection hold: a later refresh or launch cannot automatically
open the sole accepted home. An explicit home choice clears that hold.

## Local groceries before account setup

Setup verifies the current iCloud identity before asking how to keep existing local
groceries. Approval records the account/container/environment, original SQLite store
UUID and path, selected home/list UUIDs, and copy-or-retain decision. An account change
cannot reinterpret an unfinished approval for another account. The old unbound
pending-import path alone does not authorize a new account assignment.

For an unused account destination, copying uses the existing `PersonalCartActivation`
staging and recovery protocol. The UI retires its command authority and detaches its
store before the worker captures and copies persisted data. `HomeAdoptionSnapshot`
records every persisted entity, exact attribute values and relationship identities,
including archived purchase restrictions, optional quantities, one-time needs,
category ordering, People, recovery payloads and existing cart evidence.

A durable expected snapshot is written before copying. The copied store must match
before it opens as managed CloudKit data or the V7 legacy-cart review migration runs.
Interruption after approval, snapshot, copy or verification resumes the same operation.
Successful verification is recorded once; later account edits are not compared with
or overwritten by the original snapshot. The source is retained. The copied original
home remains a distinct selectable home, using its original domain UUIDs.

An existing account store cannot be overwritten or merged. **Keep [home] on this
device** records a separate route to its original store. Opening that route detaches
the account stores, validates the original store UUID, and presents the local home.
The chosen local route can reopen offline; returning to account homes verifies the
original account. The source and its copied counterpart are never attached together.

## Cart ownership and proof boundaries

No new cart attribution or cart-data migration runs here. The existing V7
`LegacyCartReview` process retains unknown-owner evidence for Claim, Keep for review
or Discard. Neither copying nor opening another home claims that evidence, combines
same-name items, sums quantities, promotes one-time needs, or retargets private carts
and checkout operations. Existing causal recovery records remain unchanged.

Local copy and decision tests do not establish Production schema readiness, native
CloudKit delivery, invitation usability across OS versions, or two-device convergence.
Those remain explicit SHOPPING-8/SHOPPING-30 gates. Physical-device responsiveness
also remains a separate validation gate.
