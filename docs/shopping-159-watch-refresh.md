# SHOPPING-159: Watch Add during local refresh

The September 28 store incident included a green swipe Add that appeared to do
nothing and a flickering Add button in item details. Its installed source/build,
watchOS version, connectivity, and trace were not captured. CloudKit correlation
remains a user observation; the reproduction below establishes a reachable local
session race, not the historical incident's exact cause.

## Cause and change

At milestone base `5ef3daf`, ordinary reload and explicit mutations shared the
same `isBusy` guard. Holding `service.load` disabled both Add controls and made a
concurrent `perform(.add(...))` return false without calling the service. Ordinary
refresh also cleared a previous command's error, allowing a periodic read to
remove its visible failure alert.

Ordinary reads now have their own private refresh state. A user mutation reserves
the command gate immediately, retains its original capture, and suspends behind
the current local read. Imports and periodic reads coalesce behind that action.
The existing real service still validates account, household, store eligibility,
permissions, and opaque causal tokens. The session rechecks its authority before
starting the deferred action and again before publishing its result. Conflicting
explicit actions receive feedback; they do not enqueue duplicate mutations.

Store choice remains an explicit serialized action. Its await completes after
the selected snapshot, preserving the chooser's success dismissal. Item details
Remove now also dismisses only when `perform` reports success. SwiftUI's native
Button, swipeActions, navigation and alert presentation remain unchanged. This
uses MainActor suspension and checked continuations as described in the
[Swift concurrency guide](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/);
no blocking waits or new UI gesture mechanism were introduced.

## Local evidence

Environment: Xcode 27.0, Apple Watch Series 11 (46mm) simulator, watchOS 26.5,
UUID `6CC1A722-336A-4CBF-B554-31B32BDB9A22`. The Watch simulator was assigned
exclusively to this issue during validation. The iPhone simulator remained owned
by the parallel sharing work.

- `/tmp/shopping-159-baseline.xcresult` and `.log`: terminal exit 65, two new
  regressions against unchanged production source, four failed assertions.
  The held-load Add did not execute; ordinary reload erased failure feedback.
- `/tmp/shopping-159-session.xcresult` and `.log`: 18 session tests passed after
  the initial correction. Later review found the store chooser awaited only
  queuing, not selection; explicit selection now uses the command gate and has
  its own held-read regression assertion.
- `/tmp/shopping-159-ui.xcresult` and `.log`: three of four UI cases passed.
  The new durable swipe test supplied an unsupported fixture name on relaunch;
  corrected to the existing UUID store plus seed-marker relaunch contract.
  The failed run remains retained. No wait or assertion was weakened.
- `/tmp/shopping-159-reviewed-watch.xcresult` and `.log`: terminal exit 0,
  all 49 Watch unit tests and five selected UI workflows passed. The UI selection
  is swipe Add failure/retry, durable swipe Add/relaunch, failed card Add/draft
  retry, durable card Add/dismissal/relaunch, and store switch/native swipe.
- Two independent read-only reviews are clear after the store-selection fix.
  Exact committed-source confirmation and CI results are recorded in the PR and
  Plane comment.

The milestone base has a stale Watch sync-details assertion for copy removed by
SHOPPING-146–152. A separate test-only commit matches the current exact sentence,
`Recent iCloud activity completed.` This is identical to the correction in the
parallel SHOPPING-129 branch; it does not alter product sync claims.

## Required physical Watch evidence

This PR remains open pending integration and the following real-device record,
coordinated with SHOPPING-122. Simulator tests do not satisfy this gate.

Record the installed commit, marketing version/build, watchOS version, Watch
model, phone version, connectivity, and whether the phone is reachable. With
ordinary CloudKit activity occurring, perform green swipe Add and item-details
Add; check the resulting private membership/quantity on Watch and the same
shopper's phone, verify successful details dismissal, and exercise a genuine
invalid action's visible feedback. Repeat while offline using cached groceries.

Capture an Animation Hitches trace covering launch, immediate scrolling, and
both interactions; record timestamps relative to imports and the `Watch snapshot
read` signpost, the trace duration, and largest app-caused main-thread hangs.
The responsiveness target is no app-caused hang of 250 ms or more. Do not replace
the installed TestFlight app merely to obtain a debug trace. If the installed
binary cannot be attached, retain that limitation and use an all-process trace
where supported. Keep SHOPPING-159 In Review until this evidence and integration
are verified; do not label the historical device report resolved from local
results alone.
