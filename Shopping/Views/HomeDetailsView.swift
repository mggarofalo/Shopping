import SwiftUI

struct HomeDetailsView: View {
    @StateObject private var model: HomeDetailsModel
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var bootstrap: PersistenceBootstrap
    @State private var showingInvitationExplanation = false
    @State private var requestedInvitation = false
    @State private var showingNameEditor = false
    @State private var name = ""
    let initialName: String

    init(scope: ActiveHomeScope, name: String, actions: HomeDetailsActions) {
        initialName = name
        _model = StateObject(wrappedValue: HomeDetailsModel(scope: scope, actions: actions))
    }

    private var homeName: String { model.snapshot?.homeName ?? initialName }
    private var cloudNeedsAttention: Bool {
        model.error != nil || bootstrap.homeSharingStatus.activity.notices.contains { $0.id != .invitation }
    }
    private var cloudIsWorking: Bool {
        model.busy || bootstrap.isCheckingSharingStatus || bootstrap.cloudStatus.isWorking
    }
    private var supportsLinks: Bool { if #available(iOS 18.0, *) { true } else { false } }

    var body: some View {
        List {
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
                    if let pending = model.pending,
                       !snapshot.members.contains(where: { $0.id == pending.participantID }) {
                        pendingInvitationRow(participantID: pending.participantID)
                    } else if model.needsPreparationRetry && model.pending == nil {
                        pendingInvitationRow(participantID: "preparing")
                    }
                    if !model.isCurrent && !model.busy && !snapshot.removals.contains(where: { $0.absentObservedAt == nil }) {
                        Button("Check members again") { Task { await model.refresh() } }
                    }
                }
            } header: {
                HStack {
                    Text("Members").font(.headline).accessibilityIdentifier("shopping.home.membersHeading")
                    Spacer()
                    if model.snapshot?.canInvite == true {
                        Button {
                            showingInvitationExplanation = true
                        } label: {
                            Image(systemName: "plus").frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!model.canInvite || !supportsLinks || model.pending != nil || model.needsPreparationRetry)
                        .accessibilityLabel("Invite contributor")
                        .accessibilityIdentifier("shopping.home.invite")
                    }
                }
                .textCase(nil)
                .frame(minHeight: 44)
            }
            if let snapshot = model.snapshot {
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
                    if snapshot.members.filter({ !$0.isCurrentUser && $0.role != .owner }).count > 1 {
                        Section {
                            Button("Stop sharing this home", role: .destructive) {
                                Task { await model.prepareRemoval(.stopSharing) }
                            }
                            .disabled(!model.canManageMembers)
                            .accessibilityIdentifier("shopping.home.stopSharing")
                        }
                    }
                }
                if snapshot.access != .owner && snapshot.source == .server {
                    Section {
                        Button("Leave home", role: .destructive) {
                            Task { await model.prepareLeave() }
                        }
                        .disabled(!model.canLeave)
                        .accessibilityIdentifier("shopping.home.leave")
                    }
                }
            }
            if let status = model.leaveStatus, !status.completed {
                Text("Leaving home is still being confirmed.")
                    .accessibilityIdentifier("shopping.home.leaveStatus")
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("shopping.home.error")
                if model.snapshot == nil {
                    Button("Check members again") { Task { await model.refresh() } }.disabled(model.busy)
                }
            }
            if bootstrap.homeCoordinator.homes.count > 1 || bootstrap.retainedLocalHomeName != nil
                || bootstrap.homeCoordinator.pendingInvitation
                || bootstrap.homeLeaveStatuses.contains(where: \.requiresResolution) || bootstrap.homeLeaveStatusError != nil {
                Section {
                    NavigationLink("Choose home") {
                        HomeSelectionView(bootstrap: bootstrap, coordinator: bootstrap.homeCoordinator)
                    }
                    .accessibilityIdentifier("shopping.home.manageHomes")
                }
            }
        }
        .navigationTitle(homeName)
        .toolbar {
            if model.snapshot?.canEditName == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        name = homeName
                        showingNameEditor = true
                    } label: {
                        Label("Rename home", systemImage: "pencil")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!model.canRename)
                    .accessibilityIdentifier("shopping.home.rename")
                }
            }
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
        .sheet(isPresented: $showingInvitationExplanation, onDismiss: {
            guard requestedInvitation else { return }
            requestedInvitation = false
            Task { await model.invite() }
        }) {
            NavigationStack {
                List {
                    Text("Invite someone to \(homeName)").font(.headline)
                    Text("Contributors can edit this home’s groceries, catalog and settings. Members can see one another and shared shopping activity. Personal carts and purchase history stay private.")
                    Text("This private link admits one person using iCloud. Anyone with the link can claim it. Send a separate link to each person you invite.")
                    Button("Create and share join link") {
                        requestedInvitation = true
                        showingInvitationExplanation = false
                    }
                    .disabled(!model.canInvite)
                    .accessibilityIdentifier("shopping.home.confirmInvite")
                }
                .navigationTitle("Invite contributor")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingInvitationExplanation = false } } }
            }
        }
        .sheet(item: $model.delivery, onDismiss: { Task { await model.refresh() } }) { delivery in
            HomeInvitationActivityView(delivery: delivery,
                onPresented: { Task { await model.presented(delivery) } },
                onFinished: { model.delivery = nil })
        }
        .sheet(item: $model.removalConfirmation) { confirmation in
            NavigationStack {
                List {
                    Text(confirmation.homeName).font(.headline)
                    Text(removalExplanation(confirmation))
                    ForEach(Array(confirmation.memberNames.enumerated()), id: \.offset) { _, name in Text(name) }
                    Text("Your home, groceries, People, and private cart history stay saved. Other devices may retain offline copies until they connect.")
                    Button("Confirm", role: .destructive) { Task { await model.confirmRemoval(confirmation) } }
                        .disabled(!model.canManageMembers)
                        .accessibilityIdentifier("shopping.home.confirmRemoval")
                }
                .navigationTitle("Change sharing access")
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.removalConfirmation = nil }
                } }
            }
        }
        .sheet(item: $model.leaveConfirmation) { command in
            HomeLeaveConfirmationView(homeName: command.homeName, canConfirm: model.canLeave,
                onConfirm: { Task { await model.confirmLeave(command) } },
                onCancel: { model.leaveConfirmation = nil })
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
            Text(model.needsPreparationRetry ? "Invitation needs attention" : "Invitation pending")
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
        Button(model.needsPreparationRetry ? "Retry invitation" : "Continue invitation") {
            Task { await model.invite(retryPreparation: model.needsPreparationRetry) }
        }
        .disabled(!model.canInvite || !supportsLinks)
        .accessibilityIdentifier("shopping.home.continueInvitation")
    }

    private var cancelInvitationButton: some View {
        Button("Cancel invitation", role: .destructive) {
            Task { await model.prepareRemoval(.cancelInvitation) }
        }
        .disabled(!model.canManageMembers)
        .accessibilityIdentifier("shopping.home.cancelInvitation")
    }

    private func removalExplanation(_ confirmation: HomeMembershipRemovalConfirmation) -> String {
        switch confirmation.removal.purpose {
        case .cancelInvitation:
            "Cancel this invitation? If iCloud is still creating it, cancellation will finish when membership is checked."
        case .removeMember:
            "Remove this member or pending invitation from this home? They will lose shared access once iCloud applies the removal."
        case .stopSharing:
            "Remove access for the people below?"
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
