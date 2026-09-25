import CloudKit
import Foundation

/// Observed engine activity, never a guarantee that all records or devices are synchronized.
struct CloudSyncStatus: Equatable {
    enum Operation: String, Hashable { case setup, download, upload }
    struct Event: Equatable {
        let store: String
        let operation: Operation
        let started: Date
        let ended: Date?
        let failure: Failure?
    }
    enum Failure: Equatable {
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

    private struct Channel: Hashable { let store: String; let operation: Operation }
    private var completed: [Channel: Event] = [:]
    private var active: [Channel: Event] = [:]

    mutating func record(_ event: Event) {
        let channel = Channel(store: event.store, operation: event.operation)
        if event.ended == nil {
            guard event.started > (completed[channel]?.started ?? .distantPast),
                  event.started >= (active[channel]?.started ?? .distantPast) else { return }
            active[channel] = event
        } else {
            guard event.started >= (completed[channel]?.started ?? .distantPast) else { return }
            completed[channel] = event
            if let pending = active[channel], pending.started <= event.started { active[channel] = nil }
        }
    }

    var isWorking: Bool { !active.isEmpty }
    var hasFailure: Bool { completed.values.contains { $0.failure != nil } }
    var lastUpload: Date? { lastSuccess(.upload) }
    var lastDownload: Date? { lastSuccess(.download) }
    private func lastSuccess(_ operation: Operation) -> Date? {
        completed.values.filter { $0.operation == operation && $0.failure == nil }.compactMap(\.ended).max()
    }
    var message: String {
        if let failed = completed.values.filter({ $0.failure != nil }).sorted(by: {
            if $0.started != $1.started { return $0.started > $1.started }
            return $0.operation.rawValue < $1.operation.rawValue
        }).first, let failure = failed.failure {
            return "iCloud \(failed.operation.rawValue) failed. \(failure.message)"
        }
        if !active.isEmpty { return "iCloud is working. Changes are saved on this device." }
        if lastUpload != nil || lastDownload != nil {
            return "Recent iCloud activity completed. This does not confirm another device has received your changes."
        }
        return "Waiting for iCloud activity. Saved data is available on this device."
    }
}
