import CoreData
import XCTest
@testable import ShoppingWatch

@MainActor
final class PersistentWatchShoppingServiceTests: XCTestCase {
    struct Provider: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }
    struct Fixture {
        let directory: URL
        let persistence: PersistenceController
        let provider: Provider
        let cart: PersonalCartService
        let householdID: UUID
        let listID: UUID
        let storeID: UUID
        let otherStoreID: UUID
        let needID: UUID
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let persistence = try PersistenceController(storeURL: directory.appendingPathComponent("store.sqlite"))
        let provider = Provider(session: try ShopperSession.authenticated(containerIdentifier: "iCloud.shopping.watch-unit",
            environment: "Development", accountRecordName: "alice"))
        let householdID = UUID(), listID = UUID(), storeID = UUID(), otherStoreID = UUID(), needID = UUID()
        let context = persistence.container.viewContext
        try context.performAndWait {
            let household = Household(context: context); household.id = householdID; household.name = "Home"
            let list = GroceryList(context: context); list.id = listID; list.household = household
            for (id, name) in [(storeID, "Market"), (otherStoreID, "Other")] {
                let store = Store(context: context); store.id = id; store.name = name; store.household = household
            }
            let category = Category(context: context); category.id = UUID(); category.name = "Dairy"; category.household = household
            let item = Item(context: context); item.id = UUID(); item.name = "Milk"; item.notes = ""; item.anyStore = true
            item.household = household; item.category = category
            let need = Need(context: context); need.id = needID; need.title = "Milk"; need.notes = ""; need.quantity = 2
            need.kind = NeedKind.remembered.rawValue; need.urgency = NeedUrgency.normal.rawValue; need.item = item; need.list = list
            try persistence.prepareForSave(context); try context.save()
        }
        return Fixture(directory: directory, persistence: persistence, provider: provider,
            cart: PersonalCartService(persistence: persistence, sessionProvider: provider), householdID: householdID,
            listID: listID, storeID: storeID, otherStoreID: otherStoreID, needID: needID)
    }

    private func adapter(_ f: Fixture, writable: (@MainActor (UUID) -> Bool)? = nil) -> PersistentWatchShoppingService {
        PersistentWatchShoppingService(persistence: f.persistence, sessionProvider: f.provider,
            selectionURL: f.directory.appendingPathComponent("selection.json"), householdWritable: writable, cartService: f.cart)
    }

    func testOfflineDraftQuantityAndCheckoutIntentRecoverAfterSQLiteRelaunch() async throws {
        enum Injected: Error { case stop }
        let f = try fixture(), service = adapter(f)
        let initial = try await service.load(storeID: f.storeID)
        let row = try XCTUnwrap(initial.grocerySections.first?.items.first)
        let added = try await service.execute(.add(token: row.commandToken, quantity: 7))
        XCTAssertEqual(added.cartSections.first?.items.first?.quantity, 7)
        let preview = try await service.captureCheckout(storeID: f.storeID)
        f.cart.failurePoint = { if $0 == "afterIntent" { throw Injected.stop } }
        do { _ = try await service.checkout(token: preview.token); XCTFail("Expected interruption") } catch {}
        f.cart.failurePoint = nil
        let retry = try await service.checkout(token: preview.token)
        XCTAssertEqual(retry.id, preview.id)
        let persistence = try PersistenceController(storeURL: f.directory.appendingPathComponent("store.sqlite"))
        let reopened = PersistentWatchShoppingService(persistence: persistence, sessionProvider: f.provider,
            selectionURL: f.directory.appendingPathComponent("selection.json"))
        let snapshot = try await reopened.load(storeID: nil)
        XCTAssertEqual(snapshot.selectedStoreID, f.storeID)
        XCTAssertEqual(snapshot.recentCheckouts.map(\.id), [preview.id])
        XCTAssertEqual(snapshot.recentCheckouts.first?.storeName, "Market")
        XCTAssertTrue(snapshot.cartSections.isEmpty)
        let context = persistence.simulationContext()
        try context.performAndWait { XCTAssertEqual(try context.fetch(Need.fetchRequest()).first?.quantity, 2) }
    }

    func testStaleAddCannotIgnoreChangedStoreRule() async throws {
        let f = try fixture(), service = adapter(f)
        let before = try await service.load(storeID: f.storeID)
        let row = try XCTUnwrap(before.grocerySections.first?.items.first)
        let context = f.persistence.simulationContext()
        try context.performAndWait {
            let item = try XCTUnwrap(context.fetch(Item.fetchRequest()).first)
            item.anyStore = false
            item.stores = Set(try context.fetch(Store.fetchRequest()).filter { $0.id == f.otherStoreID })
            item.revision += 1
            try context.save()
        }
        do { _ = try await service.execute(.add(token: row.commandToken, quantity: 4)); XCTFail("Stale add must fail") } catch {}
        XCTAssertTrue(try f.cart.entries(householdID: f.householdID, listID: f.listID).isEmpty)
    }

    func testArchivedOnlyStoreEntryRemainsRemovableInAnotherStore() async throws {
        let f = try fixture(), service = adapter(f)
        try f.cart.cart(needID: f.needID, householdID: f.householdID, listID: f.listID)
        let context = f.persistence.simulationContext()
        try context.performAndWait {
            let item = try XCTUnwrap(context.fetch(Item.fetchRequest()).first)
            let store = try XCTUnwrap(context.fetch(Store.fetchRequest()).first { $0.id == f.storeID })
            item.anyStore = false; item.stores = [store]; store.isArchived = true
            try context.save()
        }
        let snapshot = try await service.load(storeID: f.otherStoreID)
        let row = try XCTUnwrap(snapshot.cartSections.first?.items.first)
        XCTAssertTrue(row.canRemove)
        XCTAssertNotNil(row.unavailableReason)
        XCTAssertFalse(snapshot.canCheckout)
        let removed = try await service.execute(.remove(token: row.commandToken))
        XCTAssertTrue(removed.cartSections.isEmpty)
    }

    func testBuyAnywayRetriesExactCaptureAndAcknowledgesOnlyDisplayedReceipts() async throws {
        enum Injected: Error { case stop }
        let f = try fixture()
        try f.cart.cart(needID: f.needID, householdID: f.householdID, listID: f.listID)
        let bob = Provider(session: try ShopperSession.authenticated(containerIdentifier: "iCloud.shopping.watch-unit",
            environment: "Development", accountRecordName: "bob"))
        let other = PersonalCartService(persistence: f.persistence, sessionProvider: bob)
        try other.cart(needID: f.needID, householdID: f.householdID, listID: f.listID)
        let theirs = try other.entries(householdID: f.householdID, listID: f.listID)
        _ = try other.checkout(other.prepareCheckout(tokens: theirs.map(\.token)))
        let service = adapter(f)
        let snapshot = try await service.load(storeID: f.storeID)
        let row = try XCTUnwrap(snapshot.cartSections.first?.items.first)
        XCTAssertTrue(row.canBuyAnyway)
        f.cart.failurePoint = { if $0 == "afterIntent" { throw Injected.stop } }
        do { _ = try await service.execute(.buyAnyway(token: row.commandToken)); XCTFail("Expected interruption") } catch {}
        f.cart.failurePoint = nil
        let recovered = try await service.execute(.buyAnyway(token: row.commandToken))
        XCTAssertTrue(recovered.cartSections.isEmpty)
        XCTAssertEqual(recovered.recentCheckouts.count, 1)
    }
    func testNewPurchaseAfterNoticeCaptureIsNotImplicitlyAcknowledged() async throws {
        let f = try fixture()
        try f.cart.cart(needID: f.needID, householdID: f.householdID, listID: f.listID)
        func purchase(_ name: String) throws {
            let provider = Provider(session: try ShopperSession.authenticated(containerIdentifier: "iCloud.shopping.watch-unit",
                environment: "Development", accountRecordName: name))
            let cart = PersonalCartService(persistence: f.persistence, sessionProvider: provider)
            try cart.cart(needID: f.needID, householdID: f.householdID, listID: f.listID)
            let entries = try cart.entries(householdID: f.householdID, listID: f.listID)
            let notices = Set(entries.flatMap(\.purchaseNotices).map(\.receiptID))
            _ = try cart.checkout(cart.prepareCheckout(tokens: entries.map(\.token)), buyAnywayReceiptIDs: notices)
        }
        try purchase("bob")
        let service = adapter(f)
        let snapshot = try await service.load(storeID: f.storeID)
        let row = try XCTUnwrap(snapshot.cartSections.first?.items.first)
        try purchase("charlie")
        do { _ = try await service.execute(.buyAnyway(token: row.commandToken)); XCTFail("New receipt requires new acknowledgement") }
        catch { XCTAssertEqual(error as? PersonalCartError, .purchasedNoticeRequired) }
        XCTAssertEqual(try f.cart.entries(householdID: f.householdID, listID: f.listID).count, 1)
    }

    func testSavedHouseholdDoesNotSwitchWhenAnotherHouseholdImports() async throws {
        let f = try fixture(), service = adapter(f)
        _ = try await service.load(storeID: f.storeID)
        let context = f.persistence.simulationContext()
        try context.performAndWait {
            let household = Household(context: context)
            household.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            household.name = "Other household"
            let list = GroceryList(context: context); list.id = UUID(); list.household = household
            try context.save()
        }
        let reopened = adapter(f)
        let snapshot = try await reopened.load(storeID: nil)
        XCTAssertEqual(snapshot.selectedStoreID, f.storeID)
        let row = try XCTUnwrap(snapshot.grocerySections.first?.items.first)
        let result = try await reopened.execute(.add(token: row.commandToken, quantity: 3))
        XCTAssertEqual(result.cartCount, 1)
    }

    func testObservedPermissionLossBlocksCapturedRestoreButAllowsOwnRemoval() async throws {
        let f = try fixture()
        var writable = true
        let service = adapter(f, writable: { _ in writable })
        let initial = try await service.load(storeID: f.storeID)
        let row = try XCTUnwrap(initial.grocerySections.first?.items.first)
        _ = try await service.execute(.add(token: row.commandToken, quantity: 2))
        let preview = try await service.captureCheckout(storeID: f.storeID)
        let result = try await service.checkout(token: preview.token)
        let recovery = try XCTUnwrap(result.snapshot.recentCheckouts.first)
        writable = false
        do { _ = try await service.restore(token: recovery.token); XCTFail("Revoked restore must fail") } catch {}
        XCTAssertFalse(try XCTUnwrap(f.cart.history(householdID: f.householdID, listID: f.listID).first).restored)
    }

    final class MutableProvider: ShopperSessionProviding, @unchecked Sendable {
        var value: ShopperSession
        init(_ value: ShopperSession) { self.value = value }
        func currentSession() throws -> ShopperSession { value }
    }

    func testAccountSwitchInvalidatesOldPartitionOnceAndNeverExposesItsCart() async throws {
        let f = try fixture()
        let provider = MutableProvider(f.provider.session)
        let service = PersistentWatchShoppingService(persistence: f.persistence, sessionProvider: provider)
        let initial = try await service.load(storeID: f.storeID)
        let row = try XCTUnwrap(initial.grocerySections.first?.items.first)
        _ = try await service.execute(.add(token: row.commandToken, quantity: 4))
        var invalidations = 0
        service.onChange = { if $0 == .authorityInvalidated { invalidations += 1 } }
        provider.value = try ShopperSession.authenticated(containerIdentifier: "iCloud.shopping.watch-unit",
            environment: "Development", accountRecordName: "bob")
        let switched = try await service.load(storeID: f.storeID)
        guard case .setupRequired = switched.availability else { return XCTFail("Old partition must require account setup") }
        XCTAssertTrue(switched.cartSections.isEmpty)
        _ = try await service.load(storeID: f.storeID)
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(try f.cart.entries(householdID: f.householdID, listID: f.listID).count, 1)
    }

}
