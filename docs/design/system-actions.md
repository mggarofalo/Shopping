# System actions · 1.6.3 candidate

Milk & Bananas advertises two actions: Add item and Search catalog. The
Open grocery list intent remains callable for existing saved shortcuts. The icon menu is a UIKit Home Screen Quick Action surface. Siri and
Shortcuts use App Intents. Both enter the same app-owned routing and persistence
lifecycle; neither owns another Core Data stack.

A request for navigation carries the current presentation identity when a Home
is ready. One request may wait while an editor or invitation is presented. It
never dismisses that presentation. Cancel, five-minute expiry, or a changed
Home/account retires it. An unbound cold navigation request may enter the normal
Home setup/selection flow; it is not authority to write data. System Add starts
with no store, category, urgency or text filter, preserving the separate
contextual behavior of the in-app Add button.

The shared runtime drives bootstrap loading without needing a mounted root view.
Initial UI/background requests coalesce. Store transitions continue to wait for
mounted views to retire; a cancelled intent does not tear down stores used by UI.
The existing scoped service and presentation authority remain the command fence.

The Add operation accepts a free-text item prompt so unknown names can reach an explicit
creation handoff. Required catalog entity resolution must not swallow that path.
Exact normalized matches outrank substring matches. Ambiguous results need a
choice; no result offers a prefilled editor after native foreground continuation.
A one-time need already on the list whose name matches exactly (after the same
folding) is reported as “already on your grocery list” instead of offering a new
catalog item, unless a catalog item has that exact name. Substring matches never
select a one-time need, and the lookup never makes one-time needs suggestions.
Only an explicit save creates catalog data. If a subsequent list add fails, the
saved catalog item is retained and the partial result is explained. Existing
needs, including carted ones, are reported without silently renewing or editing
quantity, person or urgency. Reads and writes retain the captured Home/account.

No persistent Spotlight donation or remote inference is introduced. Siri speech
processing is controlled by iOS; app-qualified phrases and actual supported
language/device behavior need system-level evidence, independently of tests.

