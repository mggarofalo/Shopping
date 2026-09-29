import SwiftUI

struct HomeInvitationsView: View {
    @ObservedObject var invitations: HomeInvitationController
    @ObservedObject var bootstrap: PersistenceBootstrap

    var body: some View {
        List {
            if !invitations.hasVerifiedAccount {
                Section {
                    Text("Connect to iCloud to accept your home invitation. Your existing groceries stay saved.")
                    Button("Connect to iCloud") { bootstrap.activatePersonalCarts(importLegacy: false) }
                }
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
                    case .ready:
                        Label("Home is ready", systemImage: "house")
                        Text("Your current home and personal cart have been kept. Choose the shared home when you are ready.")
                        NavigationLink("Choose a home") {
                            HomeSelectionView(bootstrap: bootstrap, coordinator: bootstrap.homeCoordinator)
                        }
                    case .failed(let failure):
                        Text(failureMessage(failure))
                        Button("Retry invitation") { invitations.retry(entry.id) }
                    case .dismissed:
                        EmptyView()
                    }
                    Button("Dismiss invitation", role: .cancel) { invitations.dismiss(entry.id) }
                }
            }
        }
        .navigationTitle("Home invitations")
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
