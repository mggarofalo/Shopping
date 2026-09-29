import Foundation

/// A presentation of observations, not a delivery receipt or a command to schedule sync.
struct HomeSharingStatus: Equatable {
    enum Account: Equatable { case localOnly, verified, cached, unavailable, changed }
    enum Home: Equatable {
        case waitingForImport, choiceRequired, availableOwner, availableContributor, readOnly, unavailable, unresolved
    }
    enum Invitation: Equatable { case none, joining, loading, ready, attention }
    enum Action: String, Equatable, CaseIterable {
        case checkStatus, openSettings, returnToHome, chooseHome, reviewInvitation
    }
    enum SectionID: String { case account, home, invitation, ownedStore, sharedStore, savedWork, ownerAssociations, leavingHomes }
    struct Section: Equatable, Identifiable {
        let id: SectionID
        let presentation: SharingStatusPresentation
        var actions: [Action] = []
        var lastUpload: Date? = nil
        var lastDownload: Date? = nil
    }
    struct Work: Equatable {
        var pendingCheckout: Int? = nil
        var pendingUndo: Int? = nil
        /// A subset of pending operations held by local access or incomplete dependency rules.
        var retained: Int? = nil
        var isIncomplete = false
    }
    struct Input {
        var account: Account
        var home: Home
        var invitation: Invitation = .none
        var ownedStore: CloudSyncStatus.Snapshot? = nil
        var sharedStore: CloudSyncStatus.Snapshot? = nil
        var work = Work()
        /// Known owner records awaiting association, not a count of unsent changes.
        var ownerAssociationCount: Int? = nil
        var associationNeedsAttention = false
        var leavePendingCount = 0
    }

    let summary: SharingStatusPresentation
    let sections: [Section]
    let actions: [Action]

    init(input: Input) {
        let account = Self.accountSection(input.account)
        guard input.account != .localOnly else {
            summary = account.presentation
            sections = [account]
            actions = []
            return
        }
        let home = Self.homeSection(input.home)
        let invitation = Self.invitationSection(input.invitation)
        let owned = input.ownedStore.map { Self.engineSection($0, id: .ownedStore,
            title: "Your iCloud data", scope: "Your owned homes and private personal cart data.") }
        let shared = input.sharedStore.map { Self.engineSection($0, id: .sharedStore,
            title: "Homes shared with you", scope: "Participant changes in homes shared with you.") }
        let work = Self.workSection(input.work)
        var sections = [account, home]
        if let invitation { sections.append(invitation) }
        sections += [owned, shared].compactMap { $0 }
        sections.append(work)
        if input.leavePendingCount > 0 {
            sections.append(Section(id: .leavingHomes, presentation: .init(symbol: "house",
                title: "Leaving homes needs confirmation",
                details: "\(input.leavePendingCount) leave requests for this account are not yet confirmed. Open Homes to review them; they may concern a different home or device."), actions: [.chooseHome]))
        }
        if input.associationNeedsAttention || (input.ownerAssociationCount.map { $0 >= 0 } ?? false) {
            let count = input.ownerAssociationCount.flatMap { $0 >= 0 ? $0 : nil }
            let detail = count.map { "\($0) known home updates still need to be prepared for sharing." }
                ?? "The number of home updates awaiting sharing preparation is unknown."
            sections.append(Section(id: .ownerAssociations, presentation: .init(symbol: "link",
                title: "Preparing home sharing",
                details: "\(detail) This is not a count of all unsent changes."
                    + (input.associationNeedsAttention ? " Sharing preparation could not be checked. Check status to try again." : "")),
                actions: [.checkStatus]))
        }
        self.sections = sections
        var actions = sections.flatMap(\.actions)
        let canOpenHome = [.availableOwner, .availableContributor, .readOnly].contains(input.home)
        if canOpenHome && [.verified, .cached].contains(input.account) { actions.append(.returnToHome) }
        self.actions = Action.allCases.filter { actions.contains($0) }

        if input.account == .unavailable || input.account == .changed {
            summary = account.presentation
        } else if [.readOnly, .unavailable, .unresolved].contains(input.home) {
            summary = home.presentation
        } else if let invitation {
            summary = invitation.presentation
        } else if input.account == .cached {
            summary = account.presentation
        } else if input.ownedStore?.hasFailure == true, let owned {
            summary = Self.engineSummary(owned)
        } else if input.sharedStore?.hasFailure == true, let shared {
            summary = Self.engineSummary(shared)
        } else if input.leavePendingCount > 0, let leave = sections.first(where: { $0.id == .leavingHomes }) {
            summary = leave.presentation
        } else if input.associationNeedsAttention, let association = sections.first(where: { $0.id == .ownerAssociations }) {
            summary = association.presentation
        } else if (input.work.retained ?? 0) > 0 || input.work.isIncomplete
                    || (input.work.pendingCheckout ?? 0) > 0 || (input.work.pendingUndo ?? 0) > 0 {
            summary = work.presentation
        } else if [.waitingForImport, .choiceRequired].contains(input.home) {
            summary = home.presentation
        } else if input.ownedStore?.isWorking == true || input.sharedStore?.isWorking == true {
            summary = .init(symbol: "arrow.triangle.2.circlepath.icloud", title: "iCloud activity observed",
                details: "iCloud activity is in progress. Completed saves remain on this device; another device’s receipt is not confirmed.")
        } else if input.ownedStore?.lastUpload != nil || input.ownedStore?.lastDownload != nil
                    || input.sharedStore?.lastUpload != nil || input.sharedStore?.lastDownload != nil {
            summary = .init(symbol: "icloud", title: "Recent iCloud activity",
                details: "A successful iCloud operation was observed. This does not confirm that every change reached every device.")
        } else if input.ownedStore?.hasUnfinishedHistory == true || input.sharedStore?.hasUnfinishedHistory == true {
            summary = .init(symbol: "icloud", title: "Earlier iCloud activity is unconfirmed",
                details: "Earlier activity has no observed completion. It may no longer be running; saved data is retained and delivery is unknown.")
        } else {
            summary = .init(symbol: "icloud", title: "No recent iCloud activity observed",
                details: "Completed saves remain on this device. No activity has been observed for these stores; delivery is unknown.")
        }
    }

