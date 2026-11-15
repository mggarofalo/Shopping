import CoreData
import Foundation
import Testing
@testable import Shopping

/// SHOPPING-282: in-app adds are donated to iOS; Siri runs, other Homes and test hosts are not.
@Suite("Grocery add donations", .tags(.integration))
@MainActor
struct GroceryAddDonorTests {
    @Test func eachInAppAddPathDonatesAndEditsOrCartMovesDoNot() throws {
        let environment = try ShoppingPreviewFixtures.make(.empty)
        let scope = GroceryAddScope(householdID: environment.ids.householdID, listID: environment.ids.listID,
                                    selectedStoreID: nil, selectedStoreName: nil)
        let needID = try environment.service.addOneTimeNeed(title: "Candles", listID: environment.ids.listID)
        let writer = environment.persistence.writer
        let editing = try writer.performAndWait {
            let need = try writer.fetch(Need.fetchRequest()).first { $0.id == needID }
            return GroceryEditorTarget(scope: scope, need: need)
        }

        #expect(PendingSavedNeed.catalogAdd(UUID(), scope: scope).donatesAdd)
        #expect(PendingSavedNeed.editorSave(UUID(), target: GroceryEditorTarget(scope: scope, need: nil),
                                            savedCategoryID: nil, expectsUncarted: true).donatesAdd)
        #expect(PendingSavedNeed.needAgain(UUID(), scope: scope, savedCategoryID: nil, addedToList: true).donatesAdd)

        #expect(editing.needID == needID)
        let edit = PendingSavedNeed.editorSave(needID, target: editing, savedCategoryID: nil, expectsUncarted: true)
        #expect(edit.wasEditing && !edit.donatesAdd)
        #expect(!PendingSavedNeed.needAgain(needID, scope: scope, savedCategoryID: nil, addedToList: false).donatesAdd)
        #expect(!PendingSavedNeed.uncarted(needID, scope: scope).donatesAdd)
    }

    @Test func addsFromASiriHandoffAreNotDonated() throws {
        let navigation = GroceryNavigationState(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        navigation.requestSystemAction(.addItem)
        #expect(navigation.systemAddScope(householdID: nil, listID: nil).origin == .app)
        navigation.requestSystemAction(.createItem("Ground beef"))
        let handoff = navigation.systemAddScope(householdID: UUID(), listID: UUID())
        #expect(handoff.origin == .systemCreation)
        #expect(!PendingSavedNeed.catalogAdd(UUID(), scope: handoff).donatesAdd)
        // "Add as one-time" in that sheet opens the editor with the same scope.
        #expect(!PendingSavedNeed.editorSave(UUID(), target: GroceryEditorTarget(scope: handoff, need: nil),
                                             savedCategoryID: nil, expectsUncarted: true).donatesAdd)
    }

    @Test func donationNamesTheListSiriResolvesOffTheMainThread() async throws {
        let recorder = DonationRecorder()
        let (environment, runtime) = try await fixture(recorder.sink)
        runtime.donations.userAdded(["Milk", "Café au lait"], householdID: environment.ids.householdID,
                                    listID: environment.ids.listID)
        let donated = await recorder.records(atLeast: 2)
        let context = try await CatalogActionContext(runtime: runtime, ready: runtime.ready())
        let listID = context.entityID(for: context.listID)
        #expect(donated.map(\.donation) == [GroceryAddDonation(title: "Milk", listEntityID: listID),
                                            GroceryAddDonation(title: "Café au lait", listEntityID: listID)])
        #expect(donated.allSatisfy { !$0.onMainThread })
    }

    @Test func donationNeverWaitsForOrFailsTheAdd() async throws {
        let gate = DonationGate()
        let recorder = DonationRecorder()
        let (environment, runtime) = try await fixture { donation in
            await gate.wait()
            if donation.title == "Milk" { throw CancellationError() }
            try await recorder.sink(donation)
        }
        runtime.donations.userAdded(["Milk", "Bread"], householdID: environment.ids.householdID,
                                    listID: environment.ids.listID)
        // userAdded has returned while the sink is still suspended.
        #expect(await recorder.current.isEmpty)
        await gate.open()
        #expect(await recorder.records(atLeast: 1).map(\.donation.title) == ["Bread"])
    }

    @Test func addsForAnotherHomeOrWithoutNamesAreNotDonated() async throws {
        let recorder = DonationRecorder()
        let (environment, runtime) = try await fixture(recorder.sink)
        runtime.donations.userAdded(["Milk"], householdID: UUID(), listID: environment.ids.listID)
        runtime.donations.userAdded([], householdID: environment.ids.householdID, listID: environment.ids.listID)
        runtime.donations.userAdded(["Rice"], householdID: environment.ids.householdID, listID: environment.ids.listID)
        #expect(await recorder.records(atLeast: 1).map(\.donation.title) == ["Rice"])
    }

    @Test func siriAddsAreNotDonated() async throws {
        let recorder = DonationRecorder()
        let (environment, runtime) = try await fixture(recorder.sink)
        _ = try environment.service.createCatalogItem(values: CatalogItemValues(
            name: "Rice", notes: "", categoryID: nil, anyStore: true, storeIDs: []),
            householdID: environment.ids.householdID)
        let context = try await CatalogActionContext(runtime: runtime, ready: runtime.ready())
        let dialogue = try await CatalogAddDialogue(context: context, name: "rice", entityID: nil)
        let candidate = try #require(dialogue.candidates.first)
        #expect(try await dialogue.add(entityID: context.entityID(for: candidate.id)).added)
        // The in-app donation after it shows the sink was live while the Siri add ran.
        runtime.donations.userAdded(["Bread"], householdID: environment.ids.householdID, listID: environment.ids.listID)
        #expect(await recorder.records(atLeast: 1).map(\.donation.title) == ["Bread"])
    }

    @Test func testHostsAndPreviewsNeverDonate() {
        for key in ["XCTestConfigurationFilePath", "SHOPPING_UI_TEST_STORE_PATH",
                    "SHOPPING_UI_TEST_PERSISTENCE_FAILURE", "XCODE_RUNNING_FOR_PREVIEWS"] {
            #expect(GroceryAddDonor.systemSink(environment: [key: "1"]) == nil, "\(key)")
        }
        // This process is a test host, so the shared runtime's default sink is off too.
        #expect(GroceryAddDonor.systemSink() == nil)
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { #expect(GroceryAddDonor.systemSink(environment: [:]) != nil) }
        #else
        #expect(GroceryAddDonor.systemSink(environment: [:]) == nil)
        #endif
    }

    @Test func catalogAddNamesOnlyItemsItPutOnTheList() {
        let token = CatalogAddToken(id: UUID(), householdID: UUID(), listID: UUID(), selectedStoreID: nil,
                                    entries: [entry(.add), entry(.needAgain), entry(.focusExisting)])
        let ids = token.entries.map(\.itemID)
        #expect(result(added: 1, renewed: 1).addedItemIDs(from: token) == [ids[0], ids[1]])
        // Without renewing, a carted item stays in the cart.
        #expect(result(added: 1, renewed: 0).addedItemIDs(from: token) == [ids[0]])
        // Outcomes are not per entry, so a partly failed add names nothing.
        #expect(result(added: 1, renewed: 1, changed: 1).addedItemIDs(from: token).isEmpty)
    }

    private func fixture(_ sink: @escaping GroceryAddDonor.Sink) async throws
        -> (ShoppingPreviewEnvironment, ShoppingApplicationRuntime) {
        let environment = try ShoppingPreviewFixtures.make(.empty)
        let runtime = ShoppingApplicationRuntime(
            bootstrap: PersistenceBootstrap(preloadedPreviewEnvironment: environment), donationSink: sink)
        _ = try await runtime.ready()
        return (environment, runtime)
    }

    private func entry(_ disposition: CatalogAddDisposition) -> CatalogAddEntry {
        CatalogAddEntry(itemID: UUID(), itemRevision: 1, needID: nil, needRevision: nil, disposition: disposition)
    }

    private func result(added: Int, renewed: Int, changed: Int = 0) -> CatalogAddResult {
        CatalogAddResult(addedNeedIDs: (0..<added).map { _ in UUID() }, existingNeedIDs: [UUID()],
                         renewedNeedIDs: (0..<renewed).map { _ in UUID() }, archivedCount: 0,
                         ineligibleCount: 0, changedCount: changed, missingCount: 0)
    }
}

private actor DonationRecorder {
    struct Record { let donation: GroceryAddDonation; let onMainThread: Bool }
    private(set) var current: [Record] = []

    nonisolated var sink: GroceryAddDonor.Sink {
        { donation in await self.append(Record(donation: donation, onMainThread: pthread_main_np() != 0)) }
    }

    private func append(_ record: Record) { current.append(record) }

    /// Waits, boundedly, for `count` donations, then briefly for an unexpected extra one.
    func records(atLeast count: Int) async -> [Record] {
        for _ in 0..<500 where current.count < count { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(100))
        return current
    }
}

private actor DonationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
