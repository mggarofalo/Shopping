# Home sharing validation

This is the SHOPPING-131 handoff to SHOPPING-30. Local tests establish application
behavior and persisted recovery. Injected membership, account and store-role
observations do not establish CloudKit ACLs, zone assignment or delivery.

## Local requirement matrix

| Scenario | Required resulting state | Existing proof owner |
| --- | --- | --- |
| Owner, contributor, read-only | Only owner manages members; restricted shared writes are disabled; private recovery remains retained. | `HomeDetailsModelTests`, `HomePermissionTests`, `HomeDetailsUITests` |
| Same invite twice, cold/warm | One durable entry and acceptance gate; cold ingress holds selection before discovery. | `HomeInvitationInboxTests`, `HomeInvitationControllerTests`, `ActiveHomeBootstrapTests` |
| Two invitations, either import/Open order | Independent decisions; no automatic switch; Open resolves only its entry; original groceries/cart remain reachable. | `HomeAdoptionBootstrapTests` interaction extension in SHOPPING-131 |
| Empty home versus absent root | A complete empty home is usable; absent/ambiguous root/list remains Loading without replacement creation. | `ActiveHomeCoordinatorTests`, `HomeInvitationControllerTests` |
| Nonempty original during join | Not now retains original; Open preserves both graphs and each home’s private cart. | `HomeAdoptionBootstrapTests`, `PersonalCartUITests` |
| Temporary account loss and A→B | Old commands/callbacks cannot acquire new authority; original partition and drafts remain retained. | `ShopperSessionProviderTests`, `ActiveHomeCoordinatorTests`, `ActiveHomeBootstrapTests` |
| Home switch with editor/checkout | Captured old command cannot mutate the new home; return restores original cart/draft. | `ActiveHomeCoordinatorTests`, `ActiveHomeBootstrapTests` |
| Permission loss during accept/publish | Observed loss is retained before acceptance; old checkout stays quarantined after rejoin; missing dependencies fail closed. | `HomeInvitationAcceptanceTests`, `HomeEffectQuarantineTests` |
| Adoption interruption | Every declared checkpoint resumes the same command; source and destination identities/data survive. | `HomeAdoptionJournalTests`, `PersonalCartActivationTests` |
| Acceptance/import interruption | Interrupted Joining requires explicit retry; Loading resumes discovery without repeated acceptance; stale import tokens cannot resolve readiness. | `HomeInvitationInboxTests`, `HomeInvitationControllerTests` |
| Open versus background discovery | Explicit selection survives competing refresh; stale errors do not publish; failed Open releases its reservation and same-entry retry has one grant. | `HomeAdoptionBootstrapTests` reservation regressions from SHOPPING-130 |
| Leave/rejoin interruption | Durable quarantine precedes one submission; uncertain submitted leave never purges again; missing-root status remains reachable. | `HomeLeaveLedgerTests`, `ManagedHomeLeaveTransportTests`, `HomeLeaveBootstrapTests`, `HomeDetailsUITests` |
| Owner remove/stop interruption | Exact captured participants only; owner/share/groceries/private cart retained; fresh observations precede explicit retry. | `HomeMembershipRemovalTests`, `HomeMembershipPrivateLedgerTests`, `HomeDetailsUITests` |
| Scoped checkout and replay | Zero or one logical checkout per command; newer demand and other carts survive; one home's loss does not block another. | `PersonalCartServiceTests`, `HomeEffectQuarantineTests` |
| Post-share children/private exclusion | Child stays with its root's store; only owner-private household objects enter association staging; private cart/lifecycle objects never enter it. | `PersistenceHarnessTests`, `PersistenceContainerTests`, `HomeShareGraphTests` |
| Archived rules, one-time, People, legacy | Exact rules/identities/recovery retained; no implicit one-time promotion or cart attribution; People remain metadata. | `HomeAdoptionSnapshotTests`, `HomeShareGraphTests`, `GroceryEditingTests`, `PersonalCartServiceTests` |
| Stale/forged shared presence | Presence never authorizes or removes another shopper's private cart; shared retraction cannot restore it. | `PersonalCartServiceTests`, `HomeEffectQuarantineTests` |

SHOPPING-131 additions are validated with the existing proof owners, not a new
exhaustive permutation UI suite. The separate [ownership ledger](test-ownership.md)
records exact methods, fixture changes, failed measurements and final local runs.

## Candidate and execution record

