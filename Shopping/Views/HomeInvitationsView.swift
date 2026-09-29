import SwiftUI

struct HomeInvitationsView: View {
    @ObservedObject var invitations: HomeInvitationController
    @ObservedObject var bootstrap: PersistenceBootstrap
    @State private var setup: PersistenceBootstrap.InvitationSetupChoice?
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        List {
            if setup != nil || bootstrap.requiresHomeAccountSetup || !invitations.hasVerifiedAccount {
                Section {
                    if let setup {
                        if let name = setup.currentHomeName {
                            Text("Your current home is \(name). Its groceries will stay separate from the invited home.")
                            if setup.canAdopt {
                                Button("Keep \(name) in iCloud") { connect(setup, copyLocal: true) }
                            }
                            Button("Keep \(name) on this device") { connect(setup, copyLocal: false) }
                        } else {
                            Text("Connect to iCloud to load your invited home.")
                            Button("Continue with iCloud") { connect(setup, copyLocal: false) }
                        }
                        Button("Not now", role: .cancel) { self.setup = nil }
                    } else {
                        Text("Connect to iCloud to accept your home invitation. Your existing groceries stay saved.")
                        Button("Connect to iCloud") {
                            perform { setup = try await bootstrap.prepareInvitationSetup() }
                        }
                    }
                }
                .disabled(isWorking)
            }
            if let problem = invitations.problem {
                Section {
                    Text(problem)
                    Button("Check again") { bootstrap.applicationDidEnterForeground(); invitations.checkAgain() }
                }
            }
            ForEach(invitations.entries) { entry in
                Section {
                    switch entry.state {
                    case .queued:
                        Label("Invitation waiting", systemImage: "envelope")
                        Text("Joining will start when your iCloud account and saved groceries are ready.")
                    case .joining:
                        ProgressView("Joining home…")
                    case .loading:
                        ProgressView("Loading groceries…")
                        if let problem = invitations.importProblems[entry.id] { Text(problem) }
                        Text("The invitation was accepted. Your current home stays selected while the shared home loads.")
                        Button("Check again") { bootstrap.applicationDidEnterForeground(); invitations.checkAgain() }
                    case .ready(let graph):
                        if let home = bootstrap.homeCoordinator.homes.first(where: { $0.graph == graph }) {
                            Label(home.name, systemImage: "house")
                            if let current = bootstrap.currentHomeName {
                                Text("Your current home is \(current). Open \(home.name) and keep \(current) separately. Groceries and personal carts stay with their original home.")
                            } else {
                                Text("Open \(home.name). Any other homes and personal carts stay separate.")
                            }
                            Button("Open \(home.name)") {
                                perform { try await bootstrap.activateInvitedHome(entryID: entry.id, graph: graph) }
                            }
                            .accessibilityIdentifier("shopping.invitation.open")
                            Button("Not now", role: .cancel) {
                                perform { try await bootstrap.keepCurrentHome(entryID: entry.id) }
                            }
                            .accessibilityIdentifier("shopping.invitation.notNow")
                        } else {
                            Text("Your invited home is ready. Refresh your homes to open it.")
                            Button("Check again") { perform { try await bootstrap.refreshHomes() } }
                        }
                    case .failed(let failure):
                        Text(failureMessage(failure))
                        Button("Retry invitation") { invitations.retry(entry.id) }
                    case .dismissed:
                        EmptyView()
                    }
                    if case .ready = entry.state { }
                    else if case .failed = entry.state, entry.acceptanceAttempted { }
                    else {
                        if entry.acceptanceAttempted {
                            Text("You can hide this progress. The invitation will reappear when it is ready or needs your attention.")
                        }
                        Button(entry.acceptanceAttempted ? "Hide for now" : "Dismiss invitation", role: .cancel) {
                            invitations.dismiss(entry.id)
                        }
                    }
                }
                .disabled(isWorking)
            }
            if isWorking { ProgressView("Preparing home…") }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Home invitations")
        .task { try? await bootstrap.refreshHomes() }
    }

    private func connect(_ choice: PersistenceBootstrap.InvitationSetupChoice, copyLocal: Bool) {
        perform { try await bootstrap.confirmInvitationSetup(choice, copyLocal: copyLocal) }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        Task { @MainActor in
            defer { isWorking = false }
            do { try await action() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func failureMessage(_ failure: HomeInvitationInbox.Failure) -> String {
        switch failure {
        case .interrupted: return "Joining was interrupted. Retry to check the same invitation."
        case .accountChanged: return "Your iCloud account changed. Return to the original account to retry this invitation."
        case .acceptance(let message): return message
        }
    }
}

#Preview {
    let inbox = try! HomeInvitationInbox(url: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("inbox.json"),
        containerIdentifier: "iCloud.preview", environment: "Development")
    NavigationStack {
        HomeInvitationsView(invitations: HomeInvitationController(inbox: inbox),
            bootstrap: PersistenceBootstrap(preloadedPreviewEnvironment: try! ShoppingPreviewFixtures.make(.populated)))
    }
}
