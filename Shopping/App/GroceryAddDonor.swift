import Foundation

/// One grocery the user added from the app's own screens, addressed as Siri addresses it.
struct GroceryAddDonation: Equatable, Sendable {
    let title: String
    let listEntityID: String
}

/// Tells iOS about grocery adds made in the app's UI. Donating the add action is Apple's
/// only documented cue for learning which app the user prefers for list requests
/// (SHOPPING-282). iOS already learns from Siri and Shortcuts runs, so only UI actions
/// call this; Siri handoffs, imports, Watch receipts and test hosts never do.
@MainActor
final class GroceryAddDonor {
    typealias Sink = @Sendable (GroceryAddDonation) async throws -> Void

    private let bootstrap: PersistenceBootstrap
    private let sink: Sink?

    init(bootstrap: PersistenceBootstrap, sink: Sink?) {
        self.bootstrap = bootstrap
        self.sink = sink
    }

    /// Returns at once; the donation runs detached and its failure never reaches the add.
    /// An add for a Home that is no longer the ready one is not donated, because its list
    /// identifier would not resolve.
    func userAdded(_ titles: [String], householdID: UUID, listID: UUID) {
        guard let sink, !titles.isEmpty, case .ready(let ready) = bootstrap.state,
              ready.presentation.isActive, ready.householdID == householdID, ready.listID == listID else { return }
        let namespace = CatalogActionContext.namespace(for: ready, householdID: householdID, listID: listID)
        let listEntityID = CatalogActionContext.entityID(for: listID, namespace: namespace)
        let donations = titles.map { GroceryAddDonation(title: $0, listEntityID: listEntityID) }
        Task.detached(priority: .utility) {
            for donation in donations {
                do { try await sink(donation) } catch { SiriActionLog.failed("Add donation", error) }
            }
        }
    }

    /// The schema action, and so donation, needs iOS 27 and an Xcode 27 build.
    nonisolated static func systemSink(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Sink? {
        #if DEBUG
        guard !TestHostEnvironment.isActive(environment), environment["XCODE_RUNNING_FOR_PREVIEWS"] == nil else {
            return nil
        }
        #endif
        #if compiler(>=6.4)
        guard #available(iOS 27.0, *) else { return nil }
        return { try await AddSpokenGroceryIntent.donate($0) }
        #else
        return nil
        #endif
    }
}

extension CatalogAddResult {
    /// The catalog items a list add put on the list. Outcomes are not reported per entry,
    /// so an add in which any entry failed names none rather than guess which applied.
    func addedItemIDs(from token: CatalogAddToken) -> [UUID] {
        guard archivedCount == 0, ineligibleCount == 0, changedCount == 0, missingCount == 0 else { return [] }
        let renewed = token.entries.filter { $0.disposition == .needAgain }.count == renewedNeedIDs.count
        return token.entries.filter { $0.disposition == .add || ($0.disposition == .needAgain && renewed) }
            .map(\.itemID)
    }
}
