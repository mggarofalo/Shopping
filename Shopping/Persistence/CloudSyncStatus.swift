import CloudKit
import Foundation

/// Observed engine activity, never a guarantee that all records or devices are synchronized.
struct CloudSyncStatus: Equatable {
    enum Operation: String, Hashable, Sendable { case setup, download, upload }
    enum Source: Equatable, Sendable { case live, history }
    struct Event: Equatable, Sendable {
        /// Always supplied by the native monitor. Nil supports existing synthetic
        /// callers, whose store/operation/start tuple is their legacy identity.
        let identifier: UUID?
        let store: String
        let operation: Operation
        let started: Date
        let ended: Date?
        let failure: Failure?

        init(identifier: UUID? = nil, store: String, operation: Operation,
             started: Date, ended: Date?, failure: Failure?) {
            self.identifier = identifier; self.store = store; self.operation = operation
            self.started = started; self.ended = ended; self.failure = failure
        }
    }
    enum Failure: Equatable, Sendable {
        case network, service, account, quota, permission, configuration, unknown

        var message: String {
            switch self {
            case .network: return "iCloud is unreachable. Check this device’s internet connection; saved data remains available."
            case .service: return "iCloud is temporarily unavailable. Saved changes will retry automatically."
            case .account: return "iCloud requires attention. Check your Apple Account in Settings."
            case .quota: return "iCloud storage is full. Free some iCloud space to resume syncing."
            case .permission: return "iCloud denied access. Check your account and household access."
            case .configuration: return "iCloud could not use this app’s cloud configuration. An app or service update may be needed."
            case .unknown: return "iCloud could not complete syncing. Saved data remains available; try again later."
            }
        }

