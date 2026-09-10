import SwiftUI

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

struct ShoppingToast: Identifiable {
    let id: UUID
    let message: String
    let duration: ShoppingToastDuration
    let action: ShoppingToastAction?
}

@MainActor
final class ShoppingToastCenter: ObservableObject {
    typealias Sleeper = (TimeInterval) async throws -> Void

    @Published private(set) var toasts: [ShoppingToast] = []
    private var dismissalTasks: [UUID: Task<Void, Never>] = [:]
    private let sleeper: Sleeper

    init(sleeper: @escaping Sleeper = { duration in
        try await Task.sleep(for: .seconds(duration))
    }) {
        self.sleeper = sleeper
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
        dismissalTasks[toast.id] = Task { [weak self, sleeper] in
            do {
                try await sleeper(duration.rawValue)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
        return toast.id
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
