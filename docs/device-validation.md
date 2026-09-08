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

No physical devices were connected during this validation. Before release, verify on both household phones:

- VoiceOver order, labels, traits, focus movement, and 44pt controls on Groceries, In cart, recovery, add/edit, filters, and promotion.
- Default-size and larger-text typography, including compact-device truncation, pinned header/footer visibility, long names, long notes, and purchase-rule labels.
- Offline creation, carting, scoped clear/Undo, recovery after force-quit/relaunch, and reconnect behavior.
- Reduce Motion behavior during cart, clear, recovery, navigation, and confirmation.
- Real two-account household sharing: invitation acceptance, owner/participant writes, concurrent edits, store purchase rules, recovery, revocation, and convergence.

Simulator checks do not validate VoiceOver behavior on hardware, airplane-mode persistence, or live CloudKit sharing.

Record device model, OS version, build, date, and pass/fail evidence for each physical check. SHOPPING-30 owns real invitation, transport, permissions, and convergence evidence; Apple Developer enrollment (SHOPPING-10) remains a prerequisite.
