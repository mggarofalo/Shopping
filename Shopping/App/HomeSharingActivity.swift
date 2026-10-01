import Foundation

/// Consumer-facing observations and next steps. Diagnostic accounting stays in HomeSharingStatus.
struct HomeSharingActivity: Equatable {
    struct Notice: Equatable, Identifiable {
        enum ID: String { case account, home, invitation, cloud, savedWork, preparation, leaving, localCheck }
        let id: ID
        let title: String
        let message: String
        var action: HomeSharingStatus.Action? = nil
    }

    let lastSuccess: Date?
    let notices: [Notice]

    init(input: HomeSharingStatus.Input) {
        guard input.account != .localOnly else {
            lastSuccess = nil
            notices = []
            return
        }
        let hasAccount = input.account == .verified || input.account == .cached
        let channels = hasAccount ? [input.ownedStore, input.sharedStore].compactMap { $0 }.flatMap(\.channels) : []
        lastSuccess = channels.compactMap(\.lastSuccess).max()
        var notices: [Notice] = []
        switch input.account {
        case .cached:
            notices.append(.init(id: .account, title: "iCloud unavailable", message: "Check your connection and try again."))
        case .unavailable:
            notices.append(.init(id: .account, title: "Check your iCloud account", message: "Check your Apple Account in Settings.", action: .openSettings))
        case .changed:
            notices.append(.init(id: .account, title: "iCloud account changed", message: "Check status to load this account’s home."))
        case .localOnly, .verified: break
        }
        // A changed or unavailable account must not expose the previous account's home or work.
        guard hasAccount else { self.notices = notices; return }
        switch input.home {
        case .readOnly:
            notices.append(.init(id: .home, title: "Read-only home", message: "Ask the owner for editing access."))
        case .unavailable:
            notices.append(.init(id: .home, title: "Home unavailable", message: "Choose another home or check access.", action: .chooseHome))
        case .unresolved:
            notices.append(.init(id: .home, title: "Home access needs checking", message: "Check status to try again."))
        case .choiceRequired:
            notices.append(.init(id: .home, title: "Choose a home", message: "", action: .chooseHome))
        case .waitingForImport:
            notices.append(.init(id: .home, title: "Loading home", message: "Check again in a moment."))
        case .availableOwner, .availableContributor: break
        }
        switch input.invitation {
        case .ready:
            notices.append(.init(id: .invitation, title: "Invitation ready", message: "", action: .reviewInvitation))
        case .attention:
            notices.append(.init(id: .invitation, title: "Invitation needs attention", message: "", action: .reviewInvitation))
        case .none, .joining, .loading: break
        }
        let failures = channels.compactMap(\.failure)
        let priority: [CloudSyncStatus.Failure] = [.account, .quota, .permission, .configuration, .network, .service, .unknown]
        if let failure = priority.first(where: failures.contains),
           !(input.account == .cached && [.network, .service].contains(failure)),
           !(input.home == .unavailable && failure == .permission) {
            notices.append(Self.cloudNotice(failure))
        }
        if input.localCheckNeedsAttention {
            notices.append(.init(id: .localCheck, title: "Couldn’t check saved changes", message: "Check status to retry."))
        } else if (input.work.retained ?? 0) == 0 {
            if input.work.isIncomplete {
                notices.append(.init(id: .savedWork, title: "Saved changes need checking", message: "Check status to try again."))
            } else if input.work.retained == 0,
                      (input.work.pendingCheckout ?? 0) > 0 || (input.work.pendingUndo ?? 0) > 0 {
                notices.append(.init(id: .savedWork, title: "Saved changes waiting", message: "Check status to retry."))
            }
        }
        if input.associationNeedsAttention {
            notices.append(.init(id: .preparation, title: "Couldn’t prepare sharing", message: "Check status to retry."))
        }
        if input.leavePendingCount > 0 {
            notices.append(.init(id: .leaving, title: "Leaving home needs confirmation", message: "", action: .chooseHome))
        }
        self.notices = notices
    }

    private static func cloudNotice(_ failure: CloudSyncStatus.Failure) -> Notice {
        let message: String
        let action: HomeSharingStatus.Action?
        switch failure {
        case .account:
            message = "Check your Apple Account in Settings."; action = .openSettings
        case .quota:
            message = "Free some iCloud storage to resume sharing."; action = .openSettings
        case .permission:
            message = "Check your access to this home."; action = .chooseHome
        case .configuration:
            message = "Sharing is unavailable. Try again later."; action = nil
        case .network:
            message = "Check your internet connection and try again."; action = nil
        case .service, .unknown:
            message = "Try again later."; action = nil
        }
        return .init(id: .cloud, title: "iCloud needs attention", message: message, action: action)
    }
}