The starting integrated source is `fa3181c10ba5146d7260f7e5a6ef56deb481545d`, whose
tracked tree equals SHOPPING-130 source `47359c54c51de74f80e671cc26aff696066f1d17`.
[Pinned CI 36643875688](https://github.com/mggarofalo/Shopping/actions/runs/36643875688)
passed 564 Fast tests, all six acceptance UI workflows, unchanged coverage gates
and Release SDK Build. This is baseline evidence, not validation of later changes.

The final SHOPPING-131 candidate must record its exact source SHA, local result
bundles and test inventory, CI URL and exhaustive attestation in the
[SHOPPING-131 execution record](https://plane.wallingford.me/dev/projects/b25c0cea-908f-4021-948f-434274ce2998/issues/ebd0b625-d102-4cb3-9f9b-62227dc09409).
Do not use the baseline run for a changed candidate. Full validation keeps the
required sequence: clean commit → local full runner → push that unchanged commit
→ remote dispatch helper. No failure, missing selection, skip or coverage change
is waived by this matrix.

## Reported physical join and initial import

On October 2, 2026, Michael reported accepting the home invitation on his wife's
iPhone and successfully downloading the home's data. This is real two-account
join and initial-import evidence for the installed app, recorded in SHOPPING-30.
The report did not include exact device, OS, build, source SHA, timing, or conflict
and membership-change results. It establishes that the existing transport works
for this journey; it does not validate the later Phase 24 rewrite.

Phase 24 preserves this working transport while replacing home entry and
navigation. SHOPPING-174 records validation of the rewritten journeys.

## Phase 24 journey contract

The approved interaction reference is [Home experience](design/home-experience.md),
with an [HTML mockup](design/home-experience.html). The native implementation must
meet these paths; the mockup does not establish native routing or cloud delivery.

| Journey | App interaction | Required retained state |
| --- | --- | --- |
| First home | Create Home from the first screen. | Exact durable creation IDs; no automatic replacement after deletion. |
| Accepted invitation | Native link acceptance opens the exact home when import is ready, without an additional app Join action. | Original home and private carts; newer explicit selection wins. |
| Deferred invitation | Home control → Open on the invitation. | Durable Not Now decision; independently recoverable invitations. |
| Switch | Home control → home row. | Selected scope shown in Groceries, Catalog, My cart and Settings. |
| Saved cart from another home | Saved carts → cart. | A static label names that cart's exact home; the application selector must not identify its contents as belonging to the current home. |
| Local home → iCloud | Use iCloud in Home Settings. | A distinct owned copy and selectable exact local source; no cart attribution or merge into a joined home. |
| Delete | Home Settings → Delete Home → named confirmation. | Private history and unrelated homes; pending recovery stays reachable after the root disappears. |
| Create after delete | Create Home from No Homes. | Fresh IDs, even before background recovery finishes. |
| Account change | Homes retains the device-local source; account commands require the current account. | Old account stores, commands and history remain isolated. |
| Watch | The selected home name is visible in Groceries, Stores and Cart. | Watch selection keeps its existing independent policy. |

SHOPPING-173 adds durable deletion and copy recovery. Tests must cover later
same-home imports during confirmed deletion, an absent server zone with local
residue, missing root/list remnants, a committed copy whose acknowledgment was
interrupted, and deletion followed by a new local home. Retained adoption
decisions are evidence, not authority to reuse a replacement home's identity.

Exact local run results, failures and corrections belong in the
[test ownership ledger](test-ownership.md). SHOPPING-174 must record the final
source SHA and pinned CI run. Physical validation still requires cold/warm native
links, both phones' resulting graphs, owner deletion/revocation, account changes,
and the device Animation Hitches trace defined by the
[responsiveness contract](ui-responsiveness.md). Michael's reported initial join
above establishes the installed transport's success, not these rewritten paths.

## Required live assertions

| Live case | Evidence required on the sharing candidate |
| --- | --- |
| Signed invitation creation | Exact build/source and OS; phone signature/profile permits one-time links; returned saved private share supplies the captured participant's link. |
| Claim and forwarding | Two distinct accounts; first claim succeeds; unclaimed forwarding behavior and claimed-link denial for an uninvited account; cancel/revoke/reinvite outcomes. |
| Cold/warm native routing | Actual system link opens the installed app in each state; metadata survives restart; duplicate delivery does not duplicate membership or select a home implicitly. |
| Initial import and retained local home | Real missing-root versus empty-home states; original groceries/private cart survive acceptance and explicit return; two pending home invitations remain independent. |
| Owner/participant children | Inspect real private/shared store and zone association after each side adds catalog, need, store and category records; verify receipt on the other phone. |
| Private cart isolation | Confirm private records are unassociated with the household share; attempt cross-account writes through the actual persistence/access boundary and observe denial. Shared demand edits must still work. |
| Convergence/conflicts | Record both sides and measured latency for foreground, delayed/offline and reconnect orders; preserve disjoint edits, lifecycle evidence and recovery. Own-device cart replication is a separate same-account check. |
| Membership changes | Remove, cancel and owner Stop retain required owner data; participant Leave affects only the exact zone and retains private history; offline loss/rejoin never upgrades old effects. |
| Interrupted effects | Native callback loss/relaunch, uncertain leave, captured checkout versus offline edits, account changes and missing records; no data-reset repair or duplicate destructive replay. |
| Device responsiveness | Exact installed source/build, launch and immediate-scroll Animation Hitches trace, native share sheet, large text and required assistive-technology checks. |

Record failures and identities retained versus replaced in SHOPPING-30. An export
event does not prove a peer received data; local denial does not prove server
authorization. Production schema verification (SHOPPING-8), final onboarding
(SHOPPING-7), and physical Watch acceptance remain their own evidence gates.
