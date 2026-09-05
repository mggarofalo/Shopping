import SwiftUI

@main
struct ShoppingApp: App {
    @StateObject private var bootstrap: PersistenceBootstrap
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _bootstrap = StateObject(wrappedValue: .application())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch bootstrap.state {
                case .loading:
                    ProgressView("Opening groceries…")
                        .accessibilityIdentifier("shopping.persistence.loading")
                case .ready(let ready):
                    ContentView()
                        .environment(\.managedObjectContext, ready.persistence.container.viewContext)
                        .environment(\.needService, ready.service)
                        .environment(\.persistenceSelection, PersistenceSelection(
                            householdID: ready.householdID,
                            listID: ready.listID
                        ))
                case .failed(let error):
                    PersistenceRecoveryView(error: error, retry: bootstrap.retry)
                }
            }
            .environmentObject(bootstrap)
            .task { bootstrap.start() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { bootstrap.applicationDidEnterForeground() }
            }
        }
    }
}
