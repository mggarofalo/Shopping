# Performance validation

SHOPPING-59 covers the Groceries, Catalog, and Settings flows with deterministic loaded-data fixtures and points-of-interest signposts. The representative fixture contains 500 catalog items, 500 active needs, 20 stores, and 100 categories. The stress fixture doubles the catalog and need counts to 1,000 while retaining 20 stores and 100 categories.

Each comparable UI pass first creates a fresh, versioned SQLite store in a disposable launch. The measured launches reopen that seeded store, so fixture generation is excluded from startup observations. Every outer pass uses its own store and resets it before use. Catalog batch additions and edits therefore start from equivalent data in all three passes.

## Remediation

The initial 1,000-need grocery projection took 827–848 ms because it fetched each remembered catalog item separately. The projection now prefetches its graph and resolves all candidate item UUIDs with one bulk fetch. Invalid or unresolved identities continue to fail closed.

## Automated latency evidence

Measurements below are Debug simulator results on Xcode 26.6 (17F113), iOS 26.5, using the 1,000-item stress fixture. The test warms each operation, records monotonic wall time, reports nearest-rank percentiles, and fails if projection worst-case latency reaches 100 ms or batch-preview latency reaches 150 ms.

| Operation | p50 | p95 | Worst |
| --- | ---: | ---: | ---: |
| Catalog, all items | 15.619 ms | 15.998 ms | 16.122 ms |
| Catalog, filtered | 12.454 ms | 13.055 ms | 13.182 ms |
| Groceries, all needs | 33.250 ms | 33.566 ms | 33.572 ms |
| Groceries, filtered | 29.869 ms | 30.377 ms | 31.202 ms |
| Catalog batch preview, 1,000 items | 16.797 ms | 17.595 ms | 17.595 ms |

The post-remediation persistence suite passed 154 tests with no failures. After the native selection update, three clean loaded UI passes completed in 291.413 seconds with no failures. These durations include XCTest queries, taps, typing, waits, app relaunches, and scrolling and are not app-response latency measurements.

## Trace points

The `com.mggarofalo.shopping` points-of-interest log marks Catalog projection, Grocery projection, Catalog grouping, Management batch preview, Persistence command, Core Data save, Catalog add preview, and Catalog add apply intervals. These intervals support Time Profiler, Animation Hitches, and Processor Trace inspection without adding per-row logging.

## Physical-device evidence

Three benchmark passes ran on an iPhone 16 Pro with iOS 27.0 (24A5430a) using the 1,000-item stress fixture. The benchmark operations run off the app's main thread so the measurement loop itself does not stall the UI. All three passes completed without a Hang Detection event.

| Operation | p50 range across runs | Worst across runs |
| --- | ---: | ---: |
| Catalog, all items | 9.023–9.268 ms | 19.078 ms |
| Catalog, filtered | 7.706–7.754 ms | 7.930 ms |
| Groceries, all needs | 20.525–20.795 ms | 21.856 ms |
| Groceries, filtered | 19.029–19.502 ms | 20.043 ms |
| Catalog batch preview, 1,000 items | 11.968–13.477 ms | 22.729 ms |

The signed Shopping 1.2.0 (5) build, including the native selection update, was installed on the device. A fresh 12 MB Time Profiler trace captured the 1,000-item stress workload and its Shopping points-of-interest intervals. Its Potential Hangs table contained no event at or above 250 ms; the longest measured operation across the three clean benchmark passes was 22.729 ms.

An Animation Hitches trace of the loaded catalog flow initially reproduced a 260.14 ms main-thread interval while changing grouping, filtering to a store, selecting all eligible items, and adding them to the list. The trace attributed repeated work to `CatalogView` rebuilding category and store scopes for every item during SwiftUI body evaluation. Catalog groups are now rebuilt once when their inputs change. Three consecutive physical-device traces of the same flow recorded worst intervals of 212.91 ms, 204.99 ms, and 192.25 ms. None reached the 250 ms hang threshold.

Processor Trace was also attempted twice. Even with a four-second capture window, Instruments produced a 1.6 GB incomplete trace that could not be exported. Time Profiler, Animation Hitches, signposts, and the XCTest measurements above remain the reproducible evidence for this issue.
