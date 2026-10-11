import CoreData
import Foundation
import Testing
@testable import Shopping

@Suite("Catalog system actions", .tags(.integration, .critical))
@MainActor
struct CatalogActionTests {
    @Test func exactNamesOutrankSubstringWithoutGuessingDuplicateMatches() {
        let exact = item("Milk"), duplicate = item("ＭÍＬＫ"), partial = item("Oat milk")
        #expect(CatalogActionMatcher.matches("  milk\n", in: [partial, exact]) == [exact])
        #expect(Set(CatalogActionMatcher.matches("milk", in: [partial, exact, duplicate]).map(\.id)) == [exact.id, duplicate.id])
        #expect(CatalogActionMatcher.matches("oat", in: [partial, exact]) == [partial])
        #expect(CatalogActionMatcher.matches(" \n", in: [exact]).isEmpty)
        #expect(CatalogActionMatcher.matches("bread and milk", in: [exact]).isEmpty)
    }

    @Test func catalogSnapshotExcludesOneTimeAndArchivedItems() async throws {
        let (environment, context) = try await fixture()
        let kept = try create("Rice", in: environment)
        let archived = try create("Old rice", in: environment)
        try environment.service.setCatalogItemArchived(itemID: archived, householdID: context.householdID, archived: true)
        _ = try environment.service.addOneTimeNeed(title: "Party rice", listID: context.listID)
        let items = try await context.items()
        #expect(items.map(\.id) == [kept])
        #expect(items.first?.name == "Rice")
    }

    @Test func addIsDurableAndRepeatedAddPreservesNeedMetadataAndRules() async throws {
        let (environment, context) = try await fixture()
        let store = try environment.service.createStore(name: "Corner shop", householdID: context.householdID)
        let id = try environment.service.createCatalogItem(values: CatalogItemValues(
            name: "Rice", notes: "Brown", categoryID: nil, anyStore: false, storeIDs: [store]), householdID: context.householdID)
        let items = try await context.items()
        #expect(items.first?.purchaseRules == "Corner shop")
        let first = try await context.capture(items)
        #expect(try await context.add(itemID: id, using: first))
        let second = try await context.capture(try await context.items())
        #expect(!(try await context.add(itemID: id, using: second)))
        let state = try environment.persistence.writer.performAndWait {
            let needs = try environment.persistence.writer.fetch(Need.fetchRequest())
            let need = try #require(needs.first)
            return (needs.count, need.item?.stores?.map(\.id), need.notes, need.urgency)
        }
        #expect(state.0 == 1)
        #expect(state.1 == [store])
        #expect(state.2 == "Brown")
        #expect(state.3 == NeedUrgency.normal.rawValue)
    }

    @Test func existingCartedNeedIsNotRenewedOrEdited() async throws {
        let (environment, context) = try await fixture()
        let id = try create("Milk", in: environment)
        let needID = try environment.service.addRememberedNeed(itemID: id, listID: context.listID,
            quantity: 4, notes: "Keep", urgency: .urgent)
        try environment.service.setCarted(true, needID: needID)
        let token = try await context.capture(try await context.items())
        #expect(token.entries.first?.disposition == .needAgain)
        #expect(!(try await context.add(itemID: id, using: token)))
        let state = try environment.persistence.writer.performAndWait {
            let need = try #require(environment.persistence.writer.fetch(Need.fetchRequest()).first)
            return (need.carted, need.quantity, need.notes, need.urgency)
        }
        #expect(state.0 && state.1 == 4 && state.2 == "Keep" && state.3 == NeedUrgency.urgent.rawValue)
    }

    @Test func changesDuringDisambiguationRejectCapturedAdd() async throws {
        let (environment, context) = try await fixture()
        let id = try create("Milk", in: environment)
        let items = try await context.items()
        let token = try await context.capture(items)
        try environment.service.saveCatalogItem(itemID: id, householdID: context.householdID,
            values: CatalogItemValues(name: "Oat milk", notes: "", categoryID: nil, anyStore: true, storeIDs: []))
        await #expect(throws: ShoppingActionError.scopeChanged) { try await context.add(itemID: id, using: token) }
        await #expect(throws: ShoppingActionError.scopeChanged) { try await context.capture(items) }
        #expect(try environment.service.allActiveNeedIDs(householdID: context.householdID).isEmpty)
    }

