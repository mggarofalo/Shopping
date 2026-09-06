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
- Real two-account household sharing: invitation acceptance, owner/participant writes, concurrent edits, store tags, recovery, revocation, and convergence.

Simulator checks do not validate VoiceOver behavior on hardware, airplane-mode persistence, or live CloudKit sharing.

Record device model, OS version, build, date, and pass/fail evidence for each physical check. SHOPPING-30 owns real invitation, transport, permissions, and convergence evidence; Apple Developer enrollment (SHOPPING-10) remains a prerequisite.
