# Home management and onboarding

SHOPPING-170 · Phase 24 · Design proposal · October 2, 2026

Give people one visible home name, one place to switch homes, and one direct invitation flow. An accepted invitation opens that home's grocery list as soon as it is ready. Setup, import, and recovery work happen behind this flow.

The [interactive HTML prototype](home-experience.html) illustrates the proposed experience. It does not demonstrate working CloudKit sharing. Native implementation and two-phone validation remain separate work.

## Product decisions

### Create once or join directly

Recommend an explicit, single-tap `Create Home` on an ordinary first launch. It creates `My Home` and opens the list. Renaming is available in Home Settings. Creating an additional home uses a Name form.

A first launch from an invitation skips creation. The invitation supplies the destination. An existing account restores its homes and last selection before showing a first-use state.

The current local bootstrap can create a home named `Household` automatically. Existing instances remain legacy homes with their data intact. The new first-use flow makes creation deliberate; it does not reinterpret those old homes as account-owned.

Creating a home merely because an installation has an empty cache risks duplicates while iCloud restores existing homes. Automatic creation would require a reliable account-level first-use decision and deletion support. It offers little benefit over one clear action. Do not create another home after the user deletes or leaves their last one.

If account discovery is unfinished, show `Loading Homes…` with a progress indicator. Offer an explicit creation action when appropriate without claiming that no other homes exist. Never interpret a failed read as an empty account.

People without an available iCloud account can continue using their existing local groceries. On a fresh offline launch, `Create Home` creates a local home marked `On This iPhone`. No sign-in is required to begin shopping. It must not silently become a duplicate cloud home later. Invitations require iCloud; explain that requirement only when it blocks joining. Creating additional cloud homes requires an available account; never silently substitute a local home for that request.

### Put the active home in the interface

Phase 33 (1.6.0) keeps native page titles and makes Settings the Home switching entry point. Groceries, Catalog and My Cart retain passive Home context when several Homes exist or a retained local Home is in use.

Catalog and the current My Cart show a passive `house` + home name row only when several homes exist or a retained local home is in use. My Cart is reached from Groceries, not a separate tab. Settings has one first-section Homes row with the selected Home name as secondary text. It opens Homes. Stores, Categories and People are grouped under the selected Home name; Appearance and About are app settings. Home Settings keeps its own title without another switcher. Saved carts from other homes always show their captured home name as static context; the currently selected home must never label a saved cart from a different home. Editors continue to target their captured home. A background home change must never redirect an existing edit.

The Homes sheet uses a native NavigationStack and grouped List. Each row has a selection button and a separate info-circle details link with distinct accessible labels and 44-point targets. A checkmark identifies the selected Home. Selecting a name dismisses the sheet; inspecting details does not select it. Create Home follows the Homes section. There is no global Home Settings row. Details Back returns to Homes; Done dismisses the sheet. In no-home states, use the native readiness content without a blank home row, extra top inset, or separator.

Inactive account Homes support the same permission-aware details actions without
selection changes. A retained local Home that is not mounted exposes its saved
name and On This iPhone context; select it to manage local settings through the
existing store lifecycle. Viewing that summary never mounts a competing store.

Use a native sheet with a List because the collection may grow and include retained local homes. Do not build a nested menu tree. Show `On This iPhone` only for a retained local home. Show Owner or Member in settings, where the distinction changes available actions.

Scope store filters and list preferences by home. My Cart shows the selected home's entries from the shopper's private graph. Switching homes keeps the shopper's other carts associated with their original homes. Never combine lists, catalogs, or carts as a side effect of switching.

Watch also shows the name of the home whose list and cart it is displaying. Preserve the established device-selection policy; do not imply that changing the iPhone home necessarily changes Watch selection. A Watch command captures its actual home scope. Small screen size permits a shorter visible name, with the full name available to accessibility.

Saved personal carts and history remain reachable from My Cart or Settings. The retained local home stays in Homes with `On This iPhone`. Recovery and optional migration never block normal joining.

### Accept invitations directly

Opening an invitation enters the join flow immediately. The user never needs to find Home Settings, Sharing Status, or an invitation inbox first.

CloudKit may already present the system acceptance interface before delivering metadata to the app. That acceptance counts as the user's join intent. Do not ask them to accept again. Show one app sheet with the home name and `Joining…`, then open the invited list.

If an entry path genuinely has no prior acceptance, show the inviter and home name with `Join Home` and `Not Now`. Join captures both acceptance and selection intent. Loading and errors replace content in this same sheet.