    private static func accountSection(_ account: Account) -> Section {
        let presentation: SharingStatusPresentation
        var actions: [Action] = [.checkStatus]
        switch account {
        case .localOnly:
            presentation = .init(symbol: "internaldrive", title: "Saved on this device",
                details: "Completed saves are stored on this device. iCloud setup has not been completed.")
            actions = []
        case .verified:
            presentation = .init(symbol: "person.crop.circle.badge.checkmark", title: "iCloud account available",
                details: "The current account was verified.")
        case .cached:
            presentation = .init(symbol: "internaldrive", title: "Using saved data",
                details: "iCloud is temporarily unavailable. Saved data for this account remains on this device; check status when connected.")
        case .unavailable:
            presentation = .init(symbol: "exclamationmark.icloud", title: "iCloud account needs attention",
                details: "The account could not be verified. Check your Apple Account in Settings. Previously saved data is retained.")
            actions.append(.openSettings)
        case .changed:
            presentation = .init(symbol: "person.crop.circle.badge.exclamationmark", title: "iCloud account changed",
                details: "Choose a home after the current account is ready. Data saved for the previous account is retained separately.")
            actions.append(.openSettings)
        }
        return Section(id: .account, presentation: presentation, actions: actions)
    }

    private static func homeSection(_ home: Home) -> Section {
        let presentation: SharingStatusPresentation
        var actions: [Action] = [.checkStatus]
        switch home {
        case .availableOwner:
            presentation = .init(symbol: "house", title: "Owner home available",
                details: "Your saved home is available.")
        case .availableContributor:
            presentation = .init(symbol: "house", title: "Contributor home available",
                details: "The saved shared home is available. Its access is checked separately from cloud activity.")
        case .readOnly:
            presentation = .init(symbol: "lock", title: "Home is read-only",
                details: "Changes to this home are unavailable. Saved personal cart and recovery history are retained; pending home changes remain held.")
        case .unavailable:
            presentation = .init(symbol: "house.badge.exclamationmark", title: "Home access unavailable",
                details: "This home cannot currently be opened. Saved personal cart and recovery history are retained. Choose another home or check access.")
            actions.append(.chooseHome)
        case .unresolved:
            presentation = .init(symbol: "questionmark.circle", title: "Home access not verified",
                details: "Access or required home data is incomplete. Saved data is retained while access is checked.")
        case .waitingForImport:
            presentation = .init(symbol: "tray.and.arrow.down", title: "Loading home",
                details: "The home is not yet available on this device. You can leave this screen and check again later; iCloud decides when data arrives.")
        case .choiceRequired:
            presentation = .init(symbol: "house", title: "Choose a home",
                details: "Choose the home to use on this device.")
            actions.append(.chooseHome)
        }
        return Section(id: .home, presentation: presentation, actions: actions)
    }

