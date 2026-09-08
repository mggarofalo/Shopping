# Device validation

## Current evidence

The September 6 UI feedback is tracked in SHOPPING-33, SHOPPING-34 and SHOPPING-35. The app uses category-first wrapping pills, full-row catalog editing, one quantity control and Urgent toggle, distinct reusable/current notes, compact filters with a store-clear icon, In cart wording, and a persistent System/Light/Dark preference. Grocery captions stay with their first row, and cart/history actions use the toolbar.

| Validation | Result |
|---|---|
| Final local device checks, head `870d43a` | 5/5 on iPhone SE (3rd generation), light; 5/5 on iPhone 17 Pro, dark; iOS 26.5 |
| Complete local regression before interaction-helper corrections | 130 persistence and 30 UI passed; three promotion interaction failures subsequently repaired |
| Promotion correction | All four promotion tests passed on both local screen sizes, preserving quantity, notes, identity and conflict assertions |
| Catalog supporting-text contrast, follow-up `11d7388` | Focused fully visible catalog-row contrast regression passes on compact light and large dark simulators |
| Appearance and editor checks | Light/Dark screenshots inspected; appearance persists after relaunch; editor save/cancel/relaunch passed |
| PR 2 final pinned CI `870d43a` | 130 persistence and 33 UI tests passed on Xcode 16.4 / iOS 18.5 ([run](https://github.com/mggarofalo/Shopping/actions/runs/34030326000)) |

The final local device bundles are `/tmp/Shopping-feedback-compact-adaptive.xcresult` and `/tmp/Shopping-feedback-large-adaptive.xcresult`; both have zero failed, skipped or expected-failure tests. Earlier promotion/editor evidence is retained in `/tmp/Shopping-feedback-corrections.xcresult`, `/tmp/Shopping-feedback-final-device.xcresult` and `/tmp/Shopping-feedback-large-dark-final.xcresult`. The large combined run's scrolling failure was repaired and covered by the final five-test rerun. These paths identify local session artifacts, not committed repository files.

The full accessibility test audits every issue type. Contrast or clipping reports qualify for remeasurement only when an identified collection-view label has a unique containing cell crossing the navigation/tab viewport boundary. Every queued label and its whole cell must become fully visible and hittable, then pass a repeat audit of the reported type. New edge reports must pass their own remeasurement. The queue is bounded; overflow, same-candidate, unidentified, nonedge or unresolved findings fail. Initial and repeated reports retain diagnostic attachments.

Ordinary reveal gestures use normal pans to engage native List/search scrolling. After an overshoot reverses direction, a slow held drag removes momentum to align a tall cell. The helper retains strict visibility checks and fails with captured geometry if it cannot reveal the target. Independent review found no remaining defect in this bounded approach. Apple's [Perform accessibility audits for your app](https://developer.apple.com/videos/play/wwdc2023/10035/) describes investigating platform false positives; automated results do not replace physical VoiceOver testing.

Small catalog captions initially failed the contrast threshold while fully visible. They now use the stronger adaptive supporting-text color already used by grocery rows. The focused row-contrast regression passes in `/tmp/Shopping-feedback-catalog-contrast-fixed.xcresult` (compact light) and `/tmp/Shopping-feedback-catalog-contrast-dark.xcresult` (large dark). It fails every finding inside the unique visible catalog row and retains outside-row reports as diagnostics; it does not claim a full-catalog contrast audit.

Primary-screen control audits cover element detection, hit regions, descriptions and traits. Separate tests measure title, caption and quantity growth across four text sizes, exercise long names at accessibility XXXL, and run the full grocery-row audit with the visible remeasurement described above. SHOPPING-9 remains In Progress until physical checks are recorded.

## SHOPPING-65 offline edit latency

On September 8, an iPhone 16 Pro running iOS 27.0 beta found that saving an item quantity edit in Airplane Mode appeared to hang for approximately 15–20 seconds. The save eventually completed, and the new quantity was still present after force-quit and relaunch. The exact retained-Wi-Fi state and originating build identifier were not recorded.

The local app configuration does not use CloudKit, so network unavailability should not make its SQLite save slow. The pre-fix lifecycle nevertheless started a persistent-history pass whenever the app returned to the foreground, including after closing Control Center. That pass could fetch history and refresh the main context while the editor synchronously waited on the serial writer. The fix removes history consumption and remote-change observation from local-only stores; managed private/shared CloudKit stores retain both. Editor updates now await the serial writer without blocking the main actor.

Automated regression evidence covers two separate requirements:

- A disk-backed composite edit completes in under one second and preserves its quantity and both note fields after the store is closed and reopened.
- When the serial writer is deliberately unavailable, the main actor remains responsive and the queued edit completes durably after the writer becomes available.

The foreground/history overlap is the strongest code-level explanation for the physical delay, but the original 15–20-second event was not captured with signposts, so it is not claimed as a proven root cause. Existing `Persistence command` and `Core Data save` signposts distinguish queue/history contention from SQLite save time if it recurs.

Post-fix physical acceptance passed September 8 on an iPhone 16 Pro running iOS 27.0 beta with build 1.2.0 (5). In the requested Airplane Mode checks, including with Wi-Fi unavailable, item-edit dismissal felt immediate (observed under one second) and the updated values remained correct across app restarts. Reconnection produced no reported loss, duplicate need, or second blocking pause.

## Physical-device and live-sharing gates

No physical devices were connected during the initial simulator validation above. The later sections record the available-iPhone checks; before release, verify the remaining two-phone behaviors:

- VoiceOver order, labels, traits, focus movement, and 44pt controls on Groceries, In cart, recovery, add/edit, filters, and promotion.
- Default-size and larger-text typography, including compact-device truncation, pinned header/footer visibility, long names, long notes, and purchase-rule labels.
- Offline creation, carting, scoped clear/Undo, recovery after force-quit/relaunch, and reconnect behavior.
- Reduce Motion behavior during cart, clear, recovery, navigation, and confirmation.
- Real two-account household sharing: invitation acceptance, owner/participant writes, concurrent edits, store purchase rules, recovery, revocation, and convergence.

Simulator checks do not validate VoiceOver behavior on hardware, airplane-mode persistence, or live CloudKit sharing.

Record device model, OS version, build, date, and pass/fail evidence for each physical check. SHOPPING-30 owns real invitation, transport, permissions, and convergence evidence; Apple Developer enrollment (SHOPPING-10) remains a prerequisite.

## September 7 physical pass

Validation resumed on a connected iPhone 16 Pro running iOS 27.0 beta (24A5430a), using a signed Debug build from `milestone/phase-5` plus the SHOPPING-9 fixture-path change. The test bootstrap now resolves a fixture path into the app's Application Support directory when the path supplied by a hardware UI-test runner belongs to a different sandbox. Absolute writable paths continue to work on Simulator. This keeps the test source platform-neutral and separates test data from the phone's normal Shopping store. It retains at most 12 app-owned UI-test stores and 24 history tokens; a physical 14-store launch sequence retained the current 12 stores as expected.

The isolated populated fixture passed these physical checks through iPhone Mirroring:

- Added a remembered item with Produce and Costco purchase constraints; it appeared in the active list and under Costco's Only buy here group.
- The Costco projection showed Any store items under Can buy here and did not admit ineligible store-constrained items.
- Need again moved the carted Strawberries occurrence back to the active Costco list with its quantity and purchase constraint retained.
- Terminating and relaunching without reseeding reopened the same isolated store and retained the new item and lifecycle changes.
- An Accessibility XXXL launch displayed growing grocery, quantity, store, filter, and settings text using the hardware runtime. Simulator automation remains the authoritative reachability measurement until the signed physical UI-test runner is available.
- Checkout captured the two displayed cart occurrences, removed them after explicit confirmation, and retained both recovery batches across a forced relaunch. Restoring each batch returned Party ice and Strawberries to the cart with their one-time/catalog identities and quantities intact.
- With Airplane Mode enabled, changing Strawberries from quantity 2 to 3 persisted across process termination and relaunch. This phone retained Wi-Fi while Airplane Mode was enabled. A second launch with Wi-Fi disabled reopened the isolated store, and a USB copy of that store retained Strawberries at quantity 3 and Party ice at quantity 3 with both occurrences carted. Cellular remained available during that launch, so an edit made with both radios unavailable is still needed to prove complete network isolation.
- With Reduce Motion enabled, Groceries, Recently cleared, In cart, Checkout review, Catalog, and Settings reached stable layouts with all tested actions available. Reduce Motion was restored to its original Off setting afterward.

The matching simulator run passed all 6 `ShoppingDeviceUITests` and all 5 `PreviewFixtureTests`. A physical XCUITest invocation could build the app but could not sign `com.mggarofalo.shopping.tests.xctrunner`: Xcode has no configured developer account or provisioning profile for that runner. SHOPPING-10 owns that external signing setup. SHOPPING-61 tracks the broader move to shared test plans, Swift Testing traits/tags where appropriate, platform-neutral fixtures, and ratcheting coverage gates. SHOPPING-62 tracks the cramped multiline text observed in the Checkout explanation and the broader app-wide text-layout audit.

VoiceOver was enabled on the phone, the isolated app launched, and the grocery list and item editor remained usable while it was active. The earlier notification prompt did not reappear after permission to choose Don’t Allow was granted, so no notification setting was changed. VoiceOver was restored to its original Off setting. Broader hardware focus-order and gesture coverage remains pending because the physical XCUITest runner cannot yet be signed. An edit made with both Wi-Fi and cellular unavailable also remains. Real two-account sharing remains SHOPPING-30.

## September 8 follow-up

The SHOPPING-9 branch was updated to `milestone/phase-5` and validated again on the pinned iPhone 17 Pro simulator. The `ShoppingFast` plan passed all 154 tests, the `ShoppingDevice` plan passed all 6 UI tests, and the focused `PreviewFixtureTests` suite passed all 7 tests. New fixture-path coverage proves that a writable absolute Simulator path is preserved and that a hardware-runner path outside the app sandbox falls back to Application Support while pruning complete SQLite store groups and old history tokens.

The connected iPhone 16 Pro still could not start the physical `ShoppingDevice` plan. Command-line automatic provisioning reported no configured Xcode account and no matching profiles for the app, persistence-test bundle, or `com.mggarofalo.shopping.tests.xctrunner`; SHOPPING-10 remains the external gate.

iPhone Mirroring allowed both cellular data and Wi-Fi to be disabled and visibly confirmed Off. Disabling Wi-Fi then interrupted Mirroring, including when the device remained reachable to `devicectl`, so the automation channel could not enter or observe an edit with both radios unavailable. Wi-Fi and cellular data were restored afterward. The September 7 Airplane Mode edit/relaunch result therefore remains the strongest physical persistence evidence, and the stricter both-radios-off edit remains pending rather than being inferred from a launch-only check.

A subsequent hands-on Airplane Mode check exposed a severe responsiveness failure: saving an item quantity edit appeared hung for approximately 15–20 seconds before the editor eventually resolved. Force-quitting and relaunching afterward showed that the updated quantity had persisted, so local durability passed but the offline save interaction did not. The exact Wi-Fi state retained during this attempt was not independently recorded. SHOPPING-65 tracks diagnosis and remediation and blocks completion of SHOPPING-9.

## SHOPPING-9 completion

SHOPPING-65 subsequently recorded the post-fix physical acceptance above: on the connected iPhone 16 Pro running iOS 27.0 beta, Airplane Mode item edits dismissed in under one second, remained durable across restarts, and reconnected without reported loss, duplication, or a second blocking pause. After merging that fix into the SHOPPING-9 branch on September 8, the prescribed iPhone 17 Pro simulator passed all 157 `ShoppingFast` tests and all 6 `ShoppingDevice` UI tests.

SHOPPING-9 therefore completes the local shopping-flow, persistence, recovery, accessibility, motion, and available-device validation scope. Only one physical iPhone was connected for this evidence, so this result does not claim a two-phone or two-account pass. SHOPPING-30 retains the explicit two-account/two-iPhone invitation, transport, permission, conflict, and convergence matrix required before the shared MVP can ship.

## SHOPPING-62 multiline text audit

The September 8 audit covered checkout and recovery confirmations, grocery and catalog editors, filters, empty and error states, row captions, settings descriptions, purchase-rule guidance, and transient feedback. Multiline copy now uses semantic text styles with additional leading and unrestricted vertical growth. Feedback bars and checkout rows switch from horizontal to vertical layouts when width is constrained. Empty and persistence-recovery states use scrollable native text and controls instead of the fixed `ContentUnavailableView` composition that clipped anonymous text fragments at Accessibility XXXL. The recovery screen also preserves the Retry button's own accessibility identity rather than inheriting a container identifier.

Automated evidence on iOS 26.5 includes:

- All 157 `ShoppingFast` tests and all 8 `ShoppingDevice` UI tests passed on the prescribed iPhone 17 Pro simulator.
- The two focused multiline scenarios passed at Accessibility XXXL on the compact simulator. They cover the checkout explanation and rows, both editor note descriptions, settings guidance, the empty state, a representative long persistence error, and a 44-point Retry target. Screenshots are retained in the local xcresult bundles.
- `ShoppingAppearanceUITests.testPrimaryScreensEditorsAndFiltersInBothAppearances` passed at default and Accessibility XXXL sizes in both light and dark appearances, retaining screenshots for Groceries, both filter sheets, both editors, and Settings.
- Text-clipping and sufficient-description audits pass for the checkout and persistence-recovery scenarios. The compact empty state is verified through its rendered copy and screenshot because the system search field reports its single-line placeholder as clipped at Accessibility XXXL; that unrelated platform control is covered separately by the existing primary-screen tests.

A Debug device build from the SHOPPING-62 worktree was signed, installed, and inspected on the connected iPhone 16 Pro. The earlier cramped Checkout observation is the before evidence. After screenshots show the Checkout explanation, captured-item row, editor note descriptions, and Settings household copy with readable spacing in both light and dark appearances. A separate Accessibility XXXL launch showed the complete Checkout paragraph wrapping without truncation; scrolling revealed its final line and captured-item section while Cancel and Checkout remained fixed and reachable. The isolated populated fixture did not touch the phone's normal grocery store, and the original System appearance preference was restored afterward. The September 7 hardware pass supplies the matching VoiceOver and Reduce Motion evidence.

## SHOPPING-64 editor controls

The grocery and catalog editors now give empty reusable and temporary note fields two visible lines, allow longer input to expand without clipping, and place their scope guidance in placeholders that disappear as text is entered. When quantity is set, its clear action is inline with the 1–99 Stepper, has its own accessible label and 44-point target, and disappears when quantity is unset. Focused grocery-editor UI coverage exercises both default and accessibility text sizes; existing persistence and recovery suites continue to cover optional quantity and retained notes across save, relaunch, re-add, and recovery paths.
