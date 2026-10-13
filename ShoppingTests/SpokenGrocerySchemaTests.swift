#if compiler(>=6.4)
import AppIntents
import Foundation
import Testing
@testable import Shopping

@Suite("Siri grocery schema", .tags(.integration, .critical),
       .enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27))
@MainActor
struct SpokenGrocerySchemaTests {
    @Test func freeFormNameResolvesOnlyWhenActionRunsAndReturnsSavedNeedIdentity() async throws {
        guard #available(iOS 27.0, *) else { Issue.record("Siri schemas require iOS 27"); return }
        let (environment, context) = try await fixture()
        let id = try create("Milk", environment)
        let intent = AddSpokenGroceryIntent()
        intent.title = " milk "
        let dialogue = try await intent.prepare(context: context)
        #expect(dialogue.candidates.map(\.id) == [id])
        let first = try await dialogue.add(entityID: context.entityID(for: id))
        let snapshot = try #require(try await context.groceryNeeds(ids: [first.needID]).first)
        let entity = GroceryReminderEntity(snapshot: snapshot, context: context)
        #expect(first.added)
        #expect(entity.id == context.entityID(for: first.needID))
        #expect(entity.title == "Milk")
        #expect(entity.list.id == GroceryListEntity(context: context).id)
        #expect(!entity.isCompleted)
        let duplicate = try await intent.prepare(context: context)
        let repeated = try await duplicate.add(entityID: context.entityID(for: id))
        #expect(!repeated.added && repeated.needID == first.needID)
    }

    @Test func ambiguityCapturesEveryChoiceBeforePromptAndRejectsChangedRevision() async throws {
        guard #available(iOS 27.0, *) else { Issue.record("Siri schemas require iOS 27"); return }
        let (environment, context) = try await fixture()
        let oat = try create("Oat milk", environment)
        _ = try create("Almond milk", environment)
        let intent = AddSpokenGroceryIntent(); intent.title = "milk"
        let dialogue = try await intent.prepare(context: context)
        #expect(dialogue.candidates.count == 2)
        try environment.service.saveCatalogItem(itemID: oat, householdID: context.householdID,
            values: CatalogItemValues(name: "Changed milk", notes: "", categoryID: nil, anyStore: true, storeIDs: []))
        await #expect(throws: ShoppingActionError.scopeChanged) {
            try await dialogue.add(entityID: context.entityID(for: oat))
        }
        #expect(try environment.service.allActiveNeedIDs(householdID: context.householdID).isEmpty)
    }

    @Test func unknownNameCreatesOnlyScopedNavigationAndCancellationSavesNothing() async throws {
        guard #available(iOS 27.0, *) else { Issue.record("Siri schemas require iOS 27"); return }
        let (environment, context) = try await fixture()
        let intent = AddSpokenGroceryIntent(); intent.title = "Space pears"
        let dialogue = try await intent.prepare(context: context)
        #expect(dialogue.candidates.isEmpty)
        #expect(context.runtime.actions.pending == nil)
        try dialogue.createInApp()
        #expect(context.runtime.actions.pending?.destination == .createItem("Space pears"))
        #expect(context.runtime.actions.pending?.presentationID == context.ready.presentation.id)
        context.runtime.actions.cancel()
        #expect(try environment.service.allActiveNeedIDs(householdID: context.householdID).isEmpty)
        #expect(try await context.items().isEmpty)
    }

    @Test func explicitlySelectedOtherListIsRejectedWithoutCatalogMutation() async throws {
        guard #available(iOS 27.0, *) else { Issue.record("Siri schemas require iOS 27"); return }
        let (environment, context) = try await fixture()
        let (_, other) = try await fixture()
        _ = try create("Milk", environment)
        let intent = AddSpokenGroceryIntent(); intent.title = "Milk"
        intent.list = GroceryListEntity(context: other)
        await #expect(throws: ShoppingActionError.scopeChanged) { try await intent.prepare(context: context) }
        #expect(try environment.service.allActiveNeedIDs(householdID: context.householdID).isEmpty)
    }

    @Test func unsupportedReminderDetailsFailBeforeAnyAdd() async throws {
        guard #available(iOS 27.0, *) else { Issue.record("Siri schemas require iOS 27"); return }
        let (environment, context) = try await fixture()
        _ = try create("Milk", environment)
        let intent = AddSpokenGroceryIntent(); intent.title = "Milk"
        intent.dueDate = DateComponents(year: 2027, month: 1, day: 1)
        await #expect(throws: SpokenGroceryError.self) { try await intent.prepare(context: context) }
        intent.dueDate = nil; intent.note = AttributedString("Do not silently drop this")
        await #expect(throws: SpokenGroceryError.self) { try await intent.prepare(context: context) }
        intent.note = nil; intent.isFlagged = true
        await #expect(throws: SpokenGroceryError.self) { try await intent.prepare(context: context) }
        #expect(try environment.service.allActiveNeedIDs(householdID: context.householdID).isEmpty)
    }

    @Test func needQueriesRejectOtherHomeAndRetirementAndReturnCurrentNotes() async throws {
        guard #available(iOS 27.0, *) else { Issue.record("Siri schemas require iOS 27"); return }
        let (environment, context) = try await fixture()
        let id = try create("Milk", environment)
        let needID = try environment.service.addRememberedNeed(itemID: id, listID: context.listID,
                                                                quantity: 2, notes: "Keep cold", urgency: .urgent)
        let (_, other) = try await fixture()
        #expect(try await other.groceryNeeds(ids: [needID]).isEmpty)
        let need = try #require(try await context.groceryNeeds(ids: [needID]).first)
        #expect(need.notes == "Keep cold" && need.urgent)
        context.ready.presentation.retire()
        await #expect(throws: ShoppingActionError.scopeChanged) { try await context.groceryNeeds(ids: [needID]) }
    }

    private func fixture() async throws -> (ShoppingPreviewEnvironment, CatalogActionContext) {
        let environment = try ShoppingPreviewFixtures.make(.empty)
        let runtime = ShoppingApplicationRuntime(bootstrap: PersistenceBootstrap(preloadedPreviewEnvironment: environment))
        return try await (environment, CatalogActionContext(runtime: runtime, ready: runtime.ready()))
    }
    private func create(_ name: String, _ environment: ShoppingPreviewEnvironment) throws -> UUID {
        try environment.service.createCatalogItem(values: CatalogItemValues(name: name, notes: "", categoryID: nil,
            anyStore: true, storeIDs: []), householdID: environment.ids.householdID)
    }
}
#endif
