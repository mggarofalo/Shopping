# UI responsiveness contract

Read this before adding a screen, persistence query, CloudKit observer, or sync indicator. The iPhone and Watch share Core Data code, but each app has its own main actor and launch path.

## Targets

- Opening either app and the first list scroll should have **no app-caused main-thread hang of 250 ms or more** in a device Animation Hitches trace. Treat shorter, repeated 100 ms delays as work to investigate too. These are targets, not a claim that the current TestFlight build meets them.
- If the persistence writer is occupied for two seconds, a screen refresh must return control to the main actor promptly. The iPhone presentation regression asserts under 250 ms; the Watch load regression asserts under one second. The Watch threshold is a test guard, not the desired frame time.
- A burst of ordinary CloudKit event notifications should not cause a burst of SwiftUI updates or full grocery reloads. The monitor test sends 200 events and expects one delayed status publication after its 750 ms coalescing interval. Failures should publish immediately.
- Loading, decoding, import recovery, and account activation must preserve correct data and account isolation. Faster UI never justifies dropping a pending command, inventing an unrestricted purchase rule, or publishing a snapshot for an old account.

## Implementation rules

`async` does not imply background execution. A `Task {}` started in a `@MainActor` view model inherits the main actor until it calls work isolated elsewhere. Avoid synchronous `performAndWait`, persistent-store opening, file I/O, JSON decoding, and CloudKit history replay on that actor. Keep UI state and SwiftUI publication there.

Run Core Data work on its background context or serial writer. Pass identifiers and immutable `Sendable` values across actor boundaries; never pass live `NSManagedObject` instances to a detached task. If a service must cross the boundary, verify that its methods confine all managed-object access to the correct context. The iPhone `PersonalCartService` uses its writer; the Watch projection reads on a background context. Do not add `@unchecked Sendable` merely to silence a compiler warning.

For launch or refresh work, capture the account/session and a generation before leaving the main actor. Check them again before publishing the result. Coalesce repeated requests so one slow writer does not queue many redundant full reads. Keep status-only notifications separate from grocery projections. An icon can update from a small sync-status value without reloading every row. Avoid both an initial `.task` reload and an immediate scene-active reload for the same launch.

Commands that change authoritative state must keep the existing writer serialization, causal checkout and recovery rules. An optimistic UI update or a background task cannot substitute for the durable command result. Handle errors on the main actor after background work returns; do not silently convert failed reads into an empty household.

## Verification when changing these paths

1. Run `ShoppingFast` using the command in [AGENTS.md](../AGENTS.md). Keep the cart presentation blocked-writer test, Watch blocked-writer test, and CloudKit event burst test in their normal plans. Run the focused UI workflow for the screen you changed.
2. For launch or sync changes, capture a device Animation Hitches trace while opening the app and scrolling immediately. Exercise the exact action that caused the report, such as an appearance switch. Inspect Shopping's main thread during each hang; a toast alone does not identify the cause. Record OS, device, build, commit, actions, trace duration, and the largest hangs. Compare before and after under the same conditions.
3. Use Time Profiler or signposts to locate remaining work. Watch signposts are `Watch store bootstrap` and `Watch snapshot read`. TestFlight builds can lack `get-task-allow`, preventing process attach; an all-processes Animation Hitches trace can still locate main-thread stalls. Do not replace a person's installed TestFlight app just to obtain a debug trace.
4. Treat a simulator or unit test as proof of the behavior it actually exercises. It cannot prove CloudKit import timing or first-scroll performance on a physical Watch. Record unavailable device proof explicitly and repeat it when the device is ready.

## Investigation baseline and current evidence

On September 27, 2026, a physical iPhone 16 Pro running the installed TestFlight 1.2.0 (17) app showed launch hangs of about 299, 632, 381, and 342 ms in a 21.6-second all-processes Animation Hitches trace. Main-thread samples included Core Data SQL fetch and JSON decoding. The TestFlight binary had no attach permission or matching local symbols, so those samples do not identify an exact application method.

SHOPPING-147 moved persistent-store preparation, account activation, pending cart recovery, and cart snapshot reads away from the iPhone main actor. Its blocked-writer presentation test and the 252-test Fast suite passed locally. SHOPPING-148 moved Watch store setup and snapshot reads away from its main actor, suppressed duplicate launch reloads, and stopped status-only changes from reloading groceries; its focused service, session, and scrolling checks passed on simulator. The physical Watch was paired but Developer Mode was off, so a real Watch first-scroll trace remains outstanding. These checks validate the code paths and actor responsiveness; a post-change physical CloudKit trace is still needed to measure the end-to-end target.
