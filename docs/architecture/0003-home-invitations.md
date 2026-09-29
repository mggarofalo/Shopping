# ADR 0003: Private home invitations without account handles

Status: selected local contract for SHOPPING-123, 2026-09-29. Production implementation is SHOPPING-124–131; actual CloudKit behavior remains gated by SHOPPING-30. Builds target iOS 17; generating these invitation links requires iOS 18. No live invitations are sent by this decision or its fixture.

## Product decision

Each home has one **Owner** and zero or more **Contributors**. Roles are per home: a contributor can create and own another home. Contributors can edit shared groceries/catalog/management data, but cannot manage membership or another person's private cart. Owner/contributor labels do not replace actual CloudKit role and permission checks. Unexpected read-only access is a restricted state with shared commands disabled, not a third selectable product role. People assignments never identify members.

The user explicitly requires **text a join link to anyone without knowing or typing their iCloud email**. Select CloudKit's **one-time URL participant**, with read/write permission, in a private share (`publicPermission == .none`). Every invitation reserves one anonymous pending participant. The first accepting iCloud account claims it. Create a fresh invitation for another contributor. The pending row says **Invitation pending**, never a guessed name. The sheet explains **Anyone you send this link to can join. It can be used by one person.** A forwarded unclaimed link can be claimed by its recipient; it is not bound to the intended person until acceptance. Treat it as a secret, omit it from diagnostics and do not generate/forward it without the owner's action.

This supersedes the earlier email-lookup proposal. There is no email/contact entry, QR scanner, custom token server, hosted invite page, public reusable household link or separate Shopping account. TestFlight enrollment is separate from home membership.

## Selected native surface

Use a SwiftUI `Form`/`List` for home details, pending invitations and contributors, native `Button` actions and `confirmationDialog` for access removal. **Invite contributor** creates a one-time participant, exports the updated share and opens a `UIActivityViewController` with **only its one-time URL**. Messages/Mail provide delivery. Copying and resending that same unclaimed invitation is supported; a new owner action creates another slot/link. Supply an iPad popover anchor and provide previews/VoiceOver labels/Dynamic Type states in SHOPPING-128.

Do **not** present `UICloudSharingController`, `CKShareTransferRepresentation` or a collaboration item provider that exposes native share management. The existing-share controller exposes Stop Sharing and has no documented veto/hide for that destructive action. Its permission options alone do not solve owner data retention. The small native member list is necessary to preserve the home and implement exactly two roles; it does not replace system scrolling, keyboard, accessibility or URL delivery.

Owner **Stop sharing with others** removes the captured accepted and pending non-owner participants and persists the retained share. It does not delete a share, zone or household, change its public permission, move objects, make a backup/remapped home or retarget personal-cart history. **Remove contributor** and **Cancel invitation** use the same exact-participant operation. With no remaining contributors/invitations, show **Only you**; reuse that share for future invitations. Any unexpected public share fails closed with an explicit unsupported-access state; silently setting `.none` could remove public members and is forbidden.

## Framework API and compatibility

1. Capture authenticated `ShopperSession`, account generation, home/list UUIDs, owner store and full share record ID. Validate actual owner and private sharing. Reuse the home's existing share or create it through `NSPersistentCloudKitContainer.share(_:to:)`; personal graphs stay excluded per ADR 0002.
2. Read current metadata for the **known** share using the configured account's private `CKDatabase.fetch(withRecordID:)`. Managed `fetchShares` is a local known-share lookup, not proof of current server membership. Do not read/write Core Data-managed domain records through raw CloudKit APIs.
3. On iOS 18+, create `CKShare.Participant.oneTimeURLParticipant()`, set `permission = .readWrite`, add it, and capture its stable participant ID. Keep `publicPermission = .none`. Only the private owner may do this.
4. Persist membership changes with `persistUpdatedShare(_:in:completion:)`, using the exact owner store. Its local save precedes its export-completion callback. Never substitute `CKModifyRecordsOperation` for managed share persistence.
5. On successful completion, obtain the **one-time URL for the captured participant ID from the returned saved share**. A nil URL or mismatching returned share/session is an error/pending outcome, never a generic `share.url` fallback. Store pending intent/checkpoint before effects; verify account/scope again before presenting the URL. The URL sheet result is not recipient acceptance. Resending requires the latest observed participant to remain pending; historical creation success cannot authorize resending an accepted or cancelled invitation.
6. Refresh metadata on foreground, completed operation and relevant cloud events even if persistent history has no changed objects. Show accepted contributor only after actual acceptance; private pending participants need no email/name.
7. Recipient taps the system URL. `CKSharingSupported = YES`, application/scene wiring handles both running-scene callback and cold `connectionOptions.cloudKitShareMetadata`. Pass metadata to managed `acceptShareInvitations(from:into:)` with the exact shared store. Preserve existing homes and account-bound queued metadata. Show Joining/Loading until that invited home/list is locally usable; share preparation/export is not full graph delivery.

