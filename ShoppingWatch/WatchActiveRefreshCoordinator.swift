import Foundation

/// A bounded local-store fallback while the grocery list is visible. CloudKit owns
/// network delivery; this only rereads data that has already reached Core Data.
struct WatchActiveRefreshCoordinator {
    let interval: Duration

    init(interval: Duration = .seconds(60)) {
        self.interval = interval
    }

    func run(refresh: @escaping @MainActor () async -> Void) async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: interval) }
            catch { return }
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }
}
