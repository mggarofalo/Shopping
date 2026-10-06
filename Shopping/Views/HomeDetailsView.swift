import SwiftUI

struct HomeDetailsView: View {
    @StateObject private var model: HomeDetailsModel
    @StateObject private var invitations: HomeNamedInvitationsModel
    @State private var showingInvitationName = false
    @State private var selectedInvitation: HomeInvitationRoute?
    @State private var preparedInvitation: UUID?
    @State private var showingSharingStatus = false
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var bootstrap: PersistenceBootstrap
    @State private var showingInviteRequirement = false
    @State private var showingNameEditor = false
    @State private var name = ""
    let initialName: String
    let initialAccess: HomeCandidate.Access?

    init(scope: ActiveHomeScope, name: String, actions: HomeDetailsActions, access: HomeCandidate.Access? = nil) {
        initialName = name
        initialAccess = access
        _model = StateObject(wrappedValue: HomeDetailsModel(scope: scope, actions: actions, initialAccess: access))
        _invitations = StateObject(wrappedValue: HomeNamedInvitationsModel(scope: scope, actions: actions.namedInvitations))
    }

    private var homeName: String { model.snapshot?.homeName ?? initialName }
    private var cloudNeedsAttention: Bool {
        bootstrap.homeSharingStatus.activity.notices.contains { $0.id != .invitation }
    }
    private var cloudIsWorking: Bool {
        model.isRefreshing || bootstrap.isCheckingSharingStatus || bootstrap.cloudStatus.isWorking
    }
    private var supportsLinks: Bool { if #available(iOS 18.0, *) { true } else { false } }

    var body: some View {
        List {
            Section("Home") {
                if model.snapshot?.canEditName ?? (initialAccess == .owner || initialAccess == .contributor) {
                    Button {
                        name = homeName
                        showingNameEditor = true
                    } label: {
                        LabeledContent("Name", value: homeName)
                    }

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
                    ForEach(snapshot.members.filter { $0.acceptance != .pending }) { member in
                        HomeMemberRow(member: member, hasActions: hasActions(member, in: snapshot)) {
                            memberActions(member, in: snapshot)
                        }
                        if let record = invitations.records.first(where: { $0.participantIDs.contains(member.id) }),
                           member.name != record.name && member.email != record.name {
                            Text("Invited as \(record.name)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if !model.isCurrent && !model.busy && !snapshot.removals.contains(where: { $0.absentObservedAt == nil }) {
                        Button("Check members again") { Task { await model.refresh() } }
                    }
                }
            } header: {
                Text("Members").accessibilityIdentifier("shopping.home.membersHeading")
            }
            if model.snapshot == nil && initialAccess == .owner { invitationSection }
            if let snapshot = model.snapshot {
                if snapshot.canInvite {
                    invitationSection
                }
                if snapshot.access == .owner && snapshot.source == .server {
                    let pendingRemovals = snapshot.removals.filter { $0.absentObservedAt == nil }
                    if !pendingRemovals.isEmpty {
                        Section {
                            Text("Sharing changes pending")
                            if pendingRemovals.contains(where: \.requiresRetry) {
                                Button("Retry recorded removals") { Task { await model.retryRemovals() } }
                                    .disabled(!model.canManageMembers || invitations.busy)
                                    .accessibilityIdentifier("shopping.home.retryRemovals")
                            } else {
                                Button("Check members again") { Task { await model.refresh() } }
                                    .disabled(model.busy)
                            }
                        }
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
            Section("Sharing") {
                if model.isRefreshing {
                    ProgressView("Checking members…").accessibilityIdentifier("shopping.home.checking")
                } else if let error = model.refreshError {
                    Text(error).foregroundStyle(.secondary)
                    Button("Check again") { Task { await refresh() } }
                } else if let snapshot = model.snapshot {
                    LabeledContent("Members checked") { Text(snapshot.observedAt, style: .relative) }
                }
                if let operation = model.operation {
                    ProgressView(operation.label).accessibilityIdentifier("shopping.home.progress")
                }
                if invitations.busy, let operation = invitations.operation {
                    ProgressView(operation).accessibilityIdentifier("shopping.home.invitation.progress")
                }
            }
            if let snapshot = model.snapshot {
                if snapshot.access != .owner && snapshot.source == .server {
                    Section {
                        Button("Leave Home", role: .destructive) {
                            Task { await model.prepareLeave() }
                        }
                        .disabled(!model.canLeave || invitations.busy)
                        .accessibilityIdentifier("shopping.home.leave")
                    }
                }
                if snapshot.access == .owner && model.hasDeletionAction {
                    Section {
                        Button("Delete Home", role: .destructive) {
                            Task { await model.prepareDeletion() }
                        }
                        .disabled(!model.canDelete || invitations.busy)
                        .accessibilityIdentifier("shopping.home.delete")
                    }
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
                Button { showingSharingStatus = true } label: {
                    HomeCloudSymbol(isWorking: cloudIsWorking, needsAttention: cloudNeedsAttention)
                }
                .accessibilityLabel("Sharing status")
                .accessibilityValue(cloudNeedsAttention ? "Needs attention" : model.isRefreshing ? "Checking home" : cloudIsWorking ? "Syncing" : "")
                .accessibilityIdentifier("shopping.home.sharingStatus")
            }
        }
        .refreshable { await refresh() }
        .task { model.activate(); invitations.activate(); await refresh() }
        .onDisappear {
            if selectedInvitation == nil && !showingSharingStatus {
                model.retire()
                invitations.retire()
            }
        }
        .onChange(of: bootstrap.homeEntry.root) { _, root in
            if root != .activeHome(model.scope) { model.retire(); invitations.retire() }
        }
        .navigationDestination(item: $selectedInvitation) { route in
            HomeInvitationDetailView(route: route, invitations: invitations, details: model)
        }
        .navigationDestination(isPresented: $showingSharingStatus) { HomeSharingStatusView() }
        .sheet(isPresented: $showingInvitationName, onDismiss: {
            if let id = preparedInvitation { selectedInvitation = .named(id); preparedInvitation = nil }
        }) {
            HomeInvitationNameView(invitations: invitations, details: model) { record in
                preparedInvitation = record.id
                showingInvitationName = false
                Task { await model.refresh() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
        .alert("Inviting requires iOS 18 or later.", isPresented: $showingInviteRequirement) {
            Button("OK", role: .cancel) {}
        }
        .sheet(item: Binding(get: { selectedInvitation == nil ? model.delivery : nil }, set: { model.delivery = $0 }), onDismiss: { Task { await model.refresh() } }) { delivery in
            HomeInvitationActivityView(delivery: delivery,
                onPresented: { Task { await model.presented(delivery) } },
                onFinished: { _, _ in model.delivery = nil })
        }
        .homeRemovalConfirmation(model: model, enabled: selectedInvitation == nil)
        .alert("Leave “\(model.leaveConfirmation?.homeName ?? homeName)”?", isPresented: Binding(
            get: { model.leaveConfirmation != nil },
            // The confirm task consumes the captured command before suspending.
            // Automatic alert dismissal must not clear it first.
            set: { _ in }
        )) {
            if let command = model.leaveConfirmation {
                Button("Leave Home", role: .destructive) { Task { await model.confirmLeave(command) } }
                    .disabled(!model.canLeave || invitations.busy)
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
                    .disabled(!model.canDelete || invitations.busy)
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
                    available: model.snapshot?.canEditName ?? (initialAccess == .owner || initialAccess == .contributor), busy: model.busy || invitations.busy,
                    onSave: { Task { if await model.rename(name) { showingNameEditor = false } } },
                    onCancel: { showingNameEditor = false }, draftIdentity: "home-name")
                if let error = model.error { Text(error).foregroundStyle(.red).padding() }
            }
        }
    }

    private func refresh() async {
        async let members: Void = model.refresh()
        if model.snapshot?.canInvite ?? (initialAccess == .owner) { await invitations.refresh() }
        await members
        if model.snapshot?.canInvite == true { await invitations.refresh() }
    }

    private var invitationSection: some View {
        Section {
            ForEach(invitations.records.filter { !$0.isTerminal }) { record in
                Button { selectedInvitation = .named(record.id) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.name).foregroundStyle(.primary)
                            Text(HomeInvitationPresentation(record: record, snapshot: model.snapshot).status)
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    }
                }
                .accessibilityIdentifier("shopping.home.invitation.row.\(record.id)")
            }
            ForEach((model.snapshot?.members ?? []).filter { member in
                member.acceptance == .pending && !invitations.records.contains { $0.participantIDs.contains(member.id) }
            }) { member in
                Button { selectedInvitation = .legacy(member.id) } label: {
                    LabeledContent("Unnamed invitation", value: "Review")
                }
                .accessibilityIdentifier("shopping.home.invitation.legacy.\(member.id)")
            }
            if let pending = model.pending,
               !invitations.records.contains(where: { $0.participantIDs.contains(pending.participantID) }),
               model.snapshot?.members.contains(where: { $0.id == pending.participantID }) != true {
                pendingInvitationRow(participantID: pending.participantID)
            } else if model.needsPreparationRetry && invitations.records.isEmpty {
                pendingInvitationRow(participantID: "preparing")
            }
            if supportsLinks {
                Button("Invite someone", systemImage: "person.badge.plus") { invite() }
                    .accessibilityIdentifier("shopping.home.invite")
            } else { Text("Inviting someone requires iOS 18 or later.").foregroundStyle(.secondary) }
            if let error = invitations.refreshError { Text(error).foregroundStyle(.secondary) }
        } header: { Text("Invitations") } footer: { Text("Each invitation is for one person.") }
    }

    private func invite() {
        guard supportsLinks else {
            showingInviteRequirement = true
            return
        }
        if invitations.available { showingInvitationName = true }
        else { Task { await model.invite() } }
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
                .disabled(!model.canManageMembers || invitations.busy)
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
        .disabled(!model.canManageMembers || invitations.busy)
        .accessibilityIdentifier("shopping.home.cancelInvitation")
    }

    private var removalPrompt: MembershipRemovalPrompt? {
        guard let confirmation = model.removalConfirmation else { return nil }
        return MembershipRemovalPrompt(confirmation: confirmation, members: model.snapshot?.members ?? [])
    }
}

struct MembershipRemovalPrompt {
    let title: String
    let action: String
    let message: String?

    init(confirmation: HomeMembershipRemovalConfirmation, members: [HomeMember], invitedName: String? = nil) {
        let isPending = confirmation.removal.purpose == .cancelInvitation ||
            (confirmation.removal.purpose == .removeMember && members.contains {
                confirmation.removal.participantIDs.contains($0.id) && $0.acceptance == .pending
            })
        if isPending {
            let invitedPerson = members.first { confirmation.removal.participantIDs.contains($0.id) }
            let name = [invitedName, invitedPerson?.name, invitedPerson?.email]
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
