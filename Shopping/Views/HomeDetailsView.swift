import SwiftUI

struct HomeDetailsView: View {
    @StateObject private var model: HomeDetailsModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sharingStatusPresentation) private var syncStatus
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
    private var supportsLinks: Bool { if #available(iOS 18.0, *) { true } else { false } }

    var body: some View {
        List {
            Section {
                Text(homeName).font(.headline).accessibilityIdentifier("shopping.home.name")
                if let snapshot = model.snapshot {
                    LabeledContent("Your access", value: accessLabel(snapshot.access))
                    if snapshot.source == .localUnshared {
                        Text("No invitations yet").foregroundStyle(.secondary)
                    } else {
                        Text("\(snapshot.acceptedOtherCount) other accepted members · \(snapshot.pendingCount) pending invitations")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("shopping.home.memberCounts")
                        Text(model.isCurrent ? "Membership checked with iCloud" : "Last known membership · check again")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Rename home") {
                    name = homeName
                    showingNameEditor = true
                }
                .disabled(!model.canRename)
                .accessibilityIdentifier("shopping.home.rename")
            } header: { Text("Home") }

            if let snapshot = model.snapshot {
                Section {
                    if snapshot.source == .localUnshared {
                        LabeledContent("You", value: "Owner")
                    }
                    ForEach(snapshot.members) { member in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(member.isCurrentUser ? "\(member.label) · You" : member.label)
                            Text(memberDetail(member)).font(.subheadline).foregroundStyle(.secondary)
                            if snapshot.canResend(member) && supportsLinks {
                                Button("Share invitation again") { Task { await model.resend(member.id) } }
                                    .disabled(!model.canInvite)
                                    .accessibilityIdentifier("shopping.home.resend.\(member.id)")
                            }
                            if snapshot.access == .owner && !member.isCurrentUser && member.role != .owner {
                                Button(member.acceptance == .pending ? "Cancel invitation" : "Remove contributor", role: .destructive) {
                                    Task { await model.prepareRemoval(.removeMember, participantID: member.id) }
                                }
                                .disabled(!model.canManageMembers)
                                .accessibilityIdentifier("shopping.home.remove.\(member.id)")
                            }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityElement(children: .contain)
                    }
                } header: { Text("Members") } footer: {
                    Text("Members can access this home. People in Settings are grocery assignees and do not grant access.")
                }
                if snapshot.canInvite {
                    Section {
                        Button(model.pending == nil ? "Invite contributor" : "Continue invitation") {
                            showingInvitationExplanation = true
                        }
                        .disabled(!model.canInvite || !supportsLinks)
                        .accessibilityIdentifier("shopping.home.invite")
                        if model.pending != nil {
                            Button("Cancel this invitation attempt", role: .destructive) {
                                Task { await model.prepareRemoval(.cancelInvitation) }
                            }
                            .disabled(!model.canManageMembers)
                            .accessibilityIdentifier("shopping.home.cancelInvitation")
                        }
                        if model.needsPreparationRetry {
                            Button("Retry preparing this home’s sharing") {
                                Task { await model.invite(retryPreparation: true) }
                            }
                            .disabled(!model.canInvite || !supportsLinks)
                        }
                        if !supportsLinks { Text("Creating invitation links requires iOS 18 or later.") }
                    } footer: {
                        Text("Send a private, one-person join link using Messages or another app. You do not need their iCloud email. Sharing the link does not confirm that they joined.")
                    }
                }
                if snapshot.access == .owner && snapshot.source == .server {
                    Section {
                        if snapshot.members.contains(where: { !$0.isCurrentUser && $0.role != .owner }) {
                            Button("Stop sharing this home", role: .destructive) {
                                Task { await model.prepareRemoval(.stopSharing) }
                            }
                            .disabled(!model.canManageMembers)
                            .accessibilityIdentifier("shopping.home.stopSharing")
                        }
                        ForEach(snapshot.removals) { status in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(status.removal.purpose == .cancelInvitation ? "Invitation cancellation recorded" : "Member removal recorded")
                                Text(status.absentObservedAt == nil
                                     ? "iCloud has not confirmed that these members are absent. Check again or retry the recorded removal."
                                     : "These members were absent at the last iCloud check. Other devices may still have offline copies.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if snapshot.removals.contains(where: { $0.requiresRetry && $0.absentObservedAt == nil }) {
                            Button("Retry recorded removals") { Task { await model.retryRemovals() } }
                                .disabled(!model.canManageMembers)
                                .accessibilityIdentifier("shopping.home.retryRemovals")
                        }
                    } header: { Text("Sharing access") } footer: {
                        Text("Removing members keeps your home and groceries. Cancelled invitations will not be shared again; if a delayed invitation appears, the app will try to remove it when membership is checked.")
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
            Section {
                if let status = model.leaveStatus {
                    Text(status.completed
                         ? "You have left this home. Your personal cart and history are retained."
                         : "Leaving this home is still being verified. Your personal cart and history are retained.")
                        .accessibilityIdentifier("shopping.home.leaveStatus")
                }
                Label(syncStatus.title, systemImage: syncStatus.symbol)
                Text(syncStatus.details).foregroundStyle(.secondary)
                if let error = model.error {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("shopping.home.error")
                }
                Button("Check members again") { Task { await model.refresh() } }.disabled(model.busy)
                if model.busy { ProgressView("Checking this home…") }
            } header: { Text("Status") }
        }
        .navigationTitle("Home details")
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
                    Text("They will be a Contributor and can edit this home’s groceries, catalog, stores, categories, people and home name. Members can see one another and shared shopping activity. Personal cart contents and purchase history stay private.")
                    Text("Anyone you send or forward this link to can claim its one invitation using iCloud. Send it only to the person you want to join. Create a separate invitation for each person.")
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

    private func removalExplanation(_ confirmation: HomeMembershipRemovalConfirmation) -> String {
        switch confirmation.removal.purpose {
        case .cancelInvitation:
            "Cancel this invitation attempt? Its link will no longer be offered by this app. If iCloud finishes creating it later, the app will try to remove that invitation when membership is checked. You can create a separate invitation afterward."
        case .removeMember:
            "Remove this member or pending invitation from this home? They will lose shared access once iCloud applies the removal."
        case .stopSharing:
            "Remove the \(confirmation.removal.participantIDs.count) members and pending invitations captured below? Anyone added after this confirmation was prepared is not included."
        }
    }

    private func accessLabel(_ access: HomeMembershipSnapshot.Access) -> String {
        switch access { case .owner: "Owner"; case .contributor: "Contributor"; case .restricted: "Read-only access" }
    }

    private func memberDetail(_ member: HomeMember) -> String {
        let role: String
        switch member.role { case .owner: role = "Owner"; case .contributor: role = "Contributor"; case .restricted: role = "Read-only access" }
        switch member.acceptance {
        case .accepted: return role + " · Accepted"
        case .pending: return role + " · Not yet accepted"
        case .unknown: return role + " · Checking acceptance"
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
