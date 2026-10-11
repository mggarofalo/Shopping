import SwiftUI

/// The existing invitation sheet owns this decision and its one confirmation.
struct HomeReplacementChoiceView: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    let proposal: HomeReplacementProposal
    @State private var confirming: HomeReplacementProposal?
    @State private var error: String?

    private var targetName: String {
        if bootstrap.replacementRecord?.proposal == proposal,
           let graph = bootstrap.replacementRecord?.target?.graph,
           let home = bootstrap.homeEntry.homes.first(where: { $0.id == graph }) { return home.name }
        let invitation = bootstrap.homeEntry.invitations.first { $0.id == proposal.invitationID }
        if case .ready(let graph) = invitation?.state,
           let home = bootstrap.homeEntry.homes.first(where: { $0.id == graph }) { return home.name }
        return invitation?.displayName ?? "invited Home"
    }
    private var sourceTitle: String {
        proposal.source.name == targetName ? "\(proposal.source.name) (On This iPhone)" : proposal.source.name
    }
    private var targetTitle: String {
        proposal.source.name == targetName ? "\(targetName) (Invited Home)" : targetName
    }
    private var isWorking: Bool { bootstrap.replacementInProgress?.id == proposal.id }
    private var progressTitle: String {
        switch bootstrap.replacementRecord?.proposal == proposal ? bootstrap.replacementRecord?.stage : nil {
        case .cleanupPending: "Removing \(proposal.source.name)…"
        case .completed: "Replacement complete"
        default: "Opening \(targetName)…"
        }
    }

    var body: some View {
        List {
            Section("Invited Home") {
                Text(targetName).font(.headline)
                    .accessibilityIdentifier("shopping.replacement.target")
            }
            Section("Your starter Home") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(proposal.source.name).font(.headline)
                    Text("On This iPhone").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("shopping.replacement.source")
            }
            if isWorking {
                Section {
                    ProgressView(progressTitle)
                        .accessibilityIdentifier("shopping.replacement.progress")
                }
            } else {
                Section {
                    Button(role: .destructive) { confirming = proposal } label: {
                        Text("Replace \(proposal.source.name)").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("shopping.replacement.replace")
                    Button { bootstrap.homeEntryCommands.keepBothHomes() } label: {
                        Text("Keep Both Homes").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("shopping.replacement.keepBoth")
                } footer: {
                    Text("Replacing removes your empty \(proposal.source.name). It does not move groceries or carts.")
                }
            }
            if let error { Section { Text(error).foregroundStyle(.secondary) } }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Use \(targetName)?")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Replace “\(sourceTitle)” with “\(targetTitle)”?", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }
        ), presenting: confirming) { captured in
            Button("Cancel", role: .cancel) { confirming = nil }
            Button("Replace Home", role: .destructive) {
                confirming = nil
                Task {
                    do { try await bootstrap.homeEntryCommands.replaceStarter(captured) }
                    catch { self.error = "Couldn’t finish replacement. Review its status in Homes." }
                }
            }
        } message: { _ in
            Text("Removes your empty \(sourceTitle) after \(targetTitle) is ready. This cannot be undone.")
        }
        .onChange(of: bootstrap.replacementOffer?.id) { _, id in
            if id != proposal.id { confirming = nil }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        HomeReplacementChoiceView(bootstrap: PersistenceBootstrap(), proposal: HomeReplacementPreview.proposal)
    }
}

enum HomeReplacementPreview {
    static let proposal = HomeReplacementProposal(id: UUID(),
        source: LocalStarterEvidence(version: 1, creationID: UUID(),
            graph: HomeGraphIdentity(storeIdentifier: "preview", rootURI: "x-coredata://preview/Home/1",
                householdID: UUID(), listID: UUID()), name: "My Home", transactionNumber: 1),
        sourceURL: URL(fileURLWithPath: "/preview/Starter.sqlite"), invitationID: UUID(),
        invitation: HomeInvitationIdentity(containerIdentifier: "iCloud.preview", environment: "Development",
            share: HomeShareIdentity(recordName: "share", zoneName: "zone", zoneOwnerName: "owner")),
        session: ShopperSession(accountBinding: "preview", shopperID: UUID(),
            containerIdentifier: "iCloud.preview", environment: "Development"), navigationIntent: UUID())
}
#endif
