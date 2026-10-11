# SpringBoard animation-idle investigation (SHOPPING-230)

Keep the real Home Screen action test unchanged. No supported runtime improvement
has been demonstrated. The same two 60-second synchronization waits persisted
on a native XCTest worker clone. That clone had already run other suites,
including Settings transitions, and was copied from the existing destination.
Pristine, isolated simulator-state behavior remains unmeasured.

| Observation | Source | Worker setup | Test duration |
| --- | --- | --- | ---: |
| Retained Phase 33 passing Full | `61d56b21c4fb0da116c104281c2293fb435288ed` | Serial | 132.907s |
| SHOPPING-228 experiment | `39026e31478945fbf149585992f1946c89f24e3c` | Native two-worker run, clone 2 | 133.430s |

These are observations under different worker setups, not a paired optimization
comparison. Both use Xcode 27.0 (27A266a), iOS 26.5 and iPhone 17 Pro. The new
worker is `9D4B8BCC-7FF7-4FDE-B63A-1009DA928C19`. Its activity log is retained in
`docs/benchmarks/shopping-230-clone-system-action.log`; the parent raw result is
`/tmp/shopping-228-39026e3/Parallel.xcresult`.

The first wait follows the icon long press; the second surrounds the Add item
menu action. Both report that an app-animation-complete notification was not
received. The test subsequently passes its existing add-sheet, catalog search,
cancel and navigation-reset assertions. This points to automation synchronization
cost, not evidence that the app's domain operation took two minutes.

## Supported API investigation

The installed public `XCUIApplication`, `XCUIElement` and `XCUICoordinate` headers
were inspected. They expose bounded state/existence waits and normal input
operations; no per-element animation-idle bypass was identified. Apple's
[application-state wait documentation](https://developer.apple.com/documentation/xctest/xcuiapplication/wait(for:timeout:))
specifies waiting for an application state. It does not promise animation
completion. The existing icon and menu existence checks already establish those
elements before input; adding a fixed delay or another existence check would not
address the observed missing completion notification.

Do not replace the icon/menu journey with an injected pending action. Routing
unit tests prove different behavior. Do not disable global synchronization,
access private XCTest quiescence settings, skip the test, or remove its assertions.
The theoretical removable ceiling remains about 120 seconds per serial Full;
the implemented saving is zero.

## Remaining evidence

Pinned Xcode 16.4/iOS 18.5 execution of this new Phase 33 OS-entry test has not
been measured here. The passing SHOPPING-227 compatibility run compiles it but
executes only the six Acceptance UI methods, so it is not runtime evidence for
this test. Do not dispatch speculative hosted Full to investigate it. If an SDK
update or documented per-action remedy becomes available, compare this unchanged
journey locally and on the pinned environment before accepting a fix. Preserve
both failed and passing activity logs and complete command elapsed time.
