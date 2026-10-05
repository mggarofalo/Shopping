import SwiftUI

struct HomeDetailsView: View {
    @StateObject private var model: HomeDetailsModel
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var bootstrap: PersistenceBootstrap
    @State private var showingInviteRequirement = false
    @State private var showingNameEditor = false
    @State private var name = ""
    let initialName: String

    init(scope: ActiveHomeScope, name: String, actions: HomeDetailsActions) {
        initialName = name
        _model = StateObject(wrappedValue: HomeDetailsModel(scope: scope, actions: actions))
    }

    private var homeName: String { model.snapshot?.homeName ?? initialName }
    private var cloudNeedsAttention: Bool {
        bootstrap.homeSharingStatus.activity.notices.contains { $0.id != .invitation }
    }
    private var cloudIsWorking: Bool {
        model.busy || bootstrap.isCheckingSharingStatus || bootstrap.cloudStatus.isWorking
    }
    private var supportsLinks: Bool { if #available(iOS 18.0, *) { true } else { false } }

    var body: some View {
        List {
            Section("Home") {
                if model.snapshot?.canEditName == true {
                    Button {
                        name = homeName
                        showingNameEditor = true
                    } label: {
                        LabeledContent("Name", value: homeName)
                    }
                    .disabled(!model.canRename)
                    .accessibilityIdentifier("shopping.home.rename")
                } else {
                    LabeledContent("Name", value: homeName)
                }
            }
            Section {
                if let snapshot = model.snapshot {
                    if snapshot.source == .localUnshared {
                        HomeMemberRow(member: HomeMember(id: "local-owner", name: nil, role: .owner,
                            acceptance: .accepted, isCurrentUser: true, canResend: false)) { EmptyView() }
                    }
                    ForEach(snapshot.members) { member in
                        HomeMemberRow(member: member, hasActions: hasActions(member, in: snapshot)) {
                            memberActions(member, in: snapshot)
                        }
                    }
                    if !model.isCurrent && !model.busy && !snapshot.removals.contains(where: { $0.absentObservedAt == nil }) {
                        Button("Check members again") { Task { await model.refresh() } }
                    }
                }
                if let pending = model.pending,
                   model.snapshot?.members.contains(where: { $0.id == pending.participantID }) != true {
                    pendingInvitationRow(participantID: pending.participantID)
                } else if model.needsPreparationRetry && model.pending == nil {
                    pendingInvitationRow(participantID: "preparing")
                }
            } header: {
                Text("Members").accessibilityIdentifier("shopping.home.membersHeading")
            }
            if let snapshot = model.snapshot {
                if snapshot.canInvite {
                    Section {
                        Button("Invite", systemImage: "person.badge.plus") { invite() }
                            .disabled(!model.canInvite || model.pending != nil || model.needsPreparationRetry)
                            .accessibilityIdentifier("shopping.home.invite")
                    } footer: {
                        Text("Anyone with this link can join. One person per link.")
                    }
                }
                if snapshot.access == .owner && snapshot.source == .server {
                    let pendingRemovals = snapshot.removals.filter { $0.absentObservedAt == nil }
                    if !pendingRemovals.isEmpty {
                        Section {
                            Text("Sharing changes pending")
                            if pendingRemovals.contains(where: \.requiresRetry) {
                                Button("Retry recorded removals") { Task { await model.retryRemovals() } }
                                    .disabled(!model.canManageMembers)
                                    .accessibilityIdentifier("shopping.home.retryRemovals")
                            } else {
                                Button("Check members again") { Task { await model.refresh() } }
                                    .disabled(model.busy)
                            }
                        }
                    }
                }
                if snapshot.access != .owner && snapshot.source == .server {
                    Section {
                        Button("Leave Home", role: .destructive) {
                            Task { await model.prepareLeave() }
                        }
                        .disabled(!model.canLeave)
                        .accessibilityIdentifier("shopping.home.leave")
                    }
                }
                if snapshot.access == .owner && model.hasDeletionAction {
                    Section {
                        Button("Delete Home", role: .destructive) {
                            Task { await model.prepareDeletion() }
                        }
                        .disabled(!model.canDelete)
                        .accessibilityIdentifier("shopping.home.delete")
                    }
                }
            }
            if let status = model.leaveStatus, !status.completed {
                Text("Leaving home is still being confirmed.")
                    .accessibilityIdentifier("shopping.home.leaveStatus")
            }
            if let status = model.deletionStatus, !status.completed {
                Section {
                    Text(status.submitted ? "Deleting home…" : "Deletion needs attention.")
                        .accessibilityIdentifier("shopping.home.deletionStatus")
                    Button("Check Deletion") { Task { await model.retryDeletion() } }
                        .disabled(model.busy)
                        .accessibilityIdentifier("shopping.home.checkDeletion")
                }
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("shopping.home.error")
                if model.snapshot == nil {
                    Button("Check members again") { Task { await model.refresh() } }.disabled(model.busy)
                }
            }
        }
        .navigationTitle("Home Settings")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    HomeSharingStatusView()
                } label: {
                    HomeCloudSymbol(isWorking: cloudIsWorking, needsAttention: cloudNeedsAttention)
                }
                .accessibilityLabel("Sharing status")
                .accessibilityValue(cloudNeedsAttention ? "Needs attention" : model.busy ? "Checking home" : cloudIsWorking ? "Syncing" : "")
                .accessibilityIdentifier("shopping.home.sharingStatus")
            }
        }
        .refreshable { await model.refresh() }
        .task { model.activate(); await model.refresh() }
        .onDisappear { model.retire() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
        .onChange(of: bootstrap.cloudStatus) { _, _ in Task { await model.refresh() } }
        .alert("Inviting requires iOS 18 or later.", isPresented: $showingInviteRequirement) {
            Button("OK", role: .cancel) {}
        }
        .sheet(item: $model.delivery, onDismiss: { Task { await model.refresh() } }) { delivery in
            HomeInvitationActivityView(delivery: delivery,
                onPresented: { Task { await model.presented(delivery) } },
                onFinished: { model.delivery = nil })
        }
        .alert(removalPrompt?.title ?? "", isPresented: Binding(
            get: { model.removalConfirmation != nil },
            // Keep the prepared action until the confirmation button consumes it.
            set: { _ in }
        )) {
            if let confirmation = model.removalConfirmation, let prompt = removalPrompt {
                Button(prompt.action, role: .destructive) { Task { await model.confirmRemoval(confirmation) } }
                    .disabled(!model.canManageMembers)
                    .accessibilityIdentifier("shopping.home.confirmRemoval")
            }
            Button("Cancel", role: .cancel) { model.removalConfirmation = nil }
                .accessibilityIdentifier("shopping.home.cancelRemoval")
        } message: {
            if let message = removalPrompt?.message { Text(message) }
        }
        .alert("Leave “\(model.leaveConfirmation?.homeName ?? homeName)”?", isPresented: Binding(
            get: { model.leaveConfirmation != nil },
            // The confirm task consumes the captured command before suspending.
            // Automatic alert dismissal must not clear it first.
            set: { _ in }
        )) {
            if let command = model.leaveConfirmation {
                Button("Leave Home", role: .destructive) { Task { await model.confirmLeave(command) } }
                    .disabled(!model.canLeave)
                    .accessibilityIdentifier("shopping.home.confirmLeave")
            }
            Button("Cancel", role: .cancel) { model.leaveConfirmation = nil }
                .accessibilityIdentifier("shopping.home.cancelLeave")
        } message: {
            Text("You’ll need another invite to rejoin.")
        }
        .alert("Delete “\(model.deletionConfirmation?.homeName ?? homeName)”?", isPresented: Binding(
            get: { model.deletionConfirmation != nil },
            // The prepared command stays captured until confirmation consumes it.
            set: { _ in }
        )) {
            if let command = model.deletionConfirmation {
                Button("Delete Home", role: .destructive) { Task { await model.confirmDeletion(command) } }
                    .disabled(!model.canDelete)
                    .accessibilityIdentifier("shopping.home.confirmDelete")
            }
            Button("Cancel", role: .cancel) { model.deletionConfirmation = nil }
                .accessibilityIdentifier("shopping.home.cancelDelete")
        } message: {
            Text("Deletes its list, catalog, and settings for everyone. This can’t be undone.")
        }
        .sheet(isPresented: $showingNameEditor) {
            VStack(spacing: 0) {
                ManagementNameEditor(title: "Rename home", name: $name, fieldTitle: "Home name",
                    fieldIdentifier: "shopping.home.nameEditor", saveLabel: "Save home name",
                    initiallyFocused: true, unavailableMessage: "This home is not currently writable. Your draft is retained.",
                    available: model.isCurrent && model.snapshot?.canEditName == true, busy: model.busy,
                    onSave: { Task { if await model.rename(name) { showingNameEditor = false } } },
                    onCancel: { showingNameEditor = false }, draftIdentity: "home-name")
                if let error = model.error { Text(error).foregroundStyle(.red).padding() }
            }
        }
    }

    private func invite() {
        guard supportsLinks else {
            showingInviteRequirement = true
            return
        }
        Task { await model.invite() }
    }

    private func hasActions(_ member: HomeMember, in snapshot: HomeMembershipSnapshot) -> Bool {
        snapshot.access == .owner && !member.isCurrentUser && member.role != .owner
    }

    @ViewBuilder
    private func memberActions(_ member: HomeMember, in snapshot: HomeMembershipSnapshot) -> some View {
        if model.pending?.participantID == member.id {
            continueInvitationButton
            cancelInvitationButton
        } else {
            if snapshot.canResend(member) && supportsLinks {
                Button("Share invitation again") { Task { await model.resend(member.id) } }
                    .disabled(!model.canInvite)
                    .accessibilityIdentifier("shopping.home.resend.\(member.id)")
            }
            if hasActions(member, in: snapshot) {
                Button(member.acceptance == .pending ? "Cancel invitation" : "Remove contributor", role: .destructive) {
                    Task { await model.prepareRemoval(.removeMember, participantID: member.id) }
                }
                .disabled(!model.canManageMembers)
                .accessibilityIdentifier("shopping.home.remove.\(member.id)")
            }
        }
    }

    private func pendingInvitationRow(participantID: String) -> some View {
        HStack {
            Text(model.needsPreparationRetry ? "Sharing preparation interrupted" : "Invitation pending")
                .accessibilityIdentifier("shopping.home.pendingInvitation")
            Spacer()
            Menu {
                continueInvitationButton
                if model.pending != nil { cancelInvitationButton }
            } label: {
                Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Invitation actions")
            .accessibilityIdentifier("shopping.home.memberActions.\(participantID)")
        }
    }

    private var continueInvitationButton: some View {
        Button(!model.isCurrent ? "Check members again" : model.needsPreparationRetry ? "Retry sharing preparation" : "Continue invitation") {
            guard supportsLinks else {
                showingInviteRequirement = true
                return
            }
            Task {
                if model.isCurrent { await model.invite(retryPreparation: model.needsPreparationRetry) }
                else { await model.refresh() }
            }
        }
        .disabled(model.busy)
        .accessibilityIdentifier("shopping.home.continueInvitation")
    }

    private var cancelInvitationButton: some View {
        Button("Cancel invitation", role: .destructive) {
            Task { await model.prepareRemoval(.cancelInvitation) }
        }
        .disabled(!model.canManageMembers)
        .accessibilityIdentifier("shopping.home.cancelInvitation")
    }

    private var removalPrompt: MembershipRemovalPrompt? {
        guard let confirmation = model.removalConfirmation else { return nil }
        return MembershipRemovalPrompt(confirmation: confirmation, members: model.snapshot?.members ?? [])
    }
}

