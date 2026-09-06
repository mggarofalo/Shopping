import SwiftUI
import UIKit

enum HapticEvent: Equatable {
    case lightImpact
    case success
    case warning
}

struct HapticFeedback {
    var play: (HapticEvent) -> Void

    init() {
        play = HapticFeedback.playSystem
    }

    init(play: @escaping (HapticEvent) -> Void) {
        self.play = play
    }

    private static func playSystem(_ event: HapticEvent) {
        switch event {
        case .lightImpact:
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.65)
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}

private struct HapticFeedbackKey: EnvironmentKey {
    static let defaultValue = HapticFeedback()
}

extension EnvironmentValues {
    var hapticFeedback: HapticFeedback {
        get { self[HapticFeedbackKey.self] }
        set { self[HapticFeedbackKey.self] = newValue }
    }
}

@main
struct ShoppingApp: App {
    @StateObject private var bootstrap: PersistenceBootstrap
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("shopping.appearance") private var appearance = AppearancePreference.system.rawValue

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
            .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
            .task { bootstrap.start() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { bootstrap.applicationDidEnterForeground() }
            }
        }
    }
}
