import Foundation

enum ShoppingActionDestination: Equatable {
    case addItem
    case createItem(String)
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

    private struct Creation: Equatable {
        let name: String
        let presentationID: UUID?
    }

    @Published private(set) var pending: Request?
    @Published var message: String?
    /// The editor a delivered creation opened, until its Add sheet closes.
    private var openCreation: Creation?

    func enqueue(_ destination: ShoppingActionDestination, presentationID: UUID?, now: Date = Date()) throws {
        expire(now: now)
        if case .createItem(let name) = destination {
            try rejectRepeatedCreation(name, presentationID: presentationID, now: now)
        }
        guard pending == nil else { throw ShoppingActionError.busy }
        pending = Request(id: UUID(), destination: destination, presentationID: presentationID,
                          expiresAt: now.addingTimeInterval(300))
    }

    /// Siri AI re-runs a create action that returns no reminder, seconds later, while the
    /// editor it opened is still up (SHOPPING-271). The same name for the same Home, queued
    /// or open, is that re-run rather than a new request.
    func rejectRepeatedCreation(_ name: String, presentationID: UUID?, now: Date = Date()) throws {
        expire(now: now)
        let creation = Creation(name: CatalogProjection.normalizedName(name), presentationID: presentationID)
        let queued = pending.flatMap { request -> Creation? in
            guard case .createItem(let name) = request.destination else { return nil }
            return Creation(name: CatalogProjection.normalizedName(name), presentationID: request.presentationID)
        }
        guard creation == openCreation || creation == queued else { return }
        throw ShoppingActionError.creationOpen
    }

    func creationClosed() { openCreation = nil }

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
        if case .createItem(let name) = request.destination {
            openCreation = Creation(name: CatalogProjection.normalizedName(name), presentationID: presentationID)
        }
        return request.destination
    }

    func cancel() { pending = nil }
}
