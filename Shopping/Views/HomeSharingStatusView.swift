import Accessibility
import SwiftUI
import UIKit

private struct ReturnToHomeEnvironmentKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var returnToHome: (() -> Void)? {
        get { self[ReturnToHomeEnvironmentKey.self] }
        set { self[ReturnToHomeEnvironmentKey.self] = newValue }
    }
}

struct HomeSharingStatusView: View {
    @EnvironmentObject private var bootstrap: PersistenceBootstrap
    @Environment(\.openURL) private var openURL
    @Environment(\.returnToHome) private var returnToHome
    @Environment(\.dismiss) private var dismiss
    @State private var announcements = HomeSharingStatusAnnouncements()

    private var status: HomeSharingStatus { bootstrap.homeSharingStatus }

    var body: some View {
        List {
            Section {
                Label(status.summary.title, systemImage: status.summary.symbol)
                    .font(.headline)
                    .accessibilityIdentifier("shopping.sharing.summary")
                Text(status.summary.details).foregroundStyle(.secondary)
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
            ForEach(status.sections) { section in
                Section {
                    Text(section.presentation.details)
                        .accessibilityIdentifier("shopping.sharing.section.\(section.id.rawValue)")
                    if let date = section.lastUpload { observation("Last observed upload", date: date) }
                    if let date = section.lastDownload { observation("Last observed download", date: date) }
                } header: {
                    Label(section.presentation.title, systemImage: section.presentation.symbol)
                }
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
        case .returnToHome:
            Button("Return to home") { dismiss(); returnToHome?() }
                .accessibilityIdentifier("shopping.sharing.returnHome")
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

    private func observation(_ title: String, date: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(date, format: .dateTime.month().day().hour().minute())
        }
        .accessibilityElement(children: .combine)
    }

    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}

#Preview {
    ShoppingPreviewHost(.populated) { NavigationStack { HomeSharingStatusView() } }
}
