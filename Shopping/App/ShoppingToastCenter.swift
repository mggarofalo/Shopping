import SwiftUI
import UIKit

enum ShoppingToastDuration: TimeInterval {
    case success = 3
    case attention = 5
    case undo = 10
}

struct ShoppingToastAction {
    let title: String
    let accessibilityIdentifier: String
    let perform: @MainActor () -> Bool
}

/// Consecutive toasts with the same key merge into one counted summary.
struct ShoppingToastCoalescing {
    let key: String
    let summary: (Int) -> String
}

struct ShoppingToast: Identifiable {
    let id: UUID
    let message: String
    let duration: ShoppingToastDuration
    let action: ShoppingToastAction?
    var coalescing: ShoppingToastCoalescing? = nil
    var count = 1
}

@MainActor
final class ShoppingToastCenter: ObservableObject {
    typealias Sleeper = (TimeInterval) async throws -> Void
    typealias Announcer = @MainActor (String) -> Void

    @Published private(set) var toasts: [ShoppingToast] = []
    /// Screens with a bottom bar host toasts inside their safe area; the app-wide host yields to them.
    @Published private(set) var screenHostCount = 0
    private var dismissalTasks: [UUID: Task<Void, Never>] = [:]
    private let sleeper: Sleeper
    private let announce: Announcer

    init(sleeper: @escaping Sleeper = { duration in
        try await Task.sleep(for: .seconds(duration))
    }, announce: @escaping Announcer = { message in
        UIAccessibility.post(notification: .announcement, argument: message)
    }) {
        self.sleeper = sleeper
        self.announce = announce
    }

    @discardableResult
    func show(
        _ message: String,
        duration: ShoppingToastDuration,
        action: ShoppingToastAction? = nil
    ) -> UUID {
        let toast = ShoppingToast(
            id: UUID(),
            message: message,
            duration: duration,
            action: action
        )
        toasts.append(toast)
        present(toast)
        return toast.id
    }

    /// Shows actionless feedback, or replaces the newest toast with a counted summary when it has the same key.
    /// Toasts with actions never coalesce, because each action belongs to one change.
    @discardableResult
    func show(
        _ message: String,
        duration: ShoppingToastDuration,
        coalescing: ShoppingToastCoalescing
    ) -> UUID {
        guard let last = toasts.last, last.coalescing?.key == coalescing.key else {
            let toast = ShoppingToast(id: UUID(), message: message, duration: duration, action: nil,
                coalescing: coalescing)
            toasts.append(toast)
            present(toast)
            return toast.id
        }
        let count = last.count + 1
        let toast = ShoppingToast(id: last.id, message: coalescing.summary(count), duration: duration, action: nil,
            coalescing: coalescing, count: count)
        toasts[toasts.count - 1] = toast
        present(toast)
        return toast.id
    }

    /// Announces once per new or changed message; hosts may re-render a toast as screens change.
    private func present(_ toast: ShoppingToast) {
        announce(toast.message)
        dismissalTasks[toast.id]?.cancel()
        // Actionable feedback needs time to read and act, including while an
        // editor is dismissing. Use the same bounded window as Undo.
        let delay = toast.action == nil ? toast.duration.rawValue
            : max(toast.duration.rawValue, ShoppingToastDuration.undo.rawValue)
        dismissalTasks[toast.id] = Task { [weak self, sleeper] in
            do {
                try await sleeper(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
    }

    func dismiss(_ id: UUID) {
        dismissalTasks[id]?.cancel()
        dismissalTasks[id] = nil
        toasts.removeAll { $0.id == id }
    }

    func performAction(for toast: ShoppingToast) {
        guard toast.action?.perform() == true else { return }
        dismiss(toast.id)
    }

    func claimScreenHost() { screenHostCount += 1 }

    func releaseScreenHost() { screenHostCount = max(0, screenHostCount - 1) }
}

extension ShoppingToastCenter {
    /// UI tests can hold toasts until dismissed, so swipe and placement proof never depends on the timer.
    static func forLaunch(environment: [String: String] = ProcessInfo.processInfo.environment) -> ShoppingToastCenter {
        guard environment["SHOPPING_UI_TEST_STORE_PATH"] != nil,
              environment["SHOPPING_UI_TEST_HOLD_TOASTS"] == "1" else { return ShoppingToastCenter() }
        return ShoppingToastCenter { _ in try await Task.sleep(for: .seconds(3600)) }
    }
}

private struct ShoppingToastCenterKey: EnvironmentKey {
    static let defaultValue: ShoppingToastCenter? = nil
}

extension EnvironmentValues {
    var shoppingToastCenter: ShoppingToastCenter? {
        get { self[ShoppingToastCenterKey.self] }
        set { self[ShoppingToastCenterKey.self] = newValue }
    }
}