The current app has valuable protections around exact share identity, account binding, and rejoining. Keep them. Replace the later `Open [home]` decision with the earlier recorded join-and-open intent.

Successful import opens the home automatically only while that intent remains current. If the user dismisses the flow, chooses another home, or changes account, background completion must not move them unexpectedly. Show a ready `Open [home]` notice throughout the active app for that deferred completion, not only on Groceries.

Retain existing local groceries separately while joining. No copy, migration, cart ownership, or local-versus-iCloud choice belongs in the invitation path. Retention does not attribute legacy carts to the shopper. Moving local groceries to iCloud remains an explicit action available later from that local home's settings.

Dismissal does not pretend to revoke a CloudKit acceptance already in progress. It stops automatic navigation and keeps the durable operation available. Reopening the same invitation resumes or opens its home without creating another membership.

### Keep Home Settings small

Use one grouped Form with these rows:

- Name, editable by the owner.
- Members, with `You` and `Owner` where useful.
- `Invite` for owners, using `person.badge.plus` alongside its label.
- A pending invitation row with resend and cancel actions when needed.
- `Delete Home` for owners or `Leave Home` for members.

An invite opens the native share sheet after creating or resuming its link. Remove the explanatory sheet that currently precedes it. Put the link's necessary disclosure beside the Invite action: `Anyone with this link can join. One person per link.`

A retained local home's settings shows `Use iCloud` before sharing is available. That action explicitly copies the selected home's groceries and settings into an owned cloud home; it never merges into a joined home or claims legacy carts. Retain the local source under the existing adoption policy. After successful conversion, offer Invite normally. Account unavailability shows one actionable explanation in place. This exceptional migration flow stays outside invitation acceptance.

Member details expose `Remove Member`. Omit a separate `Stop Sharing` surface from the new form. Owners can remove individual members or delete their home. Keep existing persisted removal commands valid during migration; removing a UI action must not strand their recovery.

Show healthy sharing without a permanent status paragraph. Show actionable problems beside the affected action. A secondary details destination may expose diagnostics for support, but it never sends the user around the navigation hierarchy.

### Delete and leave deliberately

Owners can delete any home they own, including their only home. Members can leave. Both actions use a native destructive confirmation with the exact home name.

Deleting removes the shared list, catalog, and home settings. Private cart records, receipts, and recovery evidence remain retained under their existing identities. Their pending effects must be quarantined so they cannot recreate or mutate the deleted home.

Leaving ends the member's access and retains their private history. Rejoining requires a new valid grant and the existing rejoin checks. Show an unsent-change warning only when current evidence establishes affected work.

After deleting or leaving the active home, open a sole remaining eligible home. With several remaining homes, show Homes for selection. With none, show `No Homes` and `Create Home`. Never create a replacement automatically.

The UI may show `Deleting…` or `Leaving…` while remote confirmation is pending. It must not claim that every device has already removed its offline copy. Persist intent before retiring the current graph, and resume after relaunch.

Owner deletion is a new capability proposal. No current code or mockup proves that complete managed CloudKit deletion works. Establish its supported native operation, retained-data disposition, and recovery behavior before enabling the production control.

`Recoverable deletion` in the implementation backlog means that an interrupted command can resume safely. It does not promise Undo. Home deletion is irreversible once committed, as the confirmation states. Private cart and recovery evidence remains retained, but it is not a backup that can recreate the home.

Before destructive work, durably record the exact account and graph, the authorized revision, affected-data disposition, and command progress. Preserve private evidence and quarantine pending effects before removing the graph. This checkpoint supports retries and proof of what was removed; it does not require a speculative whole-home backup service.

## Copy and iconography

Use short labels for actions and recognizable symbols for navigation. Keep visible text on consequential actions. VoiceOver receives full labels and values; visual brevity must not reduce accessibility.

