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
    @UIApplicationDelegateAdaptor(ShoppingApplicationDelegate.self) private var applicationDelegate
    @StateObject private var bootstrap: PersistenceBootstrap
    @Environment(\.scenePhase) private var scenePhase
    private let shortcutsRegistration: ShoppingShortcutsRegistration
    @AppStorage("shopping.appearance") private var appearance = AppearancePreference.system.rawValue

    init() {
        let bootstrap = ShoppingApplicationRuntime.shared.bootstrap
        _bootstrap = StateObject(wrappedValue: bootstrap)
        shortcutsRegistration = ShoppingShortcutsRegistration(bootstrap: bootstrap)
    }

    var body: some Scene {
        WindowGroup {
            PersistenceRootView(bootstrap: bootstrap)
                #if DEBUG
                .task { await SystemActionUITestFixture.deliver(runtime: ShoppingApplicationRuntime.shared) }
                #endif
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { shortcutsRegistration.refresh() }
                }
                .tint(.groceryAccent)
                .environment(\.defaultMinListRowHeight, ShoppingListMetrics.minimumListRowHeight)
                .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
        }
    }
}
