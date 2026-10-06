import SwiftUI

struct HomeInvitationNameView: View {
    @ObservedObject var invitations: HomeNamedInvitationsModel
    @ObservedObject var details: HomeDetailsModel
    var record: HomeInvitationRecord?
    var participantID: String?
    let onSaved: (HomeInvitationRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var visible = false
    @FocusState private var focused: Bool

    private var matches: [HomeInvitationRecord] {
        guard record == nil, participantID == nil, !HomeInvitationRecord.normalize(name).isEmpty else { return [] }
        return invitations.records.filter { !$0.isTerminal && $0.normalizedName == HomeInvitationRecord.normalize(name) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { if canSave { save() } }
                        .disabled(invitations.busy)
                        .accessibilityIdentifier("shopping.home.invitation.name")
                } header: { Text("Who are you inviting?") } footer: {
                    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Enter a name to continue.")
                    }
                    Text("Give this invitation a name so you can find it later. This name doesn’t restrict who can use the link.")
                }
                if !matches.isEmpty {
                    Section("Existing invitations") {
                        ForEach(matches) { match in
                            Button { onSaved(match) } label: {
                                VStack(alignment: .leading) {
                                    Text(match.name)
                                    Text("Open existing invitation").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("shopping.home.invitation.existing.\(match.id)")
                        }
                    }
                }
                if let operation = invitations.operation ?? details.operation?.label {
                    ProgressView(operation).accessibilityIdentifier("shopping.home.invitation.progress")
                }
                if let error = invitations.error {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("shopping.home.invitation.nameError")
                }
            }
            .navigationTitle(record == nil && participantID == nil ? "Invite someone" : "Invitation name")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { visible = false; dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(record == nil && participantID == nil ? "Create invitation" : "Save", action: save)
                        .disabled(!canSave || !matches.isEmpty)
                        .accessibilityIdentifier("shopping.home.invitation.create")
                }
            }
            .onDisappear { visible = false }
            .onAppear { visible = true; name = record?.name ?? name; invitations.clearError(); focused = true }
            .retainedHomeNameDraft($name, editor: "invitation-\(record?.id.uuidString ?? participantID ?? "new")")
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !invitations.busy && !details.busy
    }

    private func save() {
        Task {
            if let record {
                if await invitations.rename(record, name: name) { if visible { onSaved(record) } }
            } else if let participantID {
                if let result = await invitations.label(participantID: participantID, name: name) { if visible { onSaved(result) } }
            } else if let result = await invitations.prepare(name: name) { if visible { onSaved(result) } }
        }
    }
}

#Preview {
    let scope = HomeInvitationPreview.scope
    HomeInvitationNameView(invitations: HomeNamedInvitationsModel(scope: scope, actions: nil),
        details: HomeDetailsModel(scope: scope, actions: HomeInvitationPreview.actions), onSaved: { _ in })
}