| Situation | Visible copy | Action or symbol |
| --- | --- | --- |
| Ordinary first launch | `Create a Home` | `Create Home`; house |
| Invitation hint on first launch | `Invited? Open your invite link.` | No extra setup button |
| Groceries context | Current Home name when needed | Passive house label |
| Catalog and current cart context | Current home name when several homes exist or local home is retained | Passive house label |
| Settings first row | `Homes` and current Home name | Opens Homes |
| Saved cart from another home | Captured home name | Passive house label |
| Homes selector | Home names | Checkmark selected; separate info link; plus for Create Home |
| New additional home | `New Home`; `Name` | Cancel; Create |
| Invitation before acceptance | Home name; `[name] invited you` | Join Home; Not Now |
| Accepted invitation | Home name; `Joining…` | Progress indicator; dismiss |
| Import takes longer | `Still Loading` | Keep loading automatically; dismiss |
| Failed join with connectivity error | `Couldn’t Join`; `Check your connection and try again.` | Retry; Not Now |
| Expired or revoked invitation | `Invite Unavailable`; `Ask for a new invite.` | Close |
| iCloud unavailable for joining | `Sign In to iCloud`; `Sign in in Settings, then return here.` | Open Settings; Not Now |
| Account changed | `iCloud Account Changed`; `Switch back to continue joining.` | Close |
| No homes after leave or delete | `No Homes` | Create Home |
| Owner invitation | `Invite` | person.badge.plus |
| Link disclosure | `Anyone with this link can join. One person per link.` | Inline secondary text |
| Owner removal | `Remove [name]?`; `They’ll lose access to this home.` | Cancel; Remove Member |
| Owner deletion | `Delete “[home]”?`; `Deletes its list, catalog, and settings for everyone. This can’t be undone.` | Cancel; Delete Home |
| Member departure | `Leave “[home]”?`; `You’ll need another invite to rejoin.` | Cancel; Leave Home |
| Proven unsent work during departure | `Unsent changes will be lost.` | Add only when relevant |
| Local home | `On This iPhone` | iphone |
| Delete an unshared local home | `Delete “[home]”?`; `Deletes its list, catalog, and settings. This can’t be undone.` | Cancel; Delete Home |
| Deferred completed join | `[home] is ready` | Open |

Error text must describe the actual failure. Do not map unknown failures to a connectivity diagnosis. A generic fallback is `Couldn’t Join` with `Try again.` Technical details belong in diagnostics.

Apple Account settings are not exposed through the ordinary app-settings URL. `Open Settings` must use a supported destination and honest instructions. The prototype must not imply a guaranteed direct route to iCloud sign-in.

Aim for action labels of 1 to 3 words and ordinary explanatory copy of one short sentence. Destructive consequences take the words they need. No glossary, onboarding carousel, role essay, or generic sync disclaimer is required.

## Tap budget and acceptance criteria

Count both app screens and any system acceptance surface when measuring invitation depth. Network waiting is separate from navigation depth.

| Journey | Target |
| --- | --- |
| Open invite with available account | System acceptance, if shown, plus at most one app join sheet |
| App receives already accepted invite | Zero additional acceptance taps; opens list when ready |
| App receives unaccepted invite | One Join Home tap; no later Open or Done requirement |
| Return to deferred invitation | One visible invitation action, then the same join sheet |
| Switch Home | Settings → Homes → Home name |
| Switch from Catalog or cart | Settings → Homes → Home name |
| First explicit creation | One Create Home tap using My Home |
| Additional home | Homes → Create Home → Name form; Create completes |
| Open Home details | Settings → Homes → info beside the exact Home |
| Invite from Home Settings | One Invite tap to the system share sheet |
| Delete or leave | One action plus one destructive confirmation |

Account sign-in is an external prerequisite, not another application submenu. When required, return to the same invitation after sign-in. Never make users repeat the application's join path.

Acceptance evidence must cover these outcomes:

- Cold and warm invitation launches reach the intended home within the budget.
- A fresh invite launch never creates an unwanted personal home.
- Existing local groceries remain accessible after joining without an adoption question.
- Repeated link opens, interrupted imports, and relaunches do not duplicate homes or memberships.
- A late join completion does not override a newer selection or account.
- Every home-scoped screen and editor identifies its home when multiple homes exist.
- Delete and leave work for active, inactive, and last homes; relaunch resumes pending operations.
- Private carts, purchase history, checkout recovery, and legacy ownership rules remain intact.
- Names with long text, emoji, duplicate names, and accessibility text sizes remain understandable.
- VoiceOver announces the selected home and all icon actions; touch targets are at least 44 points.
- The app remains usable while import and background persistence work are running.

For duplicate home names, add owner or local-device context in Homes. Do not silently rename a shared home to resolve ambiguity.

## Current implementation and friction

The evidence below comes from the current main checkout. Line numbers are navigation aids and may move during implementation.

