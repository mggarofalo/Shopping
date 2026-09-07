# Performance validation

SHOPPING-59 covers the Groceries, Catalog, and Settings flows with deterministic loaded-data fixtures and points-of-interest signposts. The representative fixture contains 500 catalog items, 500 active needs, 20 stores, and 100 categories. The stress fixture doubles the catalog and need counts to 1,000 while retaining 20 stores and 100 categories.

Each comparable UI pass first creates a fresh, versioned SQLite store in a disposable launch. The measured launches reopen that seeded store, so fixture generation is excluded from startup observations. Every outer pass uses its own store and resets it before use. Catalog batch additions and edits therefore start from equivalent data in all three passes.

## Remediation

The initial 1,000-need grocery projection took 827–848 ms because it fetched each remembered catalog item separately. The projection now prefetches its graph and resolves all candidate item UUIDs with one bulk fetch. Invalid or unresolved identities continue to fail closed.

## Automated latency evidence

Measurements below are Debug simulator results on Xcode 26.6 (17F113), iOS 26.5, using the 1,000-item stress fixture. The test warms each operation, records monotonic wall time, reports nearest-rank percentiles, and fails if projection worst-case latency reaches 100 ms or batch-preview latency reaches 150 ms.

| Operation | p50 | p95 | Worst |
| --- | ---: | ---: | ---: |
| Catalog, all items | 16.984 ms | 17.134 ms | 17.186 ms |
| Catalog, filtered | 13.930 ms | 14.105 ms | 14.454 ms |
| Groceries, all needs | 38.928 ms | 39.228 ms | 39.461 ms |
| Groceries, filtered | 35.767 ms | 35.926 ms | 36.088 ms |
| Catalog batch preview, 1,000 items | 20.047 ms | 20.848 ms | 20.848 ms |

The post-remediation persistence suite passed 154 tests with no failures. Three clean loaded UI passes completed in 310.334 seconds with no failures. A separate one-pass check completed in 106.670 seconds. These durations include XCTest queries, taps, typing, waits, app relaunches, and scrolling and are not app-response latency measurements.

## Trace points

The `com.mggarofalo.shopping` points-of-interest log marks Catalog projection, Grocery projection, Catalog grouping, Management batch preview, Persistence command, Core Data save, Catalog add preview, and Catalog add apply intervals. These intervals support Time Profiler, Animation Hitches, and Processor Trace inspection without adding per-row logging.

## Physical-device evidence

Three benchmark passes ran on an iPhone 16 Pro with iOS 27.0 (24A5430a) using the 1,000-item stress fixture. The benchmark operations run off the app's main thread so the measurement loop itself does not stall the UI. All three passes completed without a Hang Detection event.

| Operation | p50 range across runs | Worst across runs |
| --- | ---: | ---: |
| Catalog, all items | 9.013–9.234 ms | 10.288 ms |
| Catalog, filtered | 7.786–7.853 ms | 8.060 ms |
| Groceries, all needs | 20.765–21.066 ms | 21.903 ms |
| Groceries, filtered | 19.487–19.887 ms | 20.517 ms |
| Catalog batch preview, 1,000 items | 11.606–11.614 ms | 16.883 ms |

The signed Shopping 1.2.0 (5) build was installed and verified on the device. A 40 MB Time Profiler trace captured the stress workload and the Shopping points-of-interest intervals.
