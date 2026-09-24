import Foundation

enum WatchServiceChange {
    case dataChanged
    case authorityInvalidated
}

@MainActor
protocol WatchShoppingService: AnyObject {
    // Invalidate synchronously before an account/authority switch, even during an async command.
    // Ordinary durable imports preserve the current captured checkout.
    var onChange: (@MainActor (WatchServiceChange) -> Void)? { get set }
    func load(storeID: UUID?) async throws -> WatchShoppingSnapshot
    func execute(_ command: WatchShoppingCommand) async throws -> WatchShoppingSnapshot
    func captureCheckout(storeID: UUID) async throws -> WatchCheckoutPreview
    func checkout(token: String) async throws -> WatchActionResult
    func restore(token: String) async throws -> WatchActionResult
}

// Deliberately honest until the production adapter/bootstrap is installed by SHOPPING-121.
@MainActor
final class UnavailableWatchShoppingService: WatchShoppingService {
    var onChange: (@MainActor (WatchServiceChange) -> Void)?

    func load(storeID: UUID?) async throws -> WatchShoppingSnapshot {
        WatchShoppingSnapshot(availability: .setupRequired(
            "Your household isn’t available on this watch yet. Set up Shopping on your iPhone."
        ))
    }

    func execute(_ command: WatchShoppingCommand) async throws -> WatchShoppingSnapshot { throw unavailable }
    func captureCheckout(storeID: UUID) async throws -> WatchCheckoutPreview { throw unavailable }
    func checkout(token: String) async throws -> WatchActionResult { throw unavailable }
    func restore(token: String) async throws -> WatchActionResult { throw unavailable }

    private var unavailable: NSError {
        NSError(domain: "ShoppingWatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Shopping is not set up on this watch."])
    }
}
