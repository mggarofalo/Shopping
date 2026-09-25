import Foundation

struct WatchSyncStatus: Equatable {
    enum State: Equatable { case waiting, working, recentActivity, attention }
    let state: State
    let details: String

    init(cloud: CloudSyncStatus = CloudSyncStatus(), attentionMessages: [String] = []) {
        let messages = attentionMessages.filter { !$0.isEmpty }
        if cloud.hasFailure || !messages.isEmpty { state = .attention }
        else if cloud.isWorking { state = .working }
        else if cloud.lastUpload != nil || cloud.lastDownload != nil { state = .recentActivity }
        else { state = .waiting }
        var unique: [String] = []
        for message in (cloud.hasFailure ? [cloud.message] + messages : messages + [cloud.message]) {
            if !unique.contains(message) { unique.append(message) }
        }
        details = unique.joined(separator: "\n\n")
    }

    var symbol: String {
        switch state {
        case .waiting: return "icloud"
        case .working: return "arrow.triangle.2.circlepath.icloud"
        case .recentActivity: return "checkmark.icloud"
        case .attention: return "exclamationmark.icloud"
        }
    }

    var title: String {
        switch state {
        case .waiting: return "Waiting for iCloud"
        case .working: return "iCloud working"
        case .recentActivity: return "Recent activity completed"
        case .attention: return "Sync needs attention"
        }
    }
}
