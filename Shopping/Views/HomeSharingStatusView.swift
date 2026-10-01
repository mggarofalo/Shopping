import Accessibility
import SwiftUI
import UIKit

struct HomeSharingStatusView: View {
    @EnvironmentObject private var bootstrap: PersistenceBootstrap
    @Environment(\.openURL) private var openURL
    @State private var announcements = HomeSharingStatusAnnouncements()

    private var activity: HomeSharingActivity { bootstrap.homeSharingStatus.activity }
    private var notices: [HomeSharingActivity.Notice] {
        activity.notices.filter { $0.id != .localCheck || bootstrap.sharingStatusCheckProblem == nil }
    }

    var body: some View {
        List {
            Section("Recent activity") {
                if let date = activity.lastSuccess {
                    Text(date, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                        .accessibilityLabel("Last successful iCloud activity")
                        .accessibilityValue(date.formatted(date: .abbreviated, time: .shortened))
                        .accessibilityIdentifier("shopping.sharing.lastActivity")
                }
                checkStatusButton
                if let problem = bootstrap.sharingStatusCheckProblem {
                    Text(problem).foregroundStyle(.secondary)
                        .accessibilityIdentifier("shopping.sharing.checkResult")
                }
            }
            ForEach(notices) { notice in
                Section {
                    Text(notice.title).font(.headline)
                    if !notice.message.isEmpty { Text(notice.message).foregroundStyle(.secondary) }
                    if let action = notice.action { actionView(action) }
                }
                .accessibilityIdentifier("shopping.sharing.notice.\(notice.id.rawValue)")
            }
        }
        .navigationTitle("Sharing status")
        .task { await bootstrap.refreshSharingStatus() }
        .onChange(of: notices, initial: true) { _, notices in
            let titles = notices.map(\.title).joined(separator: ". ")
            if let message = announcements.observe(title: titles), !message.isEmpty { announce(message) }
        }
        .onChange(of: bootstrap.isCheckingSharingStatus) { wasChecking, checking in
            if wasChecking && !checking, let problem = bootstrap.sharingStatusCheckProblem { announce(problem) }
        }
    }

    @ViewBuilder
    private func actionView(_ action: HomeSharingStatus.Action) -> some View {
        switch action {
        case .checkStatus:
            checkStatusButton
        case .openSettings:
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .accessibilityHint("Opens this app’s settings. Apple Account settings are available from the main Settings screen.")
            .accessibilityIdentifier("shopping.sharing.settings")
        case .chooseHome:
            NavigationLink("Manage homes") {
                HomeSelectionView(bootstrap: bootstrap, coordinator: bootstrap.homeCoordinator)
            }
            .accessibilityIdentifier("shopping.sharing.homes")
        case .reviewInvitation:
            if let invitations = bootstrap.invitations {
                NavigationLink("Review invitation") {
                    HomeInvitationsView(invitations: invitations, bootstrap: bootstrap)
                }
                .accessibilityIdentifier("shopping.sharing.invitation")
            }
        }
    }

    private var checkStatusButton: some View {
        HomeSharingCheckButton(isChecking: bootstrap.isCheckingSharingStatus) {
            Task { await bootstrap.checkSharingStatus() }
        }
    }

    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}

#Preview {
    ShoppingPreviewHost(.populated) { NavigationStack { HomeSharingStatusView() } }
}
