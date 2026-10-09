import Foundation

enum ShoppingActionDestination: Equatable {
    case addItem
    case groceries
    case catalog(String)

    init?(shortcutType: String) {
        switch shortcutType {
        case "com.mggarofalo.shopping.add": self = .addItem
        case "com.mggarofalo.shopping.groceries": self = .groceries
        case "com.mggarofalo.shopping.catalog": self = .catalog("")
        default: return nil
        }
    }
}

/// A bounded navigation request, never a persistence command or an editor draft.
@MainActor
final class ShoppingActionRouter: ObservableObject {
    struct Request: Identifiable, Equatable {
        let id: UUID
        let destination: ShoppingActionDestination
        let presentationID: UUID?
        let expiresAt: Date
    }

    @Published private(set) var pending: Request?
    @Published var message: String?

    func enqueue(_ destination: ShoppingActionDestination, presentationID: UUID?, now: Date = Date()) throws {
        expire(now: now)
        guard pending == nil else { throw ShoppingActionError.busy }
        pending = Request(id: UUID(), destination: destination, presentationID: presentationID,
                          expiresAt: now.addingTimeInterval(300))
    }

    func expire(now: Date = Date()) {
        if let pending, pending.expiresAt <= now { self.pending = nil }
    }

    func take(presentationID: UUID, now: Date = Date()) throws -> ShoppingActionDestination? {
        expire(now: now)
        guard let request = pending else { return nil }
        pending = nil
        guard request.presentationID == nil || request.presentationID == presentationID else {
            throw ShoppingActionError.scopeChanged
        }
        return request.destination
    }

    func cancel() { pending = nil }
}
