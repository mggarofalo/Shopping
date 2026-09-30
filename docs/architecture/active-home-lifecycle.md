# Active home lifecycle

SHOPPING-124–130 implement the local account, home, invitation, membership and
status boundaries. SHOPPING-131 validates their interaction; SHOPPING-30 must
establish actual CloudKit behavior on two accounts and two physical iPhones.
See the [evidence matrix](../home-sharing-validation.md) for proof ownership.

## Account and graph identity

`ShopperSessionProvider` owns authentication. A session includes the configured
container/environment and the binding derived from the verified iCloud account.
The account's stores, selection preferences, private cart and recovery stay in
that partition. An account change never relabels or deletes the old partition.
A provisioned cached session permits supported offline work; it does not authorize
new invitation acceptance or fresh native membership claims. Temporary account
unavailability must not silently grant another account's authority.

`ActiveHomeScope` adds the selected graph's store identifier, permanent root URI,
household UUID and list UUID. Matching domain UUIDs alone cannot identify a
removed and reimported local graph. Discovery distinguishes a valid empty home
from a missing or ambiguous root/list. A pending invitation holds automatic
selection; an incomplete import cannot cause a replacement home to be created.

`ActiveHomeCoordinator` retains account-scoped selection. Discovery results and
errors belong to the latest request and generation. Changing the account, home
or selected home's access retires the old presentation and its command authority.
Editors retain their original scope and saved drafts. A captured command cannot
be redirected into the newly selected home; returning to the original home can
restore its draft and private cart.

## Creation, adoption and explicit invitation choice

Any verified user can create an owned home, including a contributor in another
home. `HomeCreationJournal` captures its account/store, operation, home/list UUIDs
and name before the atomic save. Retry uses those same identities. A partial
graph is an error, not permission to create another home.

Existing local groceries require an explicit [copy-or-retain decision](home-adoption.md).
Copying verifies the complete retained source snapshot before opening the account
destination. An existing account destination is never overwritten or merged.
Keeping a local home preserves a separate route to its original store. Neither
choice attributes legacy carts or combines private carts from different homes.

The [invitation inbox](home-invitation-acceptance.md) persists cold/warm metadata
before account readiness. Acceptance and usable-root discovery are separate
checkpoints. Neither chooses the home. **Open [home]** captures the exact entry,
account, graph and presentation, freshly verifies native access, and commits an
explicit rejoin grant when needed. Its final local discovery/selection reserves
that presentation against ordinary refresh; a fresh observation follows release.
The native verification wait does not reserve ordinary home discovery.

**Not now** resolves only that entry's choice and retains the current home. With
no selected home, it persists a selection hold. Two invitations keep independent
entries and choices. A later import cannot replace an explicit selection. The
general home picker cannot bypass a pending invitation's choice.

## Membership and retained private work

Owner and Contributor are the only product roles. Unexpected read-only access is
a restricted state. People assignments are grocery metadata, not members or
authority. The owner uses the [private one-time-link flow](0003-home-invitations.md)
without an email lookup. A pending link reserves one participant; the share
sheet's completion does not prove acceptance or grocery delivery.

Remove contributor, Cancel invitation and Stop sharing capture exact non-owner
participants and retain a durable private operation before native effects.
Stop sharing preserves the owner share, home, groceries and identities; it does
not purge a zone. A later invitation is outside an earlier captured removal.
Uncertain outcomes require fresh observations before explicit retry.

Observed access loss records an account/home/share-qualified boundary in the
private ledger. Checkout and recovery retain their captured authority and causal
dependencies. Read-only, revoked, left or incomplete history cannot publish old
household effects. An explicit rejoin grant enables new work; it does not upgrade
older captured effects. Private snapshots, history and supported own-cart cleanup
remain available. Unobserved remote revocation cannot be inferred from a local
cache or a later accepted participant alone.

Contributor Leave home confirms the exact scope and discloses unsent work. Its
durable boundary precedes the managed purge of the exact participant store/zone.
Submission is recorded once, and the local zone queue stays reserved until the
native callback drains. A missing callback or crash after submission remains
uncertain; retry never blindly purges again. Completion requires positive zone
absence and absence of the original local root/list. Private history and other
homes remain retained. Reinvitation requires fresh acceptance and explicit Open.

## Status and release evidence

Sharing status composes account/access, invitation readiness, separate private
and shared store events, local checkout/recovery work and known share-association
preparation. A local save, association acknowledgment or observed export is not
another member's receipt. Historical unfinished events and absent observations
do not become endless progress indicators.

Check status bounds the UI wait while retaining the underlying operation's
reservation until it drains. Late observations cannot publish into another
account, graph or presentation. Return to home preserves shopping state. None of
these actions resets data or forces CloudKit scheduling.

The app's local and simulated tests do not establish native one-time-link claims,
server permissions, real private/shared zone routing or two-phone convergence.
Those remain blocking live assertions in SHOPPING-30, followed by production
readiness in SHOPPING-8 and final onboarding acceptance in SHOPPING-7.
