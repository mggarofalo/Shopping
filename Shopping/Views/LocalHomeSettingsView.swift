import SwiftUI

struct LocalHomeSettingsView: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    @State private var isConnecting = false
    @State private var connectionError: String?

    private var isRetained: Bool { bootstrap.homeEntry.isShowingRetainedLocalHome }

    var body: some View {
        List {
            Section("Home") {
                LabeledContent("Name", value: bootstrap.homeEntry.currentHomeName ?? "Home")
                LabeledContent("Storage", value: "On This iPhone")
            }
            Section {
                Button(isRetained ? "Open iCloud Homes" : "Use iCloud",
                       systemImage: "icloud.and.arrow.up") {
                    if isRetained { openICloudHomes() }
                    else { bootstrap.homeEntryCommands.useICloudForLocalHome() }
                }
                .disabled(isConnecting)
                .accessibilityIdentifier(isRetained ? "shopping.home.openICloud" : "shopping.home.useICloud")
                if isConnecting { ProgressView() }
            } footer: {
                Text(isRetained ? "Your home stays on this iPhone."
                    : "Copies this home to iCloud. Your local home stays saved.")
            }
            if let connectionError {
                Section { Text(connectionError).foregroundStyle(.red) }
            }
            if let error = bootstrap.homeSetupError {
                Section { Text(error.localizedDescription).foregroundStyle(.red) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Home Settings")
    }

    private func openICloudHomes() {
        guard !isConnecting else { return }
        isConnecting = true
        connectionError = nil
        Task {
            defer { isConnecting = false }
            do { try await bootstrap.homeEntryCommands.connectBackToAccount() }
            catch { connectionError = "Couldn’t open iCloud homes. Try again." }
        }
    }
}

#Preview {
    let bootstrap = PersistenceBootstrap(preloadedPreviewEnvironment: try! ShoppingPreviewFixtures.make(.populated))
    NavigationStack { LocalHomeSettingsView(bootstrap: bootstrap) }
        .environmentObject(bootstrap)
}