| Source | Finding | Change |
| --- | --- | --- |
| `Shopping/App/PersistenceRootView.swift:14` | A missing home presents waiting explanations and several navigation routes. | Replace with a small root readiness presentation. |
| `Shopping/Views/HomeInvitationNotice.swift:12` | An incoming invitation becomes a banner the user must find and open. | Route explicit incoming acceptance directly to the join sheet. |
| `Shopping/Views/HomeInvitationsView.swift:12` | Account setup, local retention, loading, ready selection, and errors share one expanding list. | Present one invitation state at a time. |
| `Shopping/Views/HomeInvitationsView.swift:56` | After accepting and importing, users must choose Open again. | Fulfill the durable earlier join-and-open intent. |
| `Shopping/Views/HomeSelectionView.swift:73` | Home selection pushes back into invitation review. | Resolve pending invitations through the root route. |
| `Shopping/Views/HomeDetailsView.swift:115` | Home details links to Choose Home; its status page also links to homes and invitations. | Make Homes and Home Settings stable destinations without circular links. |
| `Shopping/Views/HomeDetailsView.swift:163` | Inviting opens an explanatory sheet before the share sheet. | One direct Invite action with short inline disclosure. |
| `Shopping/Views/PersonalCartSetupView.swift:11` | Home setup exposes private-cart architecture and copy choices. | Move migration choices out of first-use and join flows. |
| `Shopping/App/ActiveHomeCoordinator.swift:59` | Account-bound selection, generations, and deferred selection already exist. | Preserve and extend explicit intent handling. |
| `Shopping/App/ActiveHomeCoordinator.swift:158` | Selection is saved per account, with no command to forget a removed graph. | Clear only the removed saved selection, then reconcile remaining homes. |
| `Shopping/App/PersistenceBootstrap.swift:953` | Invitation preparation captures local retention and account state. | Extract setup policy; joining chooses retention without a migration prompt. |
| `Shopping/App/PersistenceBootstrap.swift:1490` | Invited-home activation performs serialized verification and rejoin checks. | Reuse behind automatic completion of current user intent. |
| `Shopping/App/PersistenceBootstrap.swift:1601` | Home creation has a durable command journal and guarded selection. | Expose it through the new creation UI. |
| `Shopping/App/ShoppingSceneDelegate.swift:7` | Cold and warm CloudKit callbacks already reach the invitation controller. | Feed one presentation router from both entry paths. |
| `Shopping/Views/HomeDetailsView.swift:72` | Stop sharing and member leave exist; owner deletion is absent. | Add an explicit deletion command and recovery policy. |

The present screens already use many native SwiftUI controls. The main problem is the navigation and state model exposed to the user. A visual reskin alone would retain that problem.

## Refactor first, then change behavior

Implement in dependency order. Keep commits and Plane acceptance criteria scoped to each step.

1. Extract the home presentation boundary without changing behavior. Separate root navigation, home operations, and immutable view state from `PersistenceBootstrap`. Reuse existing coordinators and journals. Add only contracts required by these consumers.
2. Define a finite home-entry presentation state and one root presentation owner. Cover loading, no home, active home, join progress, recoverable error, and deferred invitation. Avoid independent sheet booleans that can compete.
3. Add a durable invitation navigation intent. Bind it to invitation identity, account, and the user's selection generation. System acceptance or Join creates intent; dismissal or a newer selection defers it. Existing verification decides when activation is safe.
4. Replace invitation presentation. Retain local data automatically, connect the verified account, accept or resume, import, validate, and activate through the same sheet. Keep the journal's distinction between acceptance and activation.
5. Add the shared home control, flat Homes sheet, and simplified Home Settings. Reuse the current name editor and member commands. Capture scope in editors and commands.
6. Expose creation and define first-use resolution. Prefer an existing selection, then a sole existing eligible home; show Homes for several homes and the creation state for none. A pending explicit invitation takes priority over first-use creation.
7. Implement owner deletion behind its own durable command boundary. Capture account, graph, revision, and required authority. Quarantine pending effects, perform managed CloudKit removal, verify completion, and reconcile selection. Add a scoped coordinator operation to forget the removed saved graph without clearing another home's newer selection. Never implement deletion as a view-context cascade.
8. Replace explanatory invitation and removal sheets with direct actions and native confirmations. Map domain errors to the short copy table. Keep technical diagnostics available separately.
9. Remove obsolete routes and copy after all entry paths use the new presentation contract. Update previews, focused tests, and documentation.

### State transitions