    @Test func retiredScopeRejectsReadWriteAndHandoff() async throws {
        let (environment, context) = try await fixture()
        let id = try create("Milk", in: environment)
        let token = try await context.capture(try await context.items())
        context.ready.presentation.retire()
        await #expect(throws: ShoppingActionError.scopeChanged) { try await context.items() }
        await #expect(throws: ShoppingActionError.scopeChanged) { try await context.add(itemID: id, using: token) }
        #expect(throws: ShoppingActionError.scopeChanged) { try context.createInApp(name: "Bread") }
        #expect(context.runtime.actions.pending == nil)
    }

    @Test func entityIdentityCannotTransferAcrossHomes() async throws {
        let (_, first) = try await fixture()
        let (_, second) = try await fixture()
        let id = UUID()
        #expect(first.entityID(for: id) != second.entityID(for: id))
    }

    @Test func newItemHandoffAndCancellationCreateNoRecords() async throws {
        let (_, context) = try await fixture()
        try context.createInApp(name: "New rice")
        #expect(context.runtime.actions.pending?.destination == .createItem("New rice"))
        #expect(context.runtime.actions.pending?.presentationID == context.ready.presentation.id)
        context.runtime.actions.cancel()
        #expect(try await context.items().isEmpty)
        #expect(try context.ready.service.allActiveNeedIDs(householdID: context.householdID).isEmpty)
    }

    @Test func scopedServiceRejectsRetiredReadEvenWithoutCoordinator() throws {
        let environment = try ShoppingPreviewFixtures.make(.empty)
        let authority = UICommandAuthority()
        let service = environment.service.scoped(to: authority)
        authority.retire()
        #expect(throws: UICommandAuthority.Failure.retired) {
            try service.catalogActionItems(householdID: environment.ids.householdID, listID: environment.ids.listID)
        }
    }

    @Test func cancelledDialogueCannotDispatchAnAddOrEditor() async throws {
        let (environment, context) = try await fixture()
        let id = try create("Milk", in: environment)
        let token = try await context.capture(try await context.items())
        let action = Task { @MainActor in try await context.add(itemID: id, using: token) }
        action.cancel()
        await #expect(throws: CancellationError.self) { try await action.value }
        let handoff = Task { @MainActor in try context.createInApp(name: "Rice") }
        handoff.cancel()
        await #expect(throws: CancellationError.self) { try await handoff.value }
        #expect(context.runtime.actions.pending == nil)
        #expect(try environment.service.allActiveNeedIDs(householdID: context.householdID).isEmpty)
    }

    @Test func permissionFailureCannotReportSuccessOrLeaveANeed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Shopping.sqlite")
        let ids: ShoppingPreviewIDs
        let itemID: UUID
        do {
            let environment = try ShoppingPreviewFixtures.make(.empty, storeURL: url)
            ids = environment.ids
            itemID = try create("Rice", in: environment)
        }
        let persistence = try PersistenceController(configuration: .local(storeURL: url),
                                                    permissionPolicy: DenyPersistencePermissionPolicy())
        let service = NeedService(persistence: persistence)
        let environment = ShoppingPreviewEnvironment(persistence: persistence, service: service, ids: ids)
        let runtime = ShoppingApplicationRuntime(bootstrap: PersistenceBootstrap(preloadedPreviewEnvironment: environment))
        let context = try await CatalogActionContext(runtime: runtime, ready: runtime.ready())
        let token = try await context.capture(try await context.items())
        await #expect(throws: PersistencePermissionError.updateDenied) {
            try await context.add(itemID: itemID, using: token)
        }
        #expect(try service.allActiveNeedIDs(householdID: ids.householdID).isEmpty)
        #expect(try await context.items().map(\.id) == [itemID])
    }

    private func fixture() async throws -> (ShoppingPreviewEnvironment, CatalogActionContext) {
        let environment = try ShoppingPreviewFixtures.make(.empty)
        let runtime = ShoppingApplicationRuntime(bootstrap: PersistenceBootstrap(preloadedPreviewEnvironment: environment))
        return try await (environment, CatalogActionContext(runtime: runtime, ready: runtime.ready()))
    }

    private func create(_ name: String, in environment: ShoppingPreviewEnvironment) throws -> UUID {
        try environment.service.createCatalogItem(values: CatalogItemValues(
            name: name, notes: "", categoryID: nil, anyStore: true, storeIDs: []), householdID: environment.ids.householdID)
    }

    private func item(_ name: String) -> CatalogActionItem {
        CatalogActionItem(id: UUID(), revision: 1, name: name, category: "Dairy", purchaseRules: "Any Store")
    }
}