    private static func invitationSection(_ invitation: Invitation) -> Section? {
        let presentation: SharingStatusPresentation
        var actions: [Action] = [.checkStatus]
        switch invitation {
        case .none: return nil
        case .joining:
            presentation = .init(symbol: "person.crop.circle.badge.plus", title: "Joining home",
                details: "The invitation is being checked. You can leave this screen and return to the invitation later.")
        case .loading:
            presentation = .init(symbol: "tray.and.arrow.down", title: "Loading invited home",
                details: "The invitation was accepted; home data is not ready yet. iCloud controls when it arrives. You can return later.")
        case .ready:
            presentation = .init(symbol: "house", title: "Invited home is ready to open",
                details: "Review the invitation and choose whether to open this home. Your current home is not changed automatically.")
            actions.append(.reviewInvitation)
        case .attention:
            presentation = .init(symbol: "exclamationmark.bubble", title: "Invitation needs attention",
                details: "Review the invitation to retry or return to your current home. Saved data and drafts are retained.")
            actions.append(.reviewInvitation)
        }
        return Section(id: .invitation, presentation: presentation, actions: actions)
    }

    private static func engineSection(_ snapshot: CloudSyncStatus.Snapshot, id: SectionID,
                                      title: String, scope: String) -> Section {
        let detail: String
        let symbol: String
        var actions: [Action] = [.checkStatus]
        let failures = snapshot.channels.compactMap(\.failure)
        if snapshot.hasFailure {
            symbol = "exclamationmark.icloud"
            let explanations = snapshot.channels.compactMap { channel -> String? in
                guard let failure = channel.failure else { return nil }
                return "iCloud \(channel.operation.rawValue) failed. \(failure.message)"
            }
            detail = Array(Set(explanations)).sorted().joined(separator: " ")
            if failures.contains(.account) || failures.contains(.quota) { actions.append(.openSettings) }
        } else if snapshot.isWorking {
            symbol = "arrow.triangle.2.circlepath.icloud"
            let operations = Set(snapshot.channels.filter(\.isWorking).map(\.operation))
            if operations.contains(.upload) && operations.contains(.download) {
                detail = "Sending and receiving activity observed. Another device’s receipt is not confirmed."
            } else if operations.contains(.upload) {
                detail = "Sending activity observed. Another device’s receipt is not confirmed."
            } else if operations.contains(.download) {
                detail = "Receiving activity observed. This does not confirm every change has arrived."
            } else {
                detail = "iCloud setup activity observed. No upload or download is confirmed by setup."
            }
        } else {
            symbol = "icloud"
            if snapshot.lastUpload != nil || snapshot.lastDownload != nil {
                detail = "Successful activity was observed. It does not confirm all changes or another device’s receipt."
            } else if snapshot.hasUnfinishedHistory {
                detail = "Earlier activity has no observed completion. It may no longer be running; current delivery is unknown."
            } else {
                detail = "No upload or download has been observed. Delivery is unknown."
            }
        }
        return Section(id: id, presentation: .init(symbol: symbol, title: title, details: "\(scope) \(detail)"),
            actions: actions, lastUpload: snapshot.lastUpload, lastDownload: snapshot.lastDownload)
    }

    private static func engineSummary(_ section: Section) -> SharingStatusPresentation {
        .init(symbol: section.presentation.symbol, title: "\(section.presentation.title) needs attention",
              details: section.presentation.details)
    }

    private static func workSection(_ work: Work) -> Section {
        var details = ["Completed saves are stored on this device."]
        let checkout = work.pendingCheckout.flatMap { $0 >= 0 ? $0 : nil }
        let undo = work.pendingUndo.flatMap { $0 >= 0 ? $0 : nil }
        if let checkout, let undo {
            details.append("\(checkout) saved checkout operations and \(undo) saved undo operations are waiting for the app to finish processing.")
            details.append("These counts do not measure CloudKit delivery or other devices.")
        } else {
            details.append("The number of pending checkout and undo operations is not yet known.")
        }
        if let retained = work.retained, retained > 0 {
            details.append("\(retained) of the pending operations are held by access or incomplete recovery information; they are not additional changes.")
        }
        if work.isIncomplete {
            details.append("Some recovery information has not arrived or could not be verified; the counts may be incomplete.")
        }
        return Section(id: .savedWork, presentation: .init(symbol: "internaldrive",
            title: (work.retained ?? 0) > 0 ? "Saved home changes are held"
                : ((checkout ?? 0) > 0 || (undo ?? 0) > 0 ? "Saved changes awaiting processing" : "Saved work on this device"),
            details: details.joined(separator: " ")), actions: [.checkStatus])
    }
}
