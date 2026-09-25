import Foundation

/// Association progress is independent of CloudKit delivery and invitation/import errors.
@MainActor
final class WatchAssociationStatus {
    enum State: Equatable {
        case clear, pending, failed

        var message: String? {
            switch self {
            case .clear: return nil
            case .pending: return "Some household changes are waiting to be shared."
            case .failed: return "Your changes are saved. Household sharing will retry later."
            }
        }
    }

    var onChange: (() -> Void)?
    private(set) var state = State.clear
    private var generation = UUID()
    private var latestRefresh = UUID()
    var message: String? { state.message }

    func projectedMessage(cloudStatus: CloudSyncStatus, cachedAccount: Bool, otherMessage: String?) -> String {
        if cloudStatus.hasFailure { return cloudStatus.message }
        if cachedAccount { return "Using saved data. Changes sync when a connection returns." }
        return otherMessage ?? message ?? cloudStatus.message
    }

    func reset() {
        generation = UUID()
        update(.clear)
    }

    func refresh(_ operation: () async throws -> Int) async {
        let requestedGeneration = generation
        let request = UUID()
        latestRefresh = request
        let next: State
        do { next = try await operation() > 0 ? .pending : .clear }
        catch { next = .failed }
        guard requestedGeneration == generation, latestRefresh == request else { return }
        update(next)
    }

    private func update(_ next: State) {
        guard state != next else { return }
        state = next
        onChange?()
    }
}
