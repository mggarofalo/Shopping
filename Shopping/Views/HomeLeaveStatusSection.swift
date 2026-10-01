import SwiftUI

/// Account-private leave evidence stays reachable after the shared root is gone.
struct HomeLeaveStatusSection: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    @State private var actionError: String?

    var body: some View {
        Section {
            ForEach(bootstrap.homeLeaveStatuses.filter(\.requiresResolution)) { status in
                VStack(alignment: .leading, spacing: 6) {
                    Text(status.command.homeName).font(.headline)
                    Text("Leaving this home is not yet confirmed")
                        .accessibilityIdentifier("shopping.home.leaveStatus." + status.id.uuidString)
                    if bootstrap.canResumeHomeLeave(status) {
                        Button("Finish leaving") {
                            Task {
                                do { try await bootstrap.resumeHomeLeave(status.command); actionError = nil }
                                catch { actionError = "Leaving could not be finished. Your personal cart and history remain saved. Check again when you are connected." }
                            }
                        }
                        .disabled(bootstrap.homeLeaveResumingID != nil)
                        .accessibilityIdentifier("shopping.home.resumeLeave." + status.id.uuidString)
                    } else if !status.submitted && !status.completed {
                        Text(bootstrap.homeLeaveIsOnThisDevice(status.command)
                             ? "Connect to iCloud to finish leaving on this device."
                             : "Finish the confirmed leave on the device where you started it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .contain)
            }
            if bootstrap.homeLeaveStatuses.contains(where: \.requiresResolution) || bootstrap.homeLeaveStatusError != nil {
                Button("Check leave status again") {
                    Task { await bootstrap.refreshHomeLeaveStatuses() }
                }
                .disabled(bootstrap.isCheckingHomeLeaves)
                .accessibilityIdentifier("shopping.home.checkLeaveStatus")
            }
            if bootstrap.isCheckingHomeLeaves {
                ProgressView("Checking leave status…")
                    .accessibilityIdentifier("shopping.home.checkingLeaveStatus")
            }
            if let message = actionError ?? bootstrap.homeLeaveStatusError {
                Text(message).foregroundStyle(.red).accessibilityIdentifier("shopping.home.leaveError")
            }
        } header: { Text("Leaving homes") }
    }
}

#Preview {
    NavigationStack {
        List {
            HomeLeaveStatusSection(bootstrap: PersistenceBootstrap(
                preloadedPreviewEnvironment: try! ShoppingPreviewFixtures.make(.populated)))
        }
    }
}
