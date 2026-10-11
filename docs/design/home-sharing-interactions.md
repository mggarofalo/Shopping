# Home sharing interactions

Approved October 6, 2026. Phase 28 implements the Home Settings proposal through
SHOPPING-202 (presentation state), SHOPPING-203 (private invitation records),
SHOPPING-204 (screen and journeys), and SHOPPING-205 (physical evidence).

## Phase 33 route contract (1.6.0)

Settings → Homes is the single entry. A Home name selects it; its separate info
link opens that exact Home's details without selecting it. Details Back returns
to Homes, and Done dismisses the sheet. There is no global Home Settings row.
Inactive account Home commands retain their own graph identity and the captured
account/store presentation. Share preparation, rename, invitations, leave and
deletion never substitute the currently selected Home. Retiring the captured
presentation invalidates its commands.

## Presentation contract

Home Settings uses the custom home name as its native large navigation title,
with a pencil rename action for writable homes. Grouped sections contain accepted
members, named invitations, sharing status, and destructive actions. A background refresh
keeps the last known content visible and does not disable navigation or editors.
Command progress is explicit and placed beside the initiating action. Permission,
membership freshness, and command progress are distinct states. Every mutation
still validates its captured account, home, and participant at execution time.

Ordinary sync-status publications do not trigger membership reloads. Refreshes
coalesce, and a result captured before a command or retired scope cannot replace
newer presentation. Renaming completes after the durable name save, without
waiting for an unrelated network membership check.

## Invitation journey

Invite someone opens a naming form immediately. Creating an invitation saves its
name before remote work and binds its participant before submitting membership.
The resulting detail page offers Share invitation. Closing the share sheet keeps
the same invitation. Share again reuses the same participant and link.

An invitation can be a draft, creating, ready to share, waiting to join, awaiting
an uncertain result, or awaiting cancellation. A share-sheet completion records
handoff only; it never proves delivery or reading. Acceptance comes from actual
membership evidence. Show the actual accepted identity, retaining invited-as
context when it helps distinguish that identity from the owner's label.

Labels and handoff history are private to the owner and synchronize through the
existing account-private graph. They are not household People, authorization,
recipient verification, or shared graph relationships. Portable matching uses
account/container/environment plus logical home and share identity, not another
device's local store identifier or managed-object URI.

Reuse an active invitation with the same normalized name. Different people with
the same name need distinguishing labels. Independent offline owner devices can
create concurrent records before synchronization: preserve and expose distinct
capabilities; never silently revoke, merge, or infer recipient equivalence.
Strict person-level deduplication would require recipient identification before
creation and is outside this anonymous one-person link flow.

Existing anonymous invitations remain separately navigable and can be named or
cancelled individually. Legacy uncertain journals retain their recovery path.
Editing a label does not change the capability or claimed recipient identity.

## Other journeys

- Offline readers keep saved content and drafts. Actions requiring iCloud explain
  their requirement at the action; errors do not turn the entire screen inert.
- An empty name has inline validation. Failed commands retain entered values.
- iOS 17 shows the iOS 18 invitation requirement inline.
- Removal, cancellation, leave, and deletion name their target in confirmation.
  Durable uncertain outcomes remain visible and cannot submit duplicate effects.
- Lost access or changed account retires the old presentation; saved drafts remain
  bound to their original scope and home selection remains reachable.
- Navigation, scrolling, Dynamic Type, and accessibility remain native. Progress
  and errors use text as well as color and are available to VoiceOver.

## Evidence

Fast tests own private persistence, normalized-name rules, replica projection,
scope isolation, uncertain recovery, command/refresh sequencing, and blocked-writer
responsiveness. HomeDetailsUITests owns naming, opening invitation details,
share-sheet dismissal, reuse, confirmation, and accessible presentation. Existing
fixture isolation and relaunch contracts remain in force.

SHOPPING-205 owns physical Animation Hitches evidence and real two-account/two-owner-
device delivery. Its target is no app-caused main-thread hang of 250 ms or more,
with repeated 100 ms stalls investigated. Simulator and stateful backend results
do not establish real CloudKit timing or physical-device performance. Preserve
installed TestFlight data when collecting traces.

## 1.5.3 presentation refinement (SHOPPING-212)

Routine member refresh is silent: no inserted spinner row and no elapsed-check
timer. Pull-to-refresh retains native progress, and command progress and errors
remain explicit. A stable passive iCloud label uses an accent cloud, with text
for observed activity or attention; it does not claim all devices are synchronized.
A separate Sharing details row makes diagnostic navigation explicit. This uses
the status-versus-detail distinction illustrated by
[CloudSyncStatusView](https://github.com/platadani/CloudSyncStatusView), without
adding a dependency or replacing the application's existing CloudKit monitor.