The installed public Objective-C SDK declares `oneTimeURLParticipant` and `oneTimeURLForParticipantID:` at **iOS 18**. Xcode 27's refined Swift `oneTimeURL(for:)` overlay is annotated **iOS 26**. The compile probe uses the public `NS_REFINED_FOR_SWIFT` underlying import `__oneTimeURL(forParticipantID:)` and `__participantID` inside an iOS 18 availability boundary. These are imports of public APIs, not private selectors. Keep that bridge in one small adapter. Compile under the hosted Xcode 16.4/iOS 18.5 SDK as well as local Xcode 27 before delivery.

On iOS 17, keep existing shopping and existing membership management available; Invite contributor explains **Creating invitation links requires iOS 18 or later** and performs no mutation. Do not silently use email lookup or a public link. Older recipient acceptance is not established by API availability: SHOPPING-30 must test iOS 18+ recipients, and must not advertise iOS 17 link acceptance without separate evidence. The invitation tells the sender the recipient needs a supported version of Shopping and iCloud. The app's deployment floor is unchanged.

## Durable transitions and failures

Persist a small account/home/share-bound membership intent before calling CloudKit: operation UUID, action, participant IDs, expected share change tag and captured confirmation. After metadata establishes non-application, explicit retry reconfirms that same logical operation against fresh metadata while preserving its participant and target IDs. An uncertain result cannot retry. A retry uses that logical operation; it never creates another participant just because the share sheet was cancelled or the completion was lost. Store one-time invitation material only in the correct protected account partition, never in shared household domain objects or logs. Keep the operation-to-participant mapping before export; do not re-create an anonymous participant on every retry.

| State/event | Required result |
| --- | --- |
| User cancels before confirming membership change | No change. |
| Durable local preparation fails | No cloud effect or success UI. |
| Share metadata is unavailable/offline | Keep a retryable preparation state; no fabricated URL. |
| Export in flight, including delayed callback | Pending. No claim of sent/accepted or completed revocation. |
| Export errors or app restarts after request | Outcome uncertain; fetch/reconcile before retrying. A request may have succeeded remotely. |
| Invitation addition succeeded; Messages is cancelled | Pending invitation remains. Offer Send link again or explicit Cancel invitation, not silent rollback. |
| Recipient accepts | Refresh and show Contributor; the one-time URL now behaves as the ordinary private-share URL. It cannot authorize a different uninvited account. |
| Pending invitation cancelled | Remove exact participant and export; verify on devices that its old link cannot admit someone. |
| Participant removed | Retain owner data/share and other participants. Verify old claimed link cannot restore that membership. |
| Account/home changes during request | Do not show the URL/result in the new scope. Quarantine the old operation and reconcile only under its verified original account; an in-flight network effect cannot be undone by changing UI state. |
| Conflicting share version, partial error or concurrent membership edit | Fetch/reconcile intent; no blind replay of an old complete participant array and no automatic restoration of removed members. Show changed membership when a new confirmation is required. |

Serialize local membership writes and metadata refreshes within the account/home coordinator. Assign request generations before asynchronous work; reject earlier-generation callbacks after a newer result has been applied, including after cancellation or account transitions. CloudKit change tags are opaque and cannot be numerically ordered. The mock uses an ordered version solely to represent old versus fresh observations. Before and after an operation, compare the intended exact participant set with observed metadata. A captured remove-all does not authorize removing a newly arrived invitation; report remaining members and require a fresh confirmation. Never repeatedly chase new members in a background loop. Nor should a removal conflict silently re-add members that another owner device removed. CloudKit supplies no documented atomic managed membership transaction; `serverRecordChanged`/partial errors must be handled and the actual framework conflict behavior proved in 30. The fixture's version check is an injected conflict, not a claim that `persistUpdatedShare` exposes compare-and-swap or a configurable save policy.

## Leaving and retained data

Contributor **Leave home** is distinct from owner **Stop sharing with others**. Confirm the exact home and explain loss of the shared working copy. If there are pending household effects, offer Cancel (return to status) or Leave now (they may never reach this home). Retain account-private snapshots/history/own cleanup and quarantine outstanding household effects; later rejoining does not automatically authorize replay of the old membership's effects.

For participant leave, use the documented managed removal path only after rechecking the current non-owner, confirmed share zone and **nonoptional exact `.shared` persistent store**. `purgeObjectsAndRecordsInZone(with:in:completion:)` with `nil` can affect associated stores, and is prohibited. Owner stores, personal-account stores, other home zones and legacy source stores cannot be targets. Failures preserve a resumable uncertain state; no whole-store reset. Successful remote revocation still does not mean an offline device instantly erased its cache. Preserve original-scope editor contents while invalidating write capability and checkout captures.

