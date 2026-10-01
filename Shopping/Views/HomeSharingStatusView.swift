import Accessibility
import SwiftUI
import UIKit

struct HomeSharingStatusView: View {
    @EnvironmentObject private var bootstrap: PersistenceBootstrap
    @Environment(\.openURL) private var openURL
    @State private var announcements = HomeSharingStatusAnnouncements()

    private var status: HomeSharingStatus { bootstrap.homeSharingStatus }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(status.summary.title, systemImage: status.summary.symbol)
                        .font(.headline)
                        .accessibilityIdentifier("shopping.sharing.summary")
                    Text(status.summary.details).foregroundStyle(.secondary)
                }
            }
            if !status.actions.isEmpty {
                Section("Actions") {
                    ForEach(status.actions, id: \.rawValue) { action in
                        actionView(action)
                    }
                    if bootstrap.isCheckingSharingStatus {
                        ProgressView("Checking status…")
                            .accessibilityIdentifier("shopping.sharing.checking")
                    }
                    if let message = bootstrap.sharingStatusCheckMessage {
                        Text(message).foregroundStyle(.secondary)
                            .accessibilityIdentifier("shopping.sharing.checkResult")
                    }
                }
            }
            Section {
                NavigationLink("Details") { HomeSharingDetailsView() }
                    .accessibilityIdentifier("shopping.sharing.details")
            }
        }
        .navigationTitle("Sharing status")
        .task { await bootstrap.refreshSharingStatus() }
        .onChange(of: status.summary.title, initial: true) { _, title in
            if let message = announcements.observe(title: title) { announce(message) }
        }
        .onChange(of: bootstrap.isCheckingSharingStatus) { wasChecking, checking in
            if wasChecking && !checking, let message = bootstrap.sharingStatusCheckMessage { announce(message) }
        }
    }

    @ViewBuilder
    private func actionView(_ action: HomeSharingStatus.Action) -> some View {
        switch action {
        case .checkStatus:
            Button("Check status") { Task { await bootstrap.checkSharingStatus() } }
                .disabled(bootstrap.isCheckingSharingStatus)
                .accessibilityIdentifier("shopping.sharing.check")
        case .openSettings:
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .accessibilityHint("Opens this app’s settings. Apple Account settings are available from the main Settings screen.")
            .accessibilityIdentifier("shopping.sharing.settings")
        case .chooseHome:
            NavigationLink("Homes") {
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

    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}

#Preview {
    ShoppingPreviewHost(.populated) { NavigationStack { HomeSharingStatusView() } }
}
