import Foundation

/// Runs at most one projection read at a time.
///
/// Requests that arrive while a read runs collapse into one follow-up read of the latest
/// request. A finished read is never discarded just because more store changes arrived,
/// so a burst of changes during launch sync cannot keep a screen from showing results.
/// Each read checks for itself that its inputs still match the screen before publishing.
@MainActor
final class CoalescedRefresh {
    private var pending: (@MainActor () async -> Void)?
    private var running = false

    func request(_ read: @escaping @MainActor () async -> Void) {
        pending = read
        guard !running else { return }
        running = true
        #if DEBUG
        Self.runningCount += 1
        #endif
        Task {
            while let next = pending {
                pending = nil
                #if DEBUG
                if let delay = Self.uiTestReadDelay { try? await Task.sleep(for: delay) }
                #endif
                await next()
            }
            running = false
            #if DEBUG
            Self.runningCount -= 1
            #endif
        }
    }

    #if DEBUG
    /// Reads still running on any screen. A read outlives a removed screen and still reads that
    /// screen's context, so hosted tests wait for zero before deleting the store (SHOPPING-275).
    private(set) static var runningCount = 0

    /// Lets UI tests hold every projection read open to observe the loading state.
    private static let uiTestReadDelay: Duration? = ProcessInfo.processInfo
        .environment["SHOPPING_UI_TEST_PROJECTION_DELAY_MS"].flatMap(Int.init).map { .milliseconds($0) }
    #endif
}
