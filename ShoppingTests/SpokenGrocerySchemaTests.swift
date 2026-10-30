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

    /// SHOPPING-271: the re-run Siri sends after a handoff is refused before any prompt,
    /// and queues nothing behind the editor the first request opened.
    @Test func repeatedUnknownNameHandoffIsRefusedBeforePrompting() async throws {
        guard #available(iOS 27.0, *) else { Issue.record("Siri schemas require iOS 27"); return }
        let (_, context) = try await fixture()
        let intent = AddSpokenGroceryIntent(); intent.title = "Space pears"
        let first = try await intent.prepare(context: context)
        try first.rejectRepeatedCreation()
        try first.createInApp()
        #expect(try context.runtime.actions.take(presentationID: context.ready.presentation.id) == .createItem("Space pears"))
        intent.title = "space pears"
        let rerun = try await intent.prepare(context: context)
        #expect(throws: ShoppingActionError.creationOpen) { try rerun.rejectRepeatedCreation() }
        #expect(throws: ShoppingActionError.creationOpen) { try rerun.createInApp() }
        #expect(context.runtime.actions.pending == nil)
        context.runtime.actions.creationClosed()
        try rerun.rejectRepeatedCreation()
    }

    @Test func spokenOneTimeNameAlreadyOnListResolvesToThatNeed() async throws {
        guard #available(iOS 27.0, *) else { Issue.record("Siri schemas require iOS 27"); return }
        let (environment, context) = try await fixture()
        let needID = try environment.service.addOneTimeNeed(title: "Shaving cream", listID: context.listID)
        let intent = AddSpokenGroceryIntent(); intent.title = "shaving cream"
        let dialogue = try await intent.prepare(context: context)
        let need = try #require(dialogue.existingOneTime)
        let entity = GroceryReminderEntity(snapshot: need, context: context)
        #expect(entity.id == context.entityID(for: needID))
        #expect(entity.title == "Shaving cream")
        #expect(context.runtime.actions.pending == nil)
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

    @Test func unsupportedReminderDetailsAreRejected() async throws {
        guard #available(iOS 27.0, *) else { Issue.record("Siri schemas require iOS 27"); return }
        let intent = AddSpokenGroceryIntent(); intent.title = "Milk"
        #expect(throws: Never.self) { try intent.rejectUnsupportedDetails() }
        intent.note = AttributedString("Do not silently drop this")
        #expect(throws: SpokenGroceryError.unsupportedDetails) { try intent.rejectUnsupportedDetails() }
        intent.note = nil; intent.isFlagged = true
        #expect(throws: SpokenGroceryError.unsupportedDetails) { try intent.rejectUnsupportedDetails() }
        intent.isFlagged = nil; intent.tags = ["errands"]
        #expect(throws: SpokenGroceryError.unsupportedDetails) { try intent.rejectUnsupportedDetails() }
    }

    /// SHOPPING-270: "Remind me at 9 am to call mom" can be routed here. A time or
    /// repeat is declined as a scheduled reminder, even when other details came too.
    @Test func timedOrRepeatingReminderIsDeclinedAsScheduled() async throws {
        guard #available(iOS 27.0, *) else { Issue.record("Siri schemas require iOS 27"); return }
        let intent = AddSpokenGroceryIntent(); intent.title = "call mom"
        intent.dueDate = DateComponents(hour: 9, minute: 0)
        #expect(throws: SpokenGroceryError.scheduledReminder) { try intent.rejectUnsupportedDetails() }
        intent.note = AttributedString("Ask about Sunday")
        #expect(throws: SpokenGroceryError.scheduledReminder) { try intent.rejectUnsupportedDetails() }
        intent.dueDate = nil; intent.note = nil
        intent.recurrence = Calendar.RecurrenceRule.daily(calendar: .current)
        #expect(throws: SpokenGroceryError.scheduledReminder) { try intent.rejectUnsupportedDetails() }
        let message = try #require(SpokenGroceryError.scheduledReminder.errorDescription)
        #expect(message.contains("can’t set timed or location reminders") && message.contains("choose Reminders"))
    }

    /// The action itself, not only the check, surfaces the scheduled decline. That the
    /// check precedes store readiness is shown by `perform()`'s order, not by this test.
    @Test func timedReminderPerformIsDeclinedAsScheduled() async throws {
        guard #available(iOS 27.0, *) else { Issue.record("Siri schemas require iOS 27"); return }
        let intent = AddSpokenGroceryIntent(); intent.title = "call mom"
        intent.dueDate = DateComponents(hour: 9, minute: 0)
        await #expect(throws: SpokenGroceryError.scheduledReminder) { _ = try await intent.perform() }
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
