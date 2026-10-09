import SwiftUI

/// One scoped join surface; native acceptance has already recorded intent before it appears.
struct HomeInvitationsView: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    let invitationID: UUID
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var isRetrying = false
    @State private var retryError: String?
    @State private var showingDetails = false

    private var invitation: HomeEntrySnapshot.Invitation? {
        bootstrap.homeEntry.invitations.first { $0.id == invitationID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let proposal = replacementProposal {
                    HomeReplacementChoiceView(bootstrap: bootstrap, proposal: proposal).id(proposal.id)
                } else { invitationContents }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bootstrap.replacementInProgress == nil ? "Not Now" : "Close") { if let onClose { onClose() } else { dismiss() } }
                        .accessibilityIdentifier("shopping.invitation.notNow")
                }
            }
        }
        .presentationDetents(replacementProposal == nil ? [.medium, .large] : [.large])
        .interactiveDismissDisabled(bootstrap.replacementInProgress != nil)
        .presentationDragIndicator(.visible)
    }

    private var replacementProposal: HomeReplacementProposal? {
        let candidate = bootstrap.replacementOffer ?? bootstrap.replacementInProgress
        return candidate?.invitationID == invitationID ? candidate : nil
    }

    private var invitationContents: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(systemName: "house")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Color.groceryAccent)
                    .accessibilityHidden(true)
                if let invitation {
                    content(for: invitation)
                } else {
                    Text("Invitation unavailable")
                        .font(.title2.weight(.semibold))
                        .padding(.top, 18)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
        .navigationTitle("Invitation")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Invitation details", isPresented: $showingDetails) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(detailMessage)
        }
    }

    @ViewBuilder
    private func content(for invitation: HomeEntrySnapshot.Invitation) -> some View {
        if let retryError {
            stateTitle("Couldn’t Join")
            Text(retryError).foregroundStyle(.secondary).multilineTextAlignment(.center)
            retryButton
        } else if !bootstrap.homeEntry.hasVerifiedInvitationAccount,
                  bootstrap.homeEntry.joinError != nil {
            stateTitle("Sign In to iCloud")
            Text("Sign in in iPhone Settings, then return here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            retryButton
        } else if bootstrap.homeEntry.importProblems[invitation.id] != nil {
            stateTitle("Couldn’t Load Home")
            Text("Check your connection and try again.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Check Again") { checkAgain() }
                .buttonStyle(.borderedProminent)
                .disabled(isRetrying)
                .padding(.top, 20)
                .accessibilityIdentifier("shopping.invitation.checkAgain")
        } else if bootstrap.homeEntry.joinError != nil {
            stateTitle("Couldn’t Open Home")
            Text("Try again.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            retryButton
        } else {
            switch invitation.state {
            case .queued, .joining:
                stateTitle(progressTitle("Joining", invitation: invitation))
                ProgressView().padding(.top, 20)
            case .loading:
                stateTitle(progressTitle("Loading", invitation: invitation))
                ProgressView().padding(.top, 20)
            case .ready(let graph):
                if invitation.openRequested {
                    stateTitle(progressTitle("Opening", invitation: invitation))
                    ProgressView().padding(.top, 20)
                } else {
                    let name = bootstrap.homeEntry.homes.first { $0.id == graph }?.name ?? "Home"
                    stateTitle("\(name) is ready")
                    Button("Open") { open(invitation.id, graph: graph) }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 20)
                }
            case .failed(let failure):
                stateTitle(failureTitle(failure))
                Text(failureMessage(failure))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 7)
                retryButton
                if case .acceptance = failure {
                    Button("Details") { showingDetails = true }
                        .padding(.top, 7)
                }
            case .dismissed:
                stateTitle("Invite Unavailable")
                Text("Ask for a new invite.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 7)
            }
        }
    }

    private func stateTitle(_ value: String) -> some View {
        Text(value)
            .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.top, 18)
            .accessibilityIdentifier("shopping.invitation.state")
    }

    private func progressTitle(_ action: String, invitation: HomeEntrySnapshot.Invitation) -> String {
        "\(action) \(invitation.displayName ?? "Home")…"
    }

    private var retryButton: some View {
        Button("Retry") { retry() }
            .buttonStyle(.borderedProminent)
            .disabled(isRetrying)
            .padding(.top, 20)
            .accessibilityIdentifier("shopping.invitation.retry")
    }

    private var detailMessage: String {
        guard let invitation else { return "The invitation is no longer available." }
        if case .failed(.acceptance(let message)) = invitation.state { return message }
        return bootstrap.homeEntry.joinError ?? "Try again."
    }

    private func failureTitle(_ failure: HomeInvitationInbox.Failure) -> String {
        switch failure {
        case .accountChanged: "iCloud Account Changed"
        case .interrupted, .acceptance: "Couldn’t Join"
        }
    }

    private func failureMessage(_ failure: HomeInvitationInbox.Failure) -> String {
        switch failure {
        case .accountChanged: "Switch back to continue joining."
        case .interrupted, .acceptance: "Try again."
        }
    }

    private func retry() {
        guard !isRetrying else { return }
        isRetrying = true
        retryError = nil
        Task {
            defer { isRetrying = false }
            do { try await bootstrap.homeEntryCommands.joinInvitation(invitationID) }
            catch { retryError = "Try again." }
        }
    }

    private func checkAgain() {
        guard !isRetrying else { return }
        isRetrying = true
        retryError = nil
        Task {
            defer { isRetrying = false }
            do { try await bootstrap.homeEntryCommands.refreshHomes() }
            catch { retryError = "Try again." }
        }
    }

    private func open(_ id: UUID, graph: HomeGraphIdentity) {
        Task {
            do { try await bootstrap.homeEntryCommands.openInvitation(id, graph: graph) }
            catch { retryError = "Couldn’t open home. Try again." }
        }
    }
}

#Preview {
    let bootstrap = PersistenceBootstrap(preloadedPreviewEnvironment: try! ShoppingPreviewFixtures.make(.populated))
    HomeInvitationsView(bootstrap: bootstrap, invitationID: UUID())
}
