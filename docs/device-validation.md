# Device validation

## Current evidence

The September 6 UI feedback is tracked in SHOPPING-33, SHOPPING-34, and SHOPPING-35. The app uses category-first wrapping pills, full-row catalog editing, one quantity control and Urgent toggle, distinct reusable/current notes, compact filters with a store-clear icon, In cart wording, and a persistent System/Light/Dark preference. Grocery captions stay with their first row, and cart/history actions use the toolbar.

| Area | Evidence | Status |
|---|---|---|
| Historical persistence and UI baseline | SHOPPING-29: 130 unit and 27 UI tests passed | Verified baseline |
| Historical compact regression | `/tmp/Shopping9-compact-regression.xcresult`: 32 UI tests passed | Superseded UI; baseline only |
| Updated compact appearance and controls | `/tmp/Shopping-feedback-device-4.xcresult`: appearance persistence, store-clear/filter behavior, Dynamic Type growth, long-name shopping controls, and primary-screen control audits pass | 5 checks passed |
| Updated visible-row full accessibility audit | `/tmp/Shopping-feedback-visible-row.xcresult`: 1 passed on iPhone SE (3rd generation), iOS 26.5 | Passed with the verified scope correction below |
| Complete updated regression and CI | 130 persistence + 30 UI passed in the complete run; corrected promotion and final device checks described below | Final CI pending |

The visible-row test audits all accessibility issue types after positioning the complete grocery cell clear of the navigation and tab bars. Ordinary reveal gestures use normal pans; slow held drags are reserved for final audit alignment to prevent momentum from moving the row afterward. Platform reports can include list text covered by the opaque navigation bar: the compact simulator reported contrast for wholly covered Urgent text, while CI reported partially covered Filters 1 text as clipped.

The latest test replaces the initial covered-contrast exception with visible remeasurement. Identified collection-view static text is queued only for contrast or clipping when its unique containing cell crosses the navigation/tab viewport boundary; every other report fails. Each queued label and its whole cell must become fully visible and hittable, and pass a repeat audit of the reported type. Scrolling can expose another edge report, which must also pass its own remeasurement. The queue is bounded and fails on overflow; same-candidate, unidentified, and nonedge repeat findings fail. Both passes retain diagnostic attachments. This proves the reported text in a fully visible cell instead of assuming hidden text is correct.

`/tmp/Shopping-feedback-final-device.xcresult` passes all six selected tests on iPhone SE (3rd generation), iOS 26.5: the five device checks (including full audit plus visible remeasurement) and the remembered-editor save/cancel/relaunch check. The earlier complete run, `/tmp/Shopping-feedback-full-regression.xcresult`, passed 130 persistence and 30 UI tests; its three promotion failures were corrected. All four promotion tests subsequently passed in `/tmp/Shopping-feedback-corrections.xcresult`. The final iOS 18-compatible increment-child query is awaiting a focused rerun and CI.

Apple's [Perform accessibility audits for your app](https://developer.apple.com/videos/play/wwdc2023/10035/) describes investigating platform false positives. Independent Terra review accepted the bounded remeasurement design after checking that each candidate must pass with its full cell visible. Automated results do not replace physical VoiceOver testing.

Primary-screen control audits cover element detection, hit regions, descriptions, and traits; they are not full-screen contrast/Dynamic Type audits. Separate tests measure title, caption, and quantity growth across four text sizes and exercise long names at accessibility XXXL. Light and dark appearance screenshots were inspected, and the preference survives relaunch. SHOPPING-9 remains In Progress until physical checks are recorded.

## Physical-device and live-sharing gates

No physical devices are currently available. Before release, verify on both household phones:

- VoiceOver order, labels, traits, focus movement, and 44pt controls on Groceries, In cart, recovery, add/edit, filters, and promotion.
- Default-size and larger-text typography, including compact-device truncation, pinned header/footer visibility, long names, long notes, and purchase-rule labels.
- Offline creation, carting, scoped clear/Undo, recovery after force-quit/relaunch, and reconnect behavior.
- Reduce Motion behavior during cart, clear, recovery, navigation, and confirmation.
- Real two-account household sharing: invitation acceptance, owner/participant writes, concurrent edits, store tags, recovery, revocation, and convergence.

Simulator checks do not validate VoiceOver behavior on hardware, airplane-mode persistence, or live CloudKit sharing.

Record device model, OS version, build, date, and pass/fail evidence for each physical check. SHOPPING-30 owns real invitation, transport, permissions, and convergence evidence; Apple Developer enrollment (SHOPPING-10) remains a prerequisite. The earlier request to connect a phone remains unanswered.
