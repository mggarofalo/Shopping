import SwiftUI

private enum HomeRootSheet: Identifiable, Equatable {
    case homes
    case invitation(UUID)

    var id: String {
        switch self {
        case .homes: "homes"
        case .invitation(let id): "invitation-\(id.uuidString)"
        }
    }
}

struct PersistenceRootView: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: HomeRootSheet?
    @State private var lastSheet: HomeRootSheet?
    @State private var pendingSheet: HomeRootSheet?
    @State private var dismissedInvitationID: UUID?
    @State private var dismissedReplacementID: UUID?
    @State private var isCreatingFirstHome = false
    @State private var rootError: String?
    @State private var showingJoinDismissError = false

    var body: some View {
        Group {
            switch bootstrap.state {
            case .loading:
                ProgressView("Opening groceries…")
                    .accessibilityIdentifier("shopping.persistence.loading")
                    .task(id: bootstrap.loadingTransitionID) { await bootstrap.runLoadingTransition() }
            case .ready(let ready):
                readyBody(ready)
            case .failed(let error):
                NavigationStack {
                    PersistenceRecoveryView(error: error, retry: bootstrap.retry)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let record = bootstrap.replacementStatus, bootstrap.replacementError != nil,
               bootstrap.replacementInProgress == nil {
                Button { present(.homes) } label: {
                    HStack {
                        Text(record.stage == .sourceKept
                            ? "\(record.proposal.source.name) was kept." : "Replacement needs attention.")
                        Spacer()
                        Text("Homes")
                    }
                    .frame(minHeight: 44).padding(.horizontal, 16)
                }
                .background(.regularMaterial)
                .accessibilityIdentifier("shopping.replacement.notice")
            } else if case .deferred(let invitation) = bootstrap.homeEntry.joinPresentation {
                HomeInvitationNotice(bootstrap: bootstrap, invitation: invitation)
            }
        }
        .sheet(item: $sheet, onDismiss: sheetDismissed) { route in
            switch route {
            case .homes:
                HomeSelectionView(bootstrap: bootstrap)
            case .invitation(let id):
                HomeInvitationsView(bootstrap: bootstrap, invitationID: id) {
                    if bootstrap.replacementInProgress?.invitationID == id { dismissedReplacementID = id }
                    sheet = nil
                }
            }
        }
        .alert("Couldn’t pause joining", isPresented: $showingJoinDismissError) {
            Button("Open Invitation") {
                if let dismissedInvitationID { present(.invitation(dismissedInvitationID)) }
            }
        } message: {
            Text("Your join is still in progress.")
        }
        .environment(\.homeScopeDisplay, scopeDisplay)
        .environmentObject(bootstrap)
        .environment(\.presentHomes) { present(.homes) }
        .environment(\.presentInvitation) { present(.invitation($0)) }
        .environment(\.homeEditorDraftStore, bootstrap.editorDrafts)
        .environment(\.sharingStatusDescription, bootstrap.sharingStatusDescription)
        .environment(\.sharingStatusPresentation, bootstrap.sharingStatusPresentation)
        .onChange(of: requestedInvitationID, initial: true) { _, id in
            if let id {
                if dismissedInvitationID != id { present(.invitation(id)) }
            } else {
                dismissedInvitationID = nil
                if case .invitation = pendingSheet { pendingSheet = nil }
                if case .invitation = sheet { sheet = nil }
            }
        }
        .onChange(of: bootstrap.homeEntry.root) { previous, root in
            guard sheet == .homes else { return }
            if root == .noHomes { sheet = nil; return }
            switch previous {
            case .activeHome, .localHome: sheet = nil
            default: break
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { bootstrap.applicationDidEnterForeground() }
        }
    }

    private var requestedInvitationID: UUID? {
        if let replacement = bootstrap.replacementInProgress, sheet == .invitation(replacement.invitationID) {
            return replacement.invitationID
        }
        if case .active(let invitation) = bootstrap.homeEntry.joinPresentation { return invitation.id }
        return nil
    }

    private var scopeDisplay: HomeScopeDisplay? {
        let entry = bootstrap.homeEntry
        guard let name = entry.currentHomeDisplayName ??
            (entry.isShowingRetainedLocalHome ? entry.retainedLocalHomeName : nil) else { return nil }
        return HomeScopeDisplay(name: name,
            isLocal: entry.isLocalStore || entry.isShowingRetainedLocalHome,
            // Account discovery is suspended while the retained local store is
            // mounted. Keep its context visible without treating an empty
            // mounted roster as proof that this is the user's only home.
            showsContext: entry.isShowingRetainedLocalHome ||
                entry.homes.count + (entry.retainedLocalHomeName != nil ? 1 : 0) > 1)
    }

    @ViewBuilder
    private func readyBody(_ ready: PersistenceBootstrap.ReadyState) -> some View {
        Group {
            if !ready.presentation.isActive {
                EmptyView()
            } else {
                switch bootstrap.homeEntry.root {
                case .activeHome, .localHome:
                    if ready.householdID != nil { ContentView() }
                    else { waitingHomes }
                case .noHomes:
                    noHomes
                case .chooseHome:
                    chooseHome
                case .selectedHomeUnavailable:
                    unavailableHome
                case .opening, .waitingForHomes:
                    waitingHomes
                case .accountUnavailable:
                    unavailableHome
                case .failed:
                    unavailableHome
                }
            }
        }
        .id(ready.presentation.id)
        .onAppear { bootstrap.presentationDidAppear(ready.presentation.id) }
        .onDisappear { bootstrap.presentationDidDisappear(ready.presentation.id) }
        .environment(\.persistencePresentation, ready.presentation)
        .environment(\.managedObjectContext, ready.persistence.container.viewContext)
        .environment(\.needService, ready.service)
        .environment(\.personalCart, ready.personalCart)
        .environment(\.activatePersonalCart, { bootstrap.activatePersonalCarts(importLegacy: $0) })
        .environment(\.persistenceSelection, PersistenceSelection(
            householdID: ready.householdID,
            listID: ready.listID,
            homeScope: ready.homeScope
        ))
    }

    private var noHomes: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(hasExitedHome ? "No Homes" : "Create a Home", systemImage: "house")
            } description: {
                if !hasExitedHome { Text("Invited? Open your invite link.") }
            } actions: {
                Button("Create Home") { createFirstHome() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreatingFirstHome || bootstrap.homeEntry.isCreatingHome)
                    .accessibilityIdentifier("shopping.home.createFirst")
                if !bootstrap.homeEntry.invitations.isEmpty ||
                    bootstrap.homeDeletionStatuses.contains(where: \.requiresResolution) ||
                    bootstrap.homeDeletionStatusError != nil {
                    Button("Homes") { present(.homes) }
                        .accessibilityIdentifier("shopping.home.choose")
                }
                if isCreatingFirstHome { ProgressView() }
                if let rootError { Text(rootError).foregroundStyle(.red) }
                savedCartsLink
            }
            .navigationTitle("Shopping")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var hasExitedHome: Bool {
        bootstrap.hasDeletedHome || !bootstrap.homeLeaveStatuses.isEmpty
    }

    private var chooseHome: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Choose a Home", systemImage: "house")
            } actions: {
                Button("Homes") { present(.homes) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("shopping.home.choose")
                savedCartsLink
            }
            .navigationTitle("Shopping")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var unavailableHome: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Home unavailable", systemImage: "house")
            } actions: {
                Button("Homes") { present(.homes) }
                Button("Check Again") { bootstrap.applicationDidEnterForeground() }
                savedCartsLink
            }
            .navigationTitle("Shopping")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var waitingHomes: some View {
        NavigationStack {
            Group {
                if bootstrap.homeEntry.homeDiscoveryFailed {
                    ContentUnavailableView {
                        Label("Couldn’t load homes", systemImage: "house")
                    } description: {
                        Text("Try again.")
                    } actions: {
                        Button("Check Again") { bootstrap.applicationDidEnterForeground() }
                        if bootstrap.homeEntry.retainedLocalHomeName != nil {
                            Button("Homes") { present(.homes) }
                                .accessibilityIdentifier("shopping.home.choose")
                        }
                        savedCartsLink
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading Homes…")
                        if bootstrap.homeEntry.retainedLocalHomeName != nil {
                            Button("Homes") { present(.homes) }
                                .accessibilityIdentifier("shopping.home.choose")
                        }
                        savedCartsLink
                    }
                }
            }
            .navigationTitle("Shopping")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var savedCartsLink: some View {
        if case .ready(let ready) = bootstrap.state, let service = ready.personalCartService {
            NavigationLink("Saved personal carts") { PersonalRetainedCartsView(service: service) }
                .accessibilityIdentifier("shopping.home.savedCarts")
        }
    }

    private func createFirstHome() {
        guard !isCreatingFirstHome else { return }
        isCreatingFirstHome = true
        rootError = nil
        Task {
            defer { isCreatingFirstHome = false }
            do { try await bootstrap.homeEntryCommands.createFirstHome() }
            catch { rootError = "Couldn’t create home. Try again." }
        }
    }

    private func present(_ route: HomeRootSheet) {
        if sheet != nil && sheet != route {
            pendingSheet = route
            sheet = nil
            return
        }
        lastSheet = route
        sheet = route
    }

    private func sheetDismissed() {
        let dismissed = lastSheet
        lastSheet = nil
        if let pendingSheet {
            self.pendingSheet = nil
            lastSheet = pendingSheet
            sheet = pendingSheet
            return
        }
        if case .invitation(let id) = dismissed, dismissedReplacementID == id {
            dismissedReplacementID = nil
            dismissedInvitationID = id
            return
        }
        guard case .invitation(let id) = dismissed,
              case .active(let invitation) = bootstrap.homeEntry.joinPresentation,
              invitation.id == id else { return }
        dismissedInvitationID = id
        Task {
            do { try await bootstrap.homeEntryCommands.dismissJoin(id) }
            catch { showingJoinDismissError = true }
        }
    }
}

#Preview {
    PersistenceRootView(bootstrap: PersistenceBootstrap(
        preloadedPreviewEnvironment: try! ShoppingPreviewFixtures.make(.populated)
    ))
}
