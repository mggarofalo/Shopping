import SwiftUI

struct HomeSelectionView: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    @ObservedObject var coordinator: ActiveHomeCoordinator
    @State private var error: String?
    @State private var newHomeName = ""
    @State private var createdHome: PersistenceBootstrap.CreatedHome?

    var body: some View {
        List {
            Section {
                ForEach(coordinator.homes) { home in
                    Button {
                        do { try bootstrap.selectHome(home.graph) }
                        catch { self.error = error.localizedDescription }
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
                    .disabled(home.access == .unresolved)
                    .accessibilityLabel(home.name)
                    .accessibilityValue(accessDescription(home.access)
                        + (coordinator.activeScope?.graph == home.graph ? ", Selected" : ""))
                    .accessibilityIdentifier("shopping.home.choice." + home.name)
                }
            } header: { Text("Your homes") } footer: { Text("Groceries and personal carts stay with their original home.") }
            if coordinator.activeScope == nil {
                Section {
                    Text(coordinator.readiness == .selectedHomeUnavailable
                        ? "Your selected home is unavailable. Choose an accessible home or wait for its import to finish."
                        : "Choose a home. Homes still importing will appear when their grocery list is ready.")
                    Button("Check again") { bootstrap.applicationDidEnterForeground() }
                }
            }
            if coordinator.pendingInvitation {
                Text("An invitation is waiting. Your current home stays selected until you choose to join.")
            }
            Section {
                TextField("Home name", text: $newHomeName)
                    .accessibilityIdentifier("shopping.home.name")
                Button("Create home") {
                    let name = newHomeName
                    Task {
                        do {
                            createdHome = try await bootstrap.createHome(name: name)
                            newHomeName = ""
                            error = nil
                        }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(bootstrap.isCreatingHome || newHomeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("shopping.home.create")
                if bootstrap.isCreatingHome { ProgressView("Creating home…") }
            } header: { Text("New home") } footer: {
                Text("You will own the new home. Your existing groceries stay in their current home.")
            }
            if let createdHome, !createdHome.selected {
                Text("Your home was created. Choose it from Your homes when it appears.")
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Homes")
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
