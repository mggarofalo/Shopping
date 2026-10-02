import SwiftUI

/// An invitation that finished after dismissal stays available without moving the shopper.
struct HomeInvitationNotice: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    let invitation: HomeEntrySnapshot.Invitation
    @State private var isOpening = false
    @State private var error: String?

    private var readyHome: (graph: HomeGraphIdentity, name: String)? {
        guard case .ready(let graph) = invitation.state else { return nil }
        let name = bootstrap.homeEntry.homes.first { $0.id == graph }?.name ?? "Home"
        return (graph, name)
    }

    var body: some View {
        if let readyHome {
            Button {
                guard !isOpening else { return }
                isOpening = true
                Task {
                    defer { isOpening = false }
                    do { try await bootstrap.homeEntryCommands.openInvitation(invitation.id, graph: readyHome.graph) }
                    catch { self.error = "Couldn’t open home. Try again." }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "house")
                    Text("\(readyHome.name) is ready")
                    Spacer(minLength: 8)
                    Text("Open")
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 16)
            }
            .disabled(isOpening)
            .background(.regularMaterial)
            .accessibilityIdentifier("shopping.home.invitationReady")
            .alert("Couldn’t open home", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }
}

#Preview {
    let bootstrap = PersistenceBootstrap(preloadedPreviewEnvironment: try! ShoppingPreviewFixtures.make(.populated))
    if let invitation = bootstrap.homeEntry.invitations.first {
        HomeInvitationNotice(bootstrap: bootstrap, invitation: invitation)
    }
}
