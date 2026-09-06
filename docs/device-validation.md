# Device validation

## Current evidence

The September 6 UI feedback is tracked in SHOPPING-33, SHOPPING-34, and SHOPPING-35. The app uses category-first wrapping pills, full-row catalog editing, one quantity control and Urgent toggle, distinct reusable/current notes, compact filters with a store-clear icon, In cart wording, and a persistent System/Light/Dark preference. Grocery captions stay with their first row, and cart/history actions use the toolbar.

| Area | Evidence | Status |
|---|---|---|
| Historical persistence and UI baseline | SHOPPING-29: 130 unit and 27 UI tests passed | Verified baseline |
| Historical compact regression | `/tmp/Shopping9-compact-regression.xcresult`: 32 UI tests passed | Superseded UI; baseline only |
| Updated compact appearance and controls | `/tmp/Shopping-feedback-device-4.xcresult`: appearance persistence, store-clear/filter behavior, Dynamic Type growth, long-name shopping controls, and primary-screen control audits pass | 5 checks passed |
| Updated visible-row full accessibility audit | `/tmp/Shopping-feedback-visible-row.xcresult`: 1 passed on iPhone SE (3rd generation), iOS 26.5 | Passed with the verified scope correction below |
| Complete updated regression and CI | Running on the integrated feedback branch | Pending |

The visible-row test audits all accessibility issue types after positioning the complete grocery cell clear of the navigation and tab bars. Slow drags with a final hold prevent momentum from moving the row after positioning. A narrowly scoped exception handles a verified platform contrast false positive: identified, non-hittable collection-view static text wholly above the opaque Groceries navigation bar's bottom edge, excluding navigation-bar descendants. Visible text, partial overlaps, unidentified elements, other screens, and every other audit type still fail. Every report, including the covered-content report, is retained as a test attachment.

The diagnostic attachment in `/tmp/Shopping-feedback-settled-row.xcresult` identifies the Urgent filter at y=0.5–69, wholly covered by the opaque bar ending at y=74; its screenshot confirms no text pixels are visible. This exception follows Apple's guidance to investigate and narrowly handle false positives in [Perform accessibility audits for your app](https://developer.apple.com/videos/play/wwdc2023/10035/). It does not hide application accessibility elements or skip the audit. Independent Terra review found the condition conservative; automated results do not replace physical VoiceOver testing.

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