        static func classify(_ error: Error, depth: Int = 0) -> Failure {
            guard depth < 5 else { return .unknown }
            let value = error as NSError
            if value.domain == CKErrorDomain, let code = CKError.Code(rawValue: value.code) {
                switch code {
                case .networkUnavailable, .networkFailure: return .network
                case .serviceUnavailable, .requestRateLimited, .zoneBusy: return .service
                case .notAuthenticated: return .account
                case .quotaExceeded: return .quota
                case .permissionFailure: return .permission
                case .badContainer, .missingEntitlement, .invalidArguments, .serverRejectedRequest: return .configuration
                default: break
                }
            }
            if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error {
                let result = classify(underlying, depth: depth + 1)
                if result != .unknown { return result }
            }
            if let partial = value.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
                let values = partial.values.map { classify($0, depth: depth + 1) }
                // Stable precedence, independent of dictionary iteration order.
                for failure: Failure in [.configuration, .account, .permission, .quota, .network, .service] {
                    if values.contains(failure) { return failure }
                }
            }
            return .unknown
        }
    }

    struct ChannelSnapshot: Equatable {
        let store: String
        let operation: Operation
        let activeEvents: [Event]
        let latestCompletion: Event?
        let lastSuccess: Date?
        let hasUnfinishedHistory: Bool
        var isWorking: Bool { !activeEvents.isEmpty }
        var failure: Failure? { latestCompletion?.failure }
    }

    struct Snapshot: Equatable {
        let channels: [ChannelSnapshot]
        var isWorking: Bool { channels.contains(where: \.isWorking) }
        var hasFailure: Bool { channels.contains { $0.failure != nil } }
        var hasUnfinishedHistory: Bool { channels.contains(where: \.hasUnfinishedHistory) }
        var lastUpload: Date? { lastSuccess(.upload) }
        var lastDownload: Date? { lastSuccess(.download) }
        private func lastSuccess(_ operation: Operation) -> Date? {
            channels.filter { $0.operation == operation }.compactMap(\.lastSuccess).max()
        }
        var message: String {
            let failed = channels.compactMap(\.latestCompletion).filter { $0.failure != nil }
                .sorted(by: CloudSyncStatus.presentationOrder)
            if let event = failed.first, let failure = event.failure {
                return "iCloud \(event.operation.rawValue) failed. \(failure.message)"
            }
            if isWorking { return "iCloud is working. Changes are saved on this device." }
            if lastUpload != nil || lastDownload != nil { return "Recent iCloud activity completed." }
            if hasUnfinishedHistory {
                return "Previous iCloud activity has no recorded completion. Saved data is available on this device."
            }
            return "Waiting for iCloud activity. Saved data is available on this device."
        }
    }

    private struct Channel: Hashable { let store: String; let operation: Operation }
    private enum EventKey: Hashable { case native(UUID), legacy(Date) }
    private struct Completion: Equatable {
        let event: Event
        let source: Source
    }
    private struct Observations: Equatable {
        var active: [EventKey: Event] = [:]
        var unfinishedHistory: [EventKey: Event] = [:]
        // Keep all distinct events at the newest start date. Equal timestamps
        // cannot establish that one event recovered another event's failure.
        var completed: [EventKey: Completion] = [:]
        var successful: [EventKey: Completion] = [:]
        var lastSuccess: Date? { successful.values.compactMap { $0.event.ended }.max() }
        var latestStart: Date? { completed.values.first?.event.started }
    }
    private var observations: [Channel: Observations] = [:]

    mutating func record(_ event: Event, source: Source = .live) {
        let channel = Channel(store: event.store, operation: event.operation)
        let key = event.identifier.map(EventKey.native) ?? .legacy(event.started)
        var state = observations[channel] ?? Observations()
        if event.ended == nil {
            // A stale start must not resurrect a completed event. Historical
            // unfinished rows establish only missing evidence, never live work.
            guard state.completed[key] == nil,
                  event.started >= (state.latestStart ?? .distantPast) else { return }
            if source == .live {
                state.active[key] = event
                state.unfinishedHistory[key] = nil
            } else if state.active[key] == nil {
                state.unfinishedHistory[key] = event
            }
        } else {
            // Completion affects this event only; overlapping operations may
            // share a channel and even exactly the same start timestamp.
            state.active[key] = nil
            state.unfinishedHistory[key] = nil
            var completion = Completion(event: event, source: source)
            if let existing = state.completed[key] {
                completion = Self.preferredCompletion(existing, completion)
            }
            if let success = state.successful[key] {
                completion = Self.preferredCompletion(success, completion)
            }
            if completion.event.failure == nil, let ended = completion.event.ended {
                if state.lastSuccess.map({ ended > $0 }) ?? true { state.successful = [:] }
                if state.lastSuccess.map({ ended >= $0 }) ?? true { state.successful[key] = completion }
            } else { state.successful[key] = nil }
            if state.latestStart.map({ event.started > $0 }) ?? true {
                state.completed = [key: completion]
            } else if event.started == state.latestStart {
                state.completed[key] = completion
            }
            // Newer completion supplies more recent evidence than an old
            // unfinished history row, without terminating other live events.
            state.unfinishedHistory = state.unfinishedHistory.filter { $0.value.started >= event.started }
        }
        observations[channel] = state
    }

    func snapshot(forStores stores: Set<String>? = nil) -> Snapshot {
        let channels = observations.keys.filter { channel in stores.map { $0.contains(channel.store) } ?? true }
            .sorted { $0.store == $1.store ? $0.operation.rawValue < $1.operation.rawValue : $0.store < $1.store }
            .map { snapshot(forStore: $0.store, operation: $0.operation) }
        return Snapshot(channels: channels)
    }

    func snapshot(forStore store: String, operation: Operation) -> ChannelSnapshot {
        let state = observations[Channel(store: store, operation: operation)] ?? Observations()
        let completion = state.completed.values.map(\.event).sorted {
            if ($0.failure != nil) != ($1.failure != nil) { return $0.failure != nil }
            return Self.presentationOrder($0, $1)
        }.first
        return ChannelSnapshot(store: store, operation: operation,
            activeEvents: state.active.values.sorted(by: Self.presentationOrder), latestCompletion: completion,
            lastSuccess: state.lastSuccess, hasUnfinishedHistory: !state.unfinishedHistory.isEmpty)
    }

    private static func preferredCompletion(_ lhs: Completion, _ rhs: Completion) -> Completion {
        // Hydration can race notifications for the same event. Its older stored
        // representation must never regress a live terminal observation.
        if lhs.source != rhs.source { return lhs.source == .live ? lhs : rhs }
        if (lhs.event.failure != nil) != (rhs.event.failure != nil) { return lhs.event.failure != nil ? lhs : rhs }
        return presentationOrder(lhs.event, rhs.event) ? lhs : rhs
    }

    private static func presentationOrder(_ lhs: Event, _ rhs: Event) -> Bool {
        if lhs.started != rhs.started { return lhs.started > rhs.started }
        if lhs.operation != rhs.operation { return lhs.operation.rawValue < rhs.operation.rawValue }
        if lhs.store != rhs.store { return lhs.store < rhs.store }
        let precedence: [Failure] = [.configuration, .account, .permission, .quota, .network, .service, .unknown]
        let leftFailure = lhs.failure.flatMap { precedence.firstIndex(of: $0) } ?? precedence.count
        let rightFailure = rhs.failure.flatMap { precedence.firstIndex(of: $0) } ?? precedence.count
        if leftFailure != rightFailure { return leftFailure < rightFailure }
        if lhs.ended != rhs.ended { return (lhs.ended ?? .distantPast) > (rhs.ended ?? .distantPast) }
        return (lhs.identifier?.uuidString ?? "") < (rhs.identifier?.uuidString ?? "")
    }

    // Existing Watch consumers retain their account-wide aggregate interface.
    var isWorking: Bool { snapshot().isWorking }
    var hasFailure: Bool { snapshot().hasFailure }
    var lastUpload: Date? { snapshot().lastUpload }
    var lastDownload: Date? { snapshot().lastDownload }
    var message: String { snapshot().message }
}
