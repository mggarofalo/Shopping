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

## Physical-device and live-sharing gates

No physical devices were connected during this validation. Before release, verify on both household phones:

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
