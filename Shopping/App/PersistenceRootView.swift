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
                    .task(id: bootstrap.loadingTransitionID) { bootstrap.runLoadingTransition() }
            case .ready(let ready):
                Group {
                    if !ready.presentation.isActive { EmptyView() }
                    else if (ready.persistence.configuration.isManaged || ready.personalCartService != nil) && ready.householdID == nil {
                        NavigationStack {
                            ContentUnavailableView {
                                Label("Waiting for your household", systemImage: "icloud")
                            } description: {
                                Text(bootstrap.sharingStatusDescription)
                                Text("Your existing groceries will appear after import. An empty cache does not create another household.")
                            } actions: {
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
                        listID: ready.listID
                    ))
            case .failed(let error):
                PersistenceRecoveryView(error: error, retry: bootstrap.retry)
            }
        }
        .environmentObject(bootstrap)
        .environment(\.sharingStatusDescription, bootstrap.sharingStatusDescription)
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
