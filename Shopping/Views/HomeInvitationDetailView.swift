import SwiftUI

struct HomeInvitationDetailView: View {
    let route: HomeInvitationRoute
    @ObservedObject var invitations: HomeNamedInvitationsModel
    @ObservedObject var details: HomeDetailsModel
    @State private var editingName = false
    @Environment(\.dismiss) private var dismiss

    private var record: HomeInvitationRecord? {
        switch route {
        case .named(let id): return invitations.records.first { $0.id == id }
        case .legacy(let id): return invitations.records.first { $0.participantIDs.contains(id) }
        }
    }
    private var legacyID: String? { if case .legacy(let id) = route { return id }; return nil }
    private var busy: Bool { invitations.busy || details.busy }
    private var supportsLinks: Bool { if #available(iOS 18.0, *) { return true }; return false }

    var body: some View {
        List {
            if let record {
                namedContent(record)
            } else if let legacyID {
                Section {
                    Text("This invitation hasn’t been named.")
                    Button("Name invitation") { editingName = true }
                        .accessibilityIdentifier("shopping.home.invitation.nameLegacy")
                    if supportsLinks {
                        Button("Share invitation again") { Task { await details.resend(legacyID) } }
                            .disabled(!details.canInvite || invitations.busy)
                    }
                    Button("Cancel invitation", role: .destructive) {
                        Task { await details.prepareRemoval(.removeMember, participantID: legacyID) }
                    }
                    .disabled(!details.canManageMembers || invitations.busy)
                }
            } else {
                Text("This invitation is no longer available.")
            }
            if details.isRefreshing { ProgressView("Checking members…") }
            if let operation = invitations.operation ?? details.operation?.label {
                ProgressView(operation).accessibilityIdentifier("shopping.home.invitation.progress")
            }
            if let error = invitations.error ?? details.error {
                Text(error).foregroundStyle(.red)
                    .accessibilityIdentifier("shopping.home.invitation.error.\(record?.id.uuidString ?? route.id)")
            }
            if let error = invitations.refreshError ?? details.refreshError {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("Check again") { Task { await details.refresh(); await invitations.refresh() } }
                }
            }
        }
        .navigationTitle(record?.name ?? "Invitation")
        .sheet(isPresented: $editingName) {
            HomeInvitationNameView(invitations: invitations, details: details, record: record, participantID: legacyID) { _ in
                editingName = false
            }
        }
        .homeRemovalConfirmation(model: details, invitedName: record?.name)
        .sheet(item: $invitations.delivery) { value in
            HomeInvitationActivityView(delivery: value, onPresented: {}, onFinished: { completed, error in
                Task { await invitations.finishedSharing(value, completed: completed, failure: error) }
            })
        }
        .sheet(item: $details.delivery) { value in
            HomeInvitationActivityView(delivery: value, onPresented: { Task { await details.presented(value) } },
                onFinished: { _, _ in details.delivery = nil })
        }
        .task { await invitations.refresh() }
        .onChange(of: details.snapshot) { _, _ in Task { await invitations.refresh() } }
    }

    @ViewBuilder private func namedContent(_ record: HomeInvitationRecord) -> some View {
        let presentation = HomeInvitationPresentation(record: record, snapshot: details.snapshot)
        Section {
            Text(presentation.status).accessibilityIdentifier("shopping.home.invitation.status.\(record.id)")
            if let member = presentation.acceptedMember {
                LabeledContent("Joined as", value: member.label)
            }
            if let date = record.lastHandoffAt {
                LabeledContent("Last share activity") { Text(date, style: .date) }
                Text("Sharing activity doesn’t confirm delivery or that someone read the invitation.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if record.hasConflictingName || record.hasConflictingParticipants {
                Text("More than one invitation was prepared with this name. Review each link and use distinct names.")
                    .foregroundStyle(.secondary)
            }
            Button("Edit invitation name") { editingName = true }
        }
        if presentation.acceptedMember == nil && !record.isTerminal {
            Section {
                if supportsLinks {
                    if presentation.canShare {
                        Button(record.lastHandoffAt == nil ? "Share invitation" : "Share again", systemImage: "square.and.arrow.up") {
                            Task { await invitations.createOrShare(record, share: true); await details.refresh() }
                        }
                        .disabled(busy)
                        .accessibilityIdentifier("shopping.home.invitation.share.\(record.id)")
                    } else if !presentation.cancelling && !record.hasConflictingParticipants {
                        Button(invitations.needsPreparationRetry ? "Retry sharing preparation" : record.participantIDs.isEmpty ? "Create invitation" : "Check invitation") {
                            Task { await invitations.createOrShare(record, share: false); await details.refresh() }
                        }
                        .disabled(busy)
                        .accessibilityIdentifier("shopping.home.invitation.retry.\(record.id)")
                    }
                } else { Text("Sharing invitation links requires iOS 18 or later.") }
            } footer: {
                Text("Anyone with this link can join. One person per link.")
            }
            if record.hasConflictingParticipants {
                conflictingLinks(record)
            } else if !record.participantIDs.isEmpty && !presentation.cancelling {
                Section {
                    Button("Cancel invitation", role: .destructive) {
                        Task {
                            if let value = await invitations.prepareCancellation(record) { details.removalConfirmation = value }
                        }
                    }
                    .disabled(busy || !details.canManageMembers)
                    .accessibilityIdentifier("shopping.home.invitation.cancel.\(record.id)")
                }
            } else if record.participantIDs.isEmpty {
                Button("Remove draft", role: .destructive) {
                    Task { if await invitations.discard(record) { dismiss() } }
                }
                .disabled(busy)
                .accessibilityIdentifier("shopping.home.invitation.discard.\(record.id)")
            }
        }
    }
    @ViewBuilder private func conflictingLinks(_ record: HomeInvitationRecord) -> some View {
        ForEach(Array(record.participantIDs.sorted().enumerated()), id: \.element) { index, participantID in
            let member = details.snapshot?.members.first { $0.id == participantID }
            let removal = details.snapshot?.removals.first { $0.removal.participantIDs.contains(participantID) }
            Section("Link \(index + 1)") {
                if member?.acceptance == .accepted {
                    Text("Joined as \(member!.label)")
                } else if let removal {
                    Text(removal.absentObservedAt == nil ? "Cancelling invitation…" : "Invitation cancelled")
                } else {
                    Text(member?.acceptance == .pending ? "Ready to share" : "Awaiting confirmation")
                    if supportsLinks && member?.acceptance == .pending {
                        Button("Share this link") { Task { await details.resend(participantID) } }
                            .disabled(busy)
                    }
                    Button("Cancel this link", role: .destructive) {
                        Task {
                            if let value = await invitations.prepareCancellation(record, participantID: participantID) {
                                details.removalConfirmation = value
                            }
                        }
                    }
                    .disabled(busy || !details.canManageMembers)
                }
            }
        }
    }

}

#Preview {
    NavigationStack {
        HomeInvitationDetailView(route: .legacy("preview"),
            invitations: HomeNamedInvitationsModel(scope: HomeInvitationPreview.scope, actions: nil),
            details: HomeDetailsModel(scope: HomeInvitationPreview.scope, actions: HomeInvitationPreview.actions))
    }
}
