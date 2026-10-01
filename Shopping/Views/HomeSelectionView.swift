import SwiftUI

struct HomeSelectionView: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    @ObservedObject var coordinator: ActiveHomeCoordinator
    @State private var error: String?
    @State private var newHomeName = ""
    @State private var isSubmittingHome = false
    @State private var isSelectingHome = false
    @State private var pendingCreation: HomeCreationCommand?
    @State private var createdHome: PersistenceBootstrap.CreatedHome?

    var body: some View {
        List {
            if bootstrap.isShowingRetainedLocalHome {
                Section {
                    Text("This home is saved on this device. Your iCloud homes stay separate.")
                    Button("Return to iCloud homes") {
                        Task {
                            do { try await bootstrap.connectBackToAccount() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
            } else if let name = bootstrap.retainedLocalHomeName {
                Section {
                    Button("Open \(name) on this device") {
                        Task {
                            do { try await bootstrap.openRetainedLocalHome() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                } footer: {
                    Text("This home’s groceries are kept separately on this device.")
                }
            }
            Section {
                ForEach(coordinator.homes) { home in
                    Button {
                        guard !isSelectingHome else { return }
                        isSelectingHome = true
                        Task {
                            defer { isSelectingHome = false }
                            do { try await bootstrap.selectHome(home.graph) }
                            catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(home.name)
                                Text(accessDescription(home.access)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if coordinator.activeScope?.graph == home.graph {
                                Image(systemName: "checkmark").accessibilityLabel("Selected home")
                            }
                        }
                    }
                    .disabled(isSelectingHome || home.access == .unresolved)
                    .accessibilityLabel(home.name)
                    .accessibilityValue(accessDescription(home.access)
                        + (coordinator.activeScope?.graph == home.graph ? ", Selected" : ""))
                    .accessibilityIdentifier("shopping.home.choice." + home.name)
                }
            } header: { Text("Your homes") }
            if coordinator.activeScope == nil {
                Section {
                    Text(coordinator.readiness == .selectedHomeUnavailable
                        ? "Your selected home is unavailable. Choose another home or check again."
                        : "Choose a home, or check again while it loads.")
                    Button("Check again") { bootstrap.applicationDidEnterForeground() }
                }
            }
            if bootstrap.homeLeaveStatuses.contains(where: \.requiresResolution) || bootstrap.homeLeaveStatusError != nil {
                HomeLeaveStatusSection(bootstrap: bootstrap)
            }
            if coordinator.pendingInvitation, let invitations = bootstrap.invitations {
                NavigationLink("Review invitation") {
                    HomeInvitationsView(invitations: invitations, bootstrap: bootstrap)
                }
            }
            Section {
                if let pendingCreation {
                    Text("Finish creating \(pendingCreation.name). Retrying keeps the same home.")
                }
                TextField("Home name", text: $newHomeName)
                    .disabled(pendingCreation != nil)
                    .accessibilityIdentifier("shopping.home.name")
                Button(pendingCreation == nil ? "Create home" : "Resume creating home") {
                    guard !isSubmittingHome else { return }
                    isSubmittingHome = true
                    let resumedCommand = pendingCreation
                    let name = resumedCommand?.name ?? newHomeName
                    Task {
                        defer { isSubmittingHome = false }
                        do {
                            let result = try await bootstrap.createHome(name: name, resuming: resumedCommand)
                            createdHome = result
                            try await bootstrap.acknowledgeHomeCreation(result)
                            pendingCreation = nil
                            newHomeName = ""
                            error = nil
                        }
                        catch {
                            self.error = error.localizedDescription
                            if error is HomeCreationJournal.Failure {
                                pendingCreation = nil
                                newHomeName = ""
                            }
                        }
                    }
                }
                .disabled(isSubmittingHome || bootstrap.isCreatingHome || (pendingCreation == nil
                    && newHomeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .accessibilityIdentifier("shopping.home.create")
                if bootstrap.isCreatingHome { ProgressView("Creating home…") }
            } header: { Text("New home") } footer: {
                Text("Your existing groceries stay in their current home.")
            }
            if let createdHome, !createdHome.selected {
                Text("Your home was created. Choose it from Your homes when it appears.")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Manage homes")
        .task {
            do {
                try await bootstrap.refreshHomes()
                pendingCreation = try await bootstrap.pendingHomeCreation()
            }
            catch { self.error = error.localizedDescription }
        }
    }

    private func accessDescription(_ access: HomeCandidate.Access) -> String {
        switch access {
        case .owner: return "Owner"
        case .contributor: return "Contributor"
        case .restricted: return "Read-only access"
        case .unresolved: return "Checking access"
        }
    }
}

#Preview {
    let bootstrap = PersistenceBootstrap(preloadedPreviewEnvironment: try! ShoppingPreviewFixtures.make(.populated))
    NavigationStack { HomeSelectionView(bootstrap: bootstrap, coordinator: bootstrap.homeCoordinator) }
}
