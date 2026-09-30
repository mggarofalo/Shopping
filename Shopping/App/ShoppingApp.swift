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
    @AppStorage("shopping.appearance") private var appearance = AppearancePreference.system.rawValue

    init() {
        _bootstrap = StateObject(wrappedValue: .application())
    }

    var body: some Scene {
        WindowGroup {
            PersistenceRootView(bootstrap: bootstrap)
                .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
        }
    }
}
