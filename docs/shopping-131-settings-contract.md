# SHOPPING-131 offline Settings contract review

Prepared September 30, 2026, against remote head `d7099994c735554bfacbf1e03ce33eb885a7150d`. The repair is local and unvalidated in UI automation. This review accounts for the entire Settings path; it does not establish passing sharing checks, Full attestation or SHOPPING-30 two-phone proof.

## Evidence and limits

- **Pinned 18.5:** [run 36763446056](https://github.com/mggarofalo/Shopping/actions/runs/36763446056) ran all three selected methods once, without skips. Both sharing methods reached Larger Text and captured the same complete hierarchy before failing and before global Settings mutation. Promotion passed. The captured trees show one range Cell, identified StaticText, one nested Switch with value `0`, and one unlabelled Slider with value `50%`. Neither Slider nor its Cell exposes `DYNAMIC_TYPE_SLIDER`.
- **Local 26.5:** retained Home details result at `/tmp/shopping-131-settings-navigation-local.feIrrJ/Results.xcresult` passed on the earlier helper source. Its strict count assertions establish one identified outer Switch, one nested Switch and one Slider inside the identified Cell. Activities establish the button navigation route; attachments establish same-process Large → accessibility XXXL → Large and exact original/restored switch `1`, position `0.27272728085517883`, displayed value `27%`, and Large category. This result contains no complete Settings tree and does not validate the new helper.
- **API contract:** installed Apple XCUIAutomation headers specify live query counts, queries retained by `.element`, containment by descendant, variable raw `value` types, and best-effort slider adjustment. The range reader accepts only `0` and `1` as String or NSNumber. Other representations fail readiness. Slider displayed values must remain readable Strings; position/category assertions remain authoritative.

## Complete operation table

| Operation | iOS 18.5 retained evidence | iOS 26.5 retained evidence | Repair or retained requirement | Still unverified |
| --- | --- | --- | --- | --- |
| Launch Settings / reopen retained page | Both methods launch and reach Larger Text. | Earlier method passes complete round trips. | Existing launch/activate calls; Larger Text identity required by every control snapshot. | New snapshot readiness during activation. |
| Open Accessibility | Existing identified Button successfully tapped. | Existing identified Button successfully tapped. | Existing bounded existence/hittability and single tap retained. | No new selector introduced. |
| Open Display & Text Size | Identifier belongs to StaticText in a visible Cell; destination reached. | Identified Button route passes. | Shared unique button-or-containing-cell resolver; source/destination checks. | Existing routes already exercised; new helper overall remains unvalidated. |
| Open Larger Text | Same containing-cell shape; destination reached. | Identified Button route passes. | Same row resolver, bounded hittability, single tap, destination check. | Same limit as above. |
| Resolve range actuator | No identified Switch; one Cell containing identified StaticText and one Switch descendant. | One identified outer Switch and exactly one nested Switch pass prior assertions. | Prefer unique identified outer Switch; otherwise require zero identified Switches and one containing Cell. Require one nested Switch. Never use an index or first match. | Executing the new containment query on 18.5; structure after changing range. |
| Read range state | Actual Switch exposes textual hierarchy value `0`; raw Any type not captured. | Outer Switch value reads succeed as String `1`. | Preserve outer value owner for identified route; use actuator value for Cell route. Normalize only binary String/NSNumber values. | New 18.5 value read and normalization in XCUI. |
| Resolve slider | Zero identified Cells; exactly one Slider in complete Larger Text tree. | Unique Slider in identified Cell passes prior assertions. | Prefer one identified Cell with one Slider. Otherwise require zero identified Cells, exactly one Larger Text navigation bar, and one page Slider. Ambiguous identified Cells or an identified Cell with a missing/ambiguous Slider do not select the fallback. | Executing the page query on 18.5; uniqueness after a range change. |
| Read original slider state | Hierarchy reports `50%`; no mutation or normalized-position getter ran. | Original position/displayed value captured and restored exactly. | Read unique Slider value and normalized position before registering teardown, then before any mutation. | Raw String read and normalized-position getter on 18.5. |
| Change range | Not executed by pinned sharing methods. | Prior runs perform range changes and restore state. | Resolve both controls and bounded hittability; tap only when state differs; check requested state. | New routes during a real 18.5 change. |
| Change size | Not executed by pinned sharing methods. | Prior fixed-range Large/XXXL transitions pass actual UIKit observations. | Re-resolve Slider after range change, bounded hittability, one adjustment, normalized-position check. Keep range on, Large at 3/11 and XXXL at 1. | 18.5 tick mapping and actual category transitions. |
| Return to Shopping | Product size checks never reached on pinned run. | Same-process category observations and product checks pass locally. | Original process, nonce, foreground app, increasing sequence and observation timestamp after activation; no relaunch or adjustment retry. | These new-helper round trips on both runtimes. |
| Restore original state | Pinned run changes nothing; no restoration exercised. | Exact switch/position/display/category restoration passes earlier helper. | Register teardown before first mutation. Use same resolver and action path; verify original displayed Slider value and fresh original category. | 18.5 restoration including an initially disabled accessibility range. |
| Failure evidence | Both complete trees are retained. | Earlier results provide activities and metadata, not a full tree. | Gather both route counts, descendant counts and values before readiness verdict. Capture full hierarchy initially and on resolver timeout. | Runtime execution of the repaired capture path. |

The initial structural routes are supported by evidence. The rows marked unverified require runtime validation; this patch makes no claim that snapshots prove actions, tick mapping, asynchronous readiness or restoration.

## Deterministic source accounting

The task-local audit lives in the repository's common Git directory at `.git/shopping-validation-evidence/shopping-131/offline-settings-contract/`. It records one Preferences owner, two helper callers, all five control identifiers, and 87 distinct source-located XCUIAutomation references across 10 query APIs. It includes references through local aliases, subscripts, enum cases and initializers. `XCUIElement+Waiting.swift` was read separately and typechecked with the helper.

The earlier audit omitted initializer references and subscripts because it filtered AST node names. The corrected extraction uses every source-located XCUIAutomation declaration, including `processed_init`, and records that correction in `audit-parser-coverage-correction.json`. Counts above describe this candidate only; they are not retrospective claims about the earlier audit.

`reviewed-source.json` freezes the reviewed helper's exact SHA-256 and declaration/location inventory. `audit-source.py` rejects changed source, owner/caller/identifier drift, incomplete observation ordering, missing uniqueness branches or additional action sites. It checks restoration registration before first size mutation. These files are task evidence, not a new CI policy or a substitute for UI validation.

The offline hierarchy map independently parses both captured 18.5 trees and accounts for the proposed containing-Cell/Switch and page-Slider routes. It models captured structure, not XCUI execution, and is never used by tests to find or manipulate controls. Runtime selection uses native queries exclusively.

## Review status and stopping rule

- Refactor recorded before locator changes: `refactor-before-locator-repair.swift` and `.patch`.
- Local repair typechecks for the iOS 17 simulator target; source accounting and diff whitespace review pass.
- No tests, simulator launches, CI runs, pushes or integration were performed for this repair.
- Stop here with the patch and this table reviewable. Any future runtime validation needs a separately agreed bound; a new failure remains blocking and does not automatically authorize a follow-up run.
- Temporary diagnostic workflow removal and exact-SHA local/remote Full validation remain required before integration. SHOPPING-30 live proof remains open; Beka's installed TestFlight build establishes access only. SHOPPING-159 PR #56 remains open/unmerged.
