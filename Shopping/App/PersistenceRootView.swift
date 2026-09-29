import SwiftUI

struct PersistenceRootView: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch bootstrap.state {
            case .loading:
                ProgressView("Opening groceries…")
                    .accessibilityIdentifier("shopping.persistence.loading")
                    .task(id: bootstrap.loadingTransitionID) { await bootstrap.runLoadingTransition() }
            case .ready(let ready):
                Group {
                    if !ready.presentation.isActive { EmptyView() }
                    else if ready.householdID == nil {
                        NavigationStack {
                            ContentUnavailableView {
                                Label("Waiting for your household", systemImage: "icloud")
                            } description: {
                                if bootstrap.homeLeaveStatuses.contains(where: \.requiresResolution) {
                                    Text("Leaving a home is still being verified. Open Homes to check its status. Your personal cart and history remain saved.")
                                } else if bootstrap.homeLeaveStatuses.contains(where: \.completed) {
                                    Text("Your personal cart and history remain saved after leaving. Choose a home when you are ready.")
                                } else {
                                    Text(bootstrap.sharingStatusDescription)
                                    Text("Your existing groceries will appear after import. An empty cache does not create another household.")
                                }
                            } actions: {
                                NavigationLink("Choose a home") {
                                    HomeSelectionView(bootstrap: bootstrap, coordinator: bootstrap.homeCoordinator)
                                }
                                Button("Check again") { bootstrap.applicationDidEnterForeground() }
                                if let service = ready.personalCartService {
                                    NavigationLink("Saved personal carts") { PersonalRetainedCartsView(service: service) }
                                }
                        }
                        }
                    } else { ContentView() }
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
            case .failed(let error):
                PersistenceRecoveryView(error: error, retry: bootstrap.retry)
            }
        }
        .safeAreaInset(edge: .top) {
            if let invitations = bootstrap.invitations {
                HomeInvitationNotice(invitations: invitations, bootstrap: bootstrap)
            }
        }
        .environmentObject(bootstrap)
        .environment(\.homeEditorDraftStore, bootstrap.editorDrafts)
        .environment(\.sharingStatusDescription, bootstrap.sharingStatusDescription)
        .environment(\.sharingStatusPresentation, bootstrap.sharingStatusPresentation)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { bootstrap.applicationDidEnterForeground() }
        }
    }
}

#Preview {
    PersistenceRootView(bootstrap: PersistenceBootstrap(
        preloadedPreviewEnvironment: try! ShoppingPreviewFixtures.make(.populated)
    ))
}