Leaving does not promise permanent invitation revocation or removal of the participant's row from the owner's roster. Apple's [CloudKit sharing explanation](https://developer.apple.com/videos/play/tech-talks/703/) describes deleting a participant's shared zone as returning that participant to an invited state while preserving the owner and other participants. Verify departure by completion of the exact shared-store operation and loss of its local working copy; inspect the owner's accepted/pending state in SHOPPING-30. Reacceptance, including reuse of the participant identity, still requires fresh app authority and must not replay quarantined effects. The prototype models a retained pending participant to avoid depending on roster deletion.

Native share-management callbacks are unreachable by design, not ignored in a delegate. No `cloudSharingControllerDidStopSharing` handler or owner purge is added as a shortcut. Direct system/account revocation must still be handled through session/metadata lifecycle events in SHOPPING-129.

## Executable evidence and delivery boundaries

`swift test --package-path Prototypes/HomeSharingContract` runs isolated mocked fixtures with atomic JSON checkpoints. It exercises link creation/export/delivery ordering, unknown-recipient claim, forwarded-link rejection after claim, cancel/resend, removal retention, concurrent invite versus captured removal, export failure, restart after export, late callbacks after scope changes, contributor leave/quarantine, roles per home, operation-ID reuse and failed local preparation. It is not connected to iCloud or the app. Its fake cloud enforces the intended private-link semantics; those assertions are requirements for live proof, not evidence Apple has enforced them. It models one home working copy per checkpoint; production cleanup must prove multi-store/multi-home exclusion.

`API/InvitationAPIProbe.swift` typechecks the actual framework calls for an iOS 17 deployment target with iOS 18-gated creation. It does not send an invitation or implement durable account checks; SHOPPING-125/128 supply those. Document native presentation/accessibility checks in 128, real persistent interruption/isolation tests in 129/131, and live results in 30. Full app tests are not a substitute for these boundaries.

SHOPPING-30 must test two distinct iCloud accounts on physical iPhones, one-time links claimed and forwarded before/after acceptance, cancellation/revocation/reinvitation, retained owner graph and IDs, participant-leave zone isolation, concurrent owner-device changes, unavailable account/network, callback loss and relaunch, accepted invite before graph import, and same-owner private-cart exclusion. Record exact OS/build/source and both sides' observations. Neither pending invite count nor successful export establishes peer receipt. Stop release if retention, membership or private-authority evidence fails.

Implementation order: 124 active-home/session coordinator; 125 share graph and membership transport; 126 incoming lifecycle; 127 safe adoption/join; 128 native member/URL UI; 129 access removal/leave; 130 status; 131 cross-feature validation; 30 live proof; 8 production readiness; 7 final onboarding acceptance. 123 selects these interfaces without prematurely claiming their implementation.

Local validation on 2026-09-29: all 12 mocked XCTest cases passed on the macOS host with Swift 6.4/Xcode 27. The iOS 17-targeted API probe compiled successfully with the iOS 27 simulator SDK and the iOS 18 availability boundary. The Swift-overlay availability mismatch was reproduced and resolved using the public refined Objective-C import. Hosted Xcode 16.4 compilation and physical invitation/retention remain later gates. No app target or schema changed in this issue.

## Sources

- [Apple managed sharing sample and custom UI](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users)
- [One-time URL participant](https://developer.apple.com/documentation/cloudkit/ckshare/participant/onetimeurlparticipant())
- [One-time participant URL](https://developer.apple.com/documentation/cloudkit/ckshare/onetimeurlforparticipantid:)
- [Public permission removes public participants when disabled](https://developer.apple.com/documentation/cloudkit/ckshare/publicpermission)
- [Managed share persistence and export completion](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/persistupdatedshare(_:in:completion:))
- [Native share-management controller](https://developer.apple.com/documentation/uikit/uicloudsharingcontroller)
- [URL activity delivery](https://developer.apple.com/documentation/uikit/uiactivityviewcontroller/init(activityitems:applicationactivities:))
- [SwiftUI invitation lifecycle](https://developer.apple.com/documentation/coredata/accepting-share-invitations-in-a-swiftui-app)

Rejected: public reusable read/write link. It admits forwarded-link holders, does not provide the required private-member removal contract, and switching to `.none` removes public participants. Its stable URL has no documented safe rotation contract. Rejected: mandatory email lookup, because it contradicts the user's join-link requirement. Rejected: owner purge/deep-copy migration, because participant removal preserves the original graph and avoids unnecessary identity changes.
