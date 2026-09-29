import SwiftUI

struct HomeInvitationNotice: View {
    @ObservedObject var invitations: HomeInvitationController
    @ObservedObject var bootstrap: PersistenceBootstrap
    @State private var showingInvitations = false

    var body: some View {
        if invitations.isVisible {
            Button { showingInvitations = true } label: {
                Label("Home invitation", systemImage: "envelope.badge")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .background(.regularMaterial)
            .accessibilityIdentifier("shopping.home.invitation")
            .sheet(isPresented: $showingInvitations) {
                NavigationStack {
                    HomeInvitationsView(invitations: invitations, bootstrap: bootstrap)
                        .toolbar { ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingInvitations = false }
                        } }
                }
            }
        }
    }
}

#Preview {
    let inbox = try! HomeInvitationInbox(url: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("inbox.json"),
        containerIdentifier: "iCloud.preview", environment: "Development")
    HomeInvitationNotice(invitations: HomeInvitationController(inbox: inbox),
        bootstrap: PersistenceBootstrap(preloadedPreviewEnvironment: try! ShoppingPreviewFixtures.make(.populated)))
}