private struct MembershipRemovalPrompt {
    let title: String
    let action: String
    let message: String?

    init(confirmation: HomeMembershipRemovalConfirmation, members: [HomeMember]) {
        let isPending = confirmation.removal.purpose == .cancelInvitation ||
            (confirmation.removal.purpose == .removeMember && members.contains {
                confirmation.removal.participantIDs.contains($0.id) && $0.acceptance == .pending
            })
        if isPending {
            let invitedPerson = members.first { confirmation.removal.participantIDs.contains($0.id) }
            let name = [invitedPerson?.name, invitedPerson?.email]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            title = name.map { "Cancel invitation to “\($0)”?" } ?? "Cancel invitation?"
            action = "Cancel Invitation"
            message = nil
        } else if confirmation.removal.purpose == .removeMember {
            let name = confirmation.memberNames.first
            title = name.map { "Remove “\($0)”?" } ?? "Remove member?"
            action = "Remove Member"
            message = "They’ll lose access to “\(confirmation.homeName)”."
        } else {
            title = "Remove access?"
            action = "Remove Access"
            message = "Other people will lose access to “\(confirmation.homeName)”."
        }
    }
}

#Preview {
    let bootstrap = PersistenceBootstrap(preloadedPreviewEnvironment: try! ShoppingPreviewFixtures.make(.populated))
    let session = try! ShopperSession.authenticated(containerIdentifier: "iCloud.preview", environment: "Development", accountRecordName: "preview")
    let scope = ActiveHomeScope(session: session, graph: HomeGraphIdentity(storeIdentifier: "preview", rootURI: "preview", householdID: UUID(), listID: UUID()))
    let snapshot = HomeMembershipSnapshot(scope: scope, share: nil, homeName: "Our home", access: .owner,
        currentParticipantID: nil, members: [], changeTag: nil, observedAt: Date(), source: .localUnshared)
    NavigationStack {
        HomeDetailsView(scope: scope, name: "Our home", actions: HomeDetailsActions(
            refresh: { snapshot }, pending: { nil }, invite: { _ in throw HomeMembershipError.shareUnavailable },
            resend: { _ in throw HomeMembershipError.shareUnavailable }, acknowledge: { _ in }, rename: { _ in }))
    }.environmentObject(bootstrap)
}