```text
Launch
  explicit invitation → Join
  saved eligible home → Grocery List
  one eligible existing home → Grocery List
  several homes → Homes
  discovery unfinished → Loading Homes
  no homes → Create a Home

Join
  system already accepted / Join Home → Joining → Importing → Verify → Grocery List
  dismiss / newer selection → deferred completion → Open when requested
  temporary failure → same sheet, Retry
  invalid invitation → same sheet, Close
  account unavailable → same sheet, Settings → resume

Delete / Leave
  confirmation → durable pending command → verify → reconcile remaining homes
  interruption → resume same command after relaunch
```

The UI may collapse Joining, Importing, and Verify into one progress label. Domain states remain distinct for correctness and recovery.

### Boundaries that must survive the rewrite

Preserve exact local graph identity, account isolation, current command authority, and serialized participant operations. Do not replace these with a household UUID alone.

Keep personal cart authority in the private graph. Household cart presence remains advisory. A simpler onboarding flow never claims legacy local cart flags or purchase history for the authenticated user.

Creation, acceptance, activation, deletion, and leaving need durable outcomes that survive process death. Selection is presentation state with its own intent and generation checks. A committed domain action must not become a duplicate retry because selection failed.

Use background workers for persistence and CloudKit-related work. Publish immutable results on the main actor. Follow `docs/ui-responsiveness.md`, including its blocked-writer and device-trace requirements.

The existing one-time invitation implementation checks iOS 18 availability while the app targets iOS 17. The implementation issue must validate a supported native sharing route on iOS 17, or document a product-level deployment decision. Do not ship an unexplained disabled Invite button.

## Validation and delivery

Use the HTML mockup to review navigation, copy, and state changes before changing Swift behavior. It should support first launch, joining, switching, settings, creation, deletion, leaving, and at least one retry path.

Then use native previews and UI tests to validate the actual platform controls. HTML approximations cannot prove Dynamic Type, VoiceOver, native sheet behavior, or CloudKit timing.

Run ShoppingFast and the focused acceptance UI paths for changed behavior. Add domain tests for new intent and deletion consequences, including relaunch and account-change races. Retain existing fixture isolation and coverage gates. Use the shopping-testing skill for implementation and diagnosis.

Finish with two physical iPhones using distinct iCloud accounts. Record cold and warm joins, existing-local-data joins, home switching, deletion, leaving, and an interrupted operation. Capture tap counts and short screen recordings. Preserve the repository's distinction between simulated evidence and proven household sharing.

Phase 24 uses this dependency order:

| Issue | Deliverable | Depends on |
| --- | --- | --- |
| SHOPPING-170 | Reviewed design and interactive HTML prototype | Ready design work |
| SHOPPING-171 | Refactored home entry and invitation contracts | SHOPPING-170 |
| SHOPPING-172 | Native onboarding, joining, home switching, and visible scope | SHOPPING-171 |
| SHOPPING-173 | Recoverable owner deletion and membership management UI | SHOPPING-172 |
| SHOPPING-174 | Focused tests and two-phone acceptance evidence | SHOPPING-173 |

Each implementation issue includes its own focused checks; SHOPPING-174 completes the cross-flow and device proof. A mockup review or passing simulator test is not evidence that the rewrite is ready for TestFlight.

## Apple guidance used

Apple recommends learning through using the app and keeping onboarding short and optional. The proposal uses direct creation or joining, with context-specific recovery. See [Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding).

Apple's CloudKit invitation documentation describes system acceptance before scene-delegate delivery. The app must honor that existing choice. See [Accepting share invitations in a SwiftUI app](https://developer.apple.com/documentation/coredata/accepting-share-invitations-in-a-swiftui-app).

Use one sheet for a scoped task and native controls for sharing. See [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets), [Activity views](https://developer.apple.com/design/human-interface-guidelines/activity-views), and [Collaboration and sharing](https://developer.apple.com/design/human-interface-guidelines/collaboration-and-sharing).

Keep commands short and avoid deep submenu hierarchies. Destructive actions use clear labels and confirmations. See [Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus) and [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts).

These sources inform the native components and interaction principles. The specific home policy, state transitions, and copy above are product recommendations grounded in this repository.

## Prototype review evidence

Safari review on October 2 verified the flat two-tap home switch, direct accepted-invitation completion, one-tap first creation, owner deletion confirmation, last-home empty state, and successful retry within the same invitation sheet. The review also caught and corrected a Safari script-name collision and a missing first-create action.

The prototype uses simulated homes and invitation timing. Grocery rows illustrate home context; they do not propose replacing the shared grocery-row layout. Native accessibility, durable operations, real account setup, system invitation delivery, member commands, and CloudKit behavior require the implementation and device checks above.
