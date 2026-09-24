import CoreData
import XCTest
@testable import Shopping

final class PersonalCartPresentationTests: XCTestCase {
    private struct FixedSession: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }

    @MainActor
    func testColdPresentationKeepsPrivateCleanupAndHistoryWhenSharedReceiptIsIncomplete() throws {
        let persistence = try PersistenceController(inMemory: true)
        let needs = NeedService(persistence: persistence)
        let scope = try needs.createHousehold()
        let milkItem = try needs.createItem(name: "Milk", householdID: scope.householdID)
        let breadItem = try needs.createItem(name: "Bread", householdID: scope.householdID)
        let milk = try needs.addRememberedNeed(itemID: milkItem, listID: scope.listID, householdID: scope.householdID)
        let bread = try needs.addRememberedNeed(itemID: breadItem, listID: scope.listID, householdID: scope.householdID)
        let provider = FixedSession(session: try ShopperSession.authenticated(
            containerIdentifier: "iCloud.shopping.presentation-tests", environment: "Development", accountRecordName: "alice"))
        let service = PersonalCartService(persistence: persistence, sessionProvider: provider)
        for needID in [milk, bread] {
            try service.cart(needID: needID, householdID: scope.householdID, listID: scope.listID)
        }
        let breadEntry = try XCTUnwrap(service.entries(householdID: scope.householdID, listID: scope.listID)
            .first { $0.needID == bread })
        let checkout = try service.prepareCheckout(tokens: [breadEntry.token])
        _ = try service.checkout(checkout, operationID: checkout.id)

        // Simulate a partial incoming household record, not a locally authorized command.
        let incoming = persistence.simulationContext()
        try incoming.performAndWait {
            let request = NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord")
            request.predicate = NSPredicate(format: "kind == %@", "purchase")
            let receipt = try XCTUnwrap(incoming.fetch(request).first)
            receipt.payload = nil
            try incoming.save()
        }

        let presentation = PersonalCartPresentation(service: service, householdID: scope.householdID, listID: scope.listID)
        XCTAssertEqual(presentation.entries.map(\.needID), [milk])
        XCTAssertEqual(presentation.history.map(\.id), [checkout.id])
        XCTAssertNotNil(presentation.error)
        XCTAssertTrue(presentation.outstandingNeedIDs.isEmpty)
        XCTAssertTrue(presentation.presence.isEmpty)
        try presentation.uncart(XCTUnwrap(presentation.entries.first))
        XCTAssertTrue(presentation.entries.isEmpty)
        XCTAssertEqual(presentation.history.map(\.id), [checkout.id])
    }
}
