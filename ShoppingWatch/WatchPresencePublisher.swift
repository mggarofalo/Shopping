import Foundation

/// Coalesces advisory publication after durable local saves. Failed work stays
/// dirty until another edit or foreground read requests a retry; durable cart
/// history remains the recovery source after this helper's lifetime ends.
@MainActor
final class WatchPresencePublisher {
    typealias Sleep = @MainActor (Duration) async throws -> Void
    typealias Publish = @MainActor (Set<UUID>) async -> Set<UUID>

    private let delay: Duration
    private let sleep: Sleep
    private let publish: Publish
    private var versions: [UUID: UUID] = [:]
    private var generation = UUID()
    private var task: Task<Void, Never>?

    var dirtyNeedIDs: Set<UUID> { Set(versions.keys) }
    var hasScheduledPublication: Bool { task != nil }

    init(delay: Duration = .seconds(2),
         sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
         publish: @escaping Publish) {
        self.delay = delay
        self.sleep = sleep
        self.publish = publish
    }

    deinit { task?.cancel() }

    func markDirty(_ needID: UUID) {
        versions[needID] = UUID()
        retry()
    }

    func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
        versions.removeAll()
    }

    /// The first dirty need starts a fixed window. Later edits do not restart
    /// its deadline, so continuous tapping cannot postpone publication forever.
    func retry() {
        guard task == nil, !versions.isEmpty else { return }
        let generation = generation, delay = delay, sleep = sleep
        task = Task { [weak self] in
            do { try await sleep(delay) }
            catch {
                guard let self, self.generation == generation else { return }
                self.task = nil
                return
            }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            let captured = self.versions
            let published = await self.publish(Set(captured.keys))
            guard !Task.isCancelled, self.generation == generation else { return }
            for id in published where self.versions[id] == captured[id] {
                self.versions.removeValue(forKey: id)
            }
            self.task = nil
            // Only newer edits start a trailing window. Unchanged failed IDs
            // remain dirty without an idle retry loop.
            if self.versions.contains(where: { captured[$0.key] != $0.value }) {
                self.retry()
            }
        }
    }
}