The framework distinctions and foreground handoff are documented by Apple:
[Home Screen quick actions](https://developer.apple.com/documentation/uikit/add-home-screen-quick-actions),
[App Shortcuts](https://developer.apple.com/design/human-interface-guidelines/app-shortcuts),
and [ForegroundContinuableIntent](https://developer.apple.com/documentation/appintents/foregroundcontinuableintent).
Existing actions retain iOS 17 compatibility. The modern Siri schema requires iOS 27 and Xcode 27; older compilers exclude that adapter. Release metadata checks fail if it is omitted.

The two App Shortcuts use static app-qualified phrases, such as “Add an item in
Milk and Bananas” and “Add to my shopping list in Milk and Bananas”. There are no catalog-item phrase templates or catalog
suggestions exported during registration. App Shortcut phrases cannot interpolate
an unrestricted String parameter. The older Add action prompts for a name;
saved shortcuts can still supply text or a remembered catalog entity. Matching folds case, diacritics,
width and whitespace. Duplicate matches present numbered native choices with
category and purchase rules. More than twenty matches requests a narrower name;
no candidate is silently chosen or truncated. Archived items, one-time needs and
unresolved catalog relationships do not become suggestions. Entity identities
include the captured local Home graph, so reimported or other-Home entities must
be selected again. No command crosses an account or Home change during dialogue.

All callable mutation/navigation actions require device authentication. Catalog reads use the existing
writer and return immutable values. The add captures catalog and need revisions
before disambiguation, then uses the existing duplicate-safe catalog-add command.
Cancellation is checked before command dispatch. Success dialogue follows the
durable save; existing needs report “already on your grocery list”. The app does not implement a natural-language parser.

## System registration and discovery

Registration updates once at startup. Catalog edits, Home transitions and scene
activation do not rebuild trigger phrases. Explicit entity identifier and text
queries remain available for saved shortcuts, but never authorize a write:
execution checks current Home-qualified identity and captured revisions.

The iOS 27 adapter adopts `.reminders.createReminder` with a free-form title and
returns the durable saved occurrence as a reminder entity. Only the selected
Home’s grocery list is exposed. List lookup recognizes “shopping list”, “my shopping list”,
“the shopping list”, “grocery list”, “groceries”, “shopping” and the app’s own
name (“Milk and Bananas”, “Milk & Bananas”), since the app has one list per Home. This only resolves
the list after Siri selects the app; it does not reserve unqualified requests or
set a system default reminder app. Purchased or superseded occurrences are excluded
by the existing outstanding-demand projection. Unsupported dates, recurrence,
attachments, tags, notes, flags and location/section parameters fail before saving.
The schema requires these parameters to exist even when the app cannot support
their semantics. Required unsupported entity types return no query candidates.

Both adapters use `CatalogAddDialogue` for lookup, captured choices, add and scoped
creation handoff. The modern action declares `supportedModes` of background plus
dynamic foreground instead of the deprecated `ForegroundContinuableIntent`. Siri
runs it in the background; only an unknown name calls `continueInForeground`
(skipped when the app is already in front), then queues the prefilled editor and
returns no entity, because nothing is saved until the user chooses Save and Add.
A request that arrives while the user has a sheet open waits behind it (the app
never dismisses the user's work), and a further unknown name then fails with the
spoken “finish or cancel the pending action” message rather than a generic error.

Every wait inside a system action is bounded. Readiness, including the loading
transition, fails after 15 seconds with “still opening”. Each store read or write
fails after 10 seconds with a spoken “didn’t respond in time” message; the
abandoned store work may still finish, and duplicate-add rules keep a retry safe.
Persistence errors that have no spoken text (for example duplicate remembered
needs) become a user-facing failure instead of Siri’s generic problem message.

SHOPPING-258 exercised the 1.6.3 action through AppIntentsTesting system
execution on the iOS 27 simulator (`supportedModes` was foreground-only, 8). From a
backgrounded app, the old unknown-name continuation came forward to the editor in
about one second; it did not reproduce the physical device's multi-minute spin.
With the app already in front, it returned no value to the schema
(`castingFailed NSNull`). A second unknown name queued behind the open editor
sheet and a third failed as busy. “Milk and Bananas” resolved no list. The current
modes follow Apple's replacement for the deprecated protocol; the device spin
still needs a physical re-test to confirm it is gone.

Apple now describes [SiriKit Lists and Notes](https://developer.apple.com/documentation/sirikit/lists-and-notes)
as legacy and unsupported by Apple Intelligence/Siri AI. The exploratory legacy
adapter was discarded. The candidate instead follows the current
[create-reminder schema](https://developer.apple.com/documentation/appintents/appschema/remindersintent/createreminder).
This establishes the API choice, not proof that Siri routes the user’s phrase.

Settings provides written invocation instructions and Apple's ShortcutsLink.
It does not construct SiriTipView: exact-source CI 38320208353 observed the
unselected Settings tab contacting `com.apple.linkd.autoShortcut` during grocery
presentation retirement, followed by a 167-second test and a missing-shortcut
warning while the service indexed unrelated system apps. The existing five-second
retirement assertion failed and remains unchanged. Removing the redundant tip
keeps system phrase lookup out of this screen's construction; this does not prove
spoken Siri routing or fix the separately recorded older-runtime provider failure.
The app's spoken name is
Milk and Bananas. These make invocation discoverable but are not evidence that
Siri recognized a physical user's voice. Apple documents entity phrase parameters
and refresh requirements in [Dive into App Shortcuts](https://developer.apple.com/videos/play/wwdc2023/10102/).

## Choosing between Reminders and this app (SHOPPING-266)

Any app that adopts the Reminders schema can receive an unqualified request such
as “Add milk to my shopping list”. Apple documents that the same phrases work in
every adopting app and that the system identifies the app, but not how it chooses,
whether it remembers a choice, or when it asks. That choice, speech recognition,
and whether Apple Intelligence or legacy SiriKit handles the request belong to iOS.
Developer-forum reports describe the chooser appearing even when the app is named,
and schema routing only on devices with Apple Intelligence enabled.

The app controls three things:

- App Shortcut phrases always name the app, so they route here without a chooser.
  The Add shortcut covers both “grocery list” and “shopping list” wording; the
  metadata guard rejects a phrase without the app name and a missing wording.
  Phrases cannot carry a free-form item name (WWDC23 “Dive into App Shortcuts”),
  so these phrases ask for the name.
- The list query accepts the app name, so “Add bread to Milk and Bananas” resolves
  the list once Siri has chosen this app.
- Donating `createReminder` after in-app adds is Apple's only documented cue for
  learning the preferred app (WWDC26 session 343). It would put grocery names in
  the system's on-device donation store and reverses the “no persistent donation”
  choice above, so it is not adopted without a product decision.

`CFBundleSpokenName`, parameter summaries, `supportedModes` and entity synonyms
have no documented effect on app choice.

## Requests that aren't groceries (SHOPPING-270)

Adopting `createReminder` makes the app a candidate for every reminder, so iOS
may offer it for “Remind me at 9 am to call mom”. The schema cannot be narrowed:
in the iOS 27 SDK `.reminders.createReminder` is only an identifier, the macro
requires every reminder parameter, and Apple documents no way to declare a subset,
decline a request kind, or opt out of the chooser. `isAssistantOnly` and
`supportedModes` change visibility and execution, not routing.

The app declines what it cannot be. The first step of the action, before it waits
for the store, fails a request with a due date or recurrence with “Milk & Bananas
only keeps your grocery list, so it can’t set timed or location reminders. Ask
again and choose Reminders.” and logs `declined scheduledReminder`. (iOS resolves
an explicit list parameter before the action runs, which can still wait for the
store.) The location entity query returns nothing, so a location reminder either
fails during Siri's parameter resolution or arrives without a trigger; a trigger
that does arrive is declined the same way. Other reminder details still fail as
unsupported. An untimed request such as “Remind me to call
mom” is indistinguishable from a grocery name; it reaches the normal unknown-name
handoff, which asks before opening the editor and saves nothing without Save.

Removing `createReminder` would stop the chooser but would also end unqualified
“Add milk to my shopping list” routing; only app-named App Shortcut phrases would
remain. That is a product decision and is not made here.

Both Add actions log start, outcome and error type, without grocery text, in the
`com.mggarofalo.shopping` subsystem's `Siri` category at notice level, which
sysdiagnose archives keep. A request with no “started” line never reached the app.

## Validation evidence

On October 9, Xcode 27 / iPhone 18 Pro simulator iOS 27.0 (24A434), an isolated AppIntentsTesting probe queried `CatalogItemEntity` for the seeded Bananas item and executed all three intents through Apple's native out-of-process interface. The query returned one entity; Add completed, Search opened Catalog, and Open returned to Groceries. `/tmp/shopping-phase33-native-intents-seeded.xcresult` passed 1/1 without skips. The SDK 27-only diagnostic was not added to the iOS 17/Xcode 16.4 CI sources.

Siri invocation remains a separate unverified boundary. `XCUIDevice.siriService` with “Open my grocery list in Milk and Bananas” opened Siri but did not bring the app foreground within 20 seconds on iOS 26.5 or27 simulators. Failed artifacts remain `/tmp/shopping-phase33-siri-capability.xcresult` and `/tmp/shopping-phase33-native-siri27.xcresult`. These runs do not establish spoken recognition, native ambiguity prompts, or real-device foreground continuation. Domain and isolated editor tests cover their app-owned behavior; physical Siri acceptance still needs to be recorded.

On October 11, the unchanged 1.6.0 implementation appeared in Shortcuts → Apps →
Milk & Bananas on a clean iPhone 16 Pro / iOS 27 simulator, and its Add action
prompted for Bananas and returned the existing-need dialogue. The retained bundle
is `/tmp/shopping-240-shortcuts-add-confirm.xcresult`. This disproves a universal
registration failure; it does not explain the reported physical-device discovery
failure or prove the unregistered “Add milk…” phrase worked in 1.6.0.

The 1.6.2 simulator run `/tmp/shopping-240-system-ui-fixed.xcresult` passed the
icon-menu, editor persistence, and real system Shortcuts prompt/response tests.
The expanded `/tmp/shopping-240-system-handoff-final.xcresult` passed the actual
unknown-name foreground-continuation path, including prefilled editor and Cancel,
after explicitly dismissing the final system result. The test itself took 37
seconds; Xcode then spent ten minutes collecting simulator diagnostics. This is
system execution evidence, not physical Siri speech evidence.

On October 12, the 1.6.3 working candidate passed all 807 Fast tests with no skips
on iPhone 16 Pro / iOS 27 (`/tmp/shopping-241-fast.xcresult`). Its generated
metadata contains the Reminders create schema, a free-form title, local-device
authentication, two static shortcuts and both spoken app-name forms. The metadata
guard and release workflow contract tests passed. Two independent reviews found
one purchased-occurrence lookup defect; the outstanding-demand projection fix
and checkout/re-add/undo assertions passed Fast and independent re-review.

The exact-phrase Siri probe failed (`/tmp/shopping-241-voice-probe.xcresult`): Siri
showed “Sorry, something went wrong. Please try again.” A separate time-query
probe did not retain a useful answer and is inconclusive, regardless of its
negative-error assertion passing. Neither is voice routing evidence. The first
combined follow-up was interrupted while an unexpected keyboard appeared
over the Home Screen; its screenshot and log are retained under
`/tmp/shopping-241-system-and-capability.*`. Diagnostic probes are excluded from
the maintained test suite, rather than represented as passing product coverage.

The Home Screen long-press stall also reproduced on unchanged `1063484` with a
fresh iOS 27 simulator (`/tmp/shopping-241-system-baseline.log` and
`/tmp/shopping-241-baseline-menu.png`). Both runs stopped inside XCTest’s
SpringBoard-idle wait before tapping Add item. SHOPPING-242 tracks this unresolved
system/SDK boundary; neither source comparison nor screenshots prove that real
device behavior is unaffected. The maintained assertion remains unchanged.

The modern action also passed out-of-process execution with an inactive catalog
item, both shopping-list aliases and a repeated-add identity check
(`/tmp/shopping-241-modern-system-add-fixed.xcresult`, 7.068 seconds). The final
combined selection passed all 22 tests without skips
(`/tmp/shopping-241-combined-final.xcresult`); hosted CI enforces its 15 + 6 + 1
manifest. This does not establish actual Siri routing or the modern adapter’s
`needsToContinueInForegroundError` unknown-item continuation. The legacy adapter’s
separate system Shortcuts/editor path passed in
`/tmp/shopping-241-shortcuts-final.xcresult` (39.845 seconds).
