import Foundation
import Testing
@testable import Shopping

extension Tag {
    @Tag static var critical: Self
    @Tag static var integration: Self
    @Tag static var persistence: Self
    @Tag static var unit: Self
}

@Suite("Catalog filter logic", .tags(.unit, .critical))
struct CatalogFilterUnitTests {
    @Test("Purchase rules retain store eligibility and filter narrowing")
    func independentPurchaseRuleMatrix() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let active: Set<UUID> = [a, b, c]
        struct Case {
            let value: PurchaseRuleValue
            let selected: UUID?
            let include: Set<UUID>
            let exclude: Set<UUID>
            let expectedAvailability: PurchaseAvailability
            let expectedMatch: Bool
        }
        let cases = [
            Case(value: .init(explicitStoreIDs: [a], anyStore: false), selected: a, include: [], exclude: [], expectedAvailability: .mustBuyHere, expectedMatch: true),
            Case(value: .init(explicitStoreIDs: [a], anyStore: false), selected: b, include: [], exclude: [], expectedAvailability: .unavailable, expectedMatch: false),
            Case(value: .init(explicitStoreIDs: [a, b], anyStore: false), selected: a, include: [], exclude: [], expectedAvailability: .flexibleHere, expectedMatch: true),
            Case(value: .init(explicitStoreIDs: [], anyStore: true), selected: c, include: [], exclude: [], expectedAvailability: .flexibleHere, expectedMatch: true),
            Case(value: .init(explicitStoreIDs: [a], anyStore: true), selected: b, include: [a], exclude: [], expectedAvailability: .flexibleHere, expectedMatch: true),
            Case(value: .init(explicitStoreIDs: [], anyStore: false), selected: nil, include: [], exclude: [], expectedAvailability: .unavailable, expectedMatch: true),
            Case(value: .init(explicitStoreIDs: [], anyStore: false), selected: a, include: [], exclude: [], expectedAvailability: .flexibleHere, expectedMatch: true),
            Case(value: .init(explicitStoreIDs: [], anyStore: false), selected: a, include: [a], exclude: [], expectedAvailability: .flexibleHere, expectedMatch: false),
            Case(value: .init(explicitStoreIDs: [], anyStore: false), selected: a, include: [], exclude: [a], expectedAvailability: .flexibleHere, expectedMatch: true),
            Case(value: .init(explicitStoreIDs: [a, b], anyStore: false), selected: a, include: [b], exclude: [], expectedAvailability: .flexibleHere, expectedMatch: true),
            Case(value: .init(explicitStoreIDs: [a, b], anyStore: false), selected: a, include: [c], exclude: [], expectedAvailability: .flexibleHere, expectedMatch: false),
            Case(value: .init(explicitStoreIDs: [a, b], anyStore: false), selected: a, include: [], exclude: [b], expectedAvailability: .flexibleHere, expectedMatch: false),
            Case(value: .init(explicitStoreIDs: [a], anyStore: false), selected: a, include: [a], exclude: [a], expectedAvailability: .mustBuyHere, expectedMatch: false),
            Case(value: .init(explicitStoreIDs: [], anyStore: true), selected: a, include: [], exclude: [a], expectedAvailability: .flexibleHere, expectedMatch: true),
            Case(value: .init(explicitStoreIDs: [], anyStore: true), selected: a, include: [a], exclude: [], expectedAvailability: .flexibleHere, expectedMatch: false),
            Case(value: .init(explicitStoreIDs: [a], anyStore: true), selected: b, include: [b], exclude: [], expectedAvailability: .flexibleHere, expectedMatch: false),
            Case(value: .init(explicitStoreIDs: [a], anyStore: false), selected: b, include: [a], exclude: [], expectedAvailability: .unavailable, expectedMatch: false)
        ]

        for (index, testCase) in cases.enumerated() {
            let filter = PurchaseFilter(
                selectedStoreID: testCase.selected,
                includedStoreIDs: testCase.include,
                excludedStoreIDs: testCase.exclude
            )
            #expect(
                filter.matches(testCase.value, activeStoreIDs: active) == testCase.expectedMatch,
                "case \(index)"
            )
            #expect(
                filter.availability(
                    of: testCase.value,
                    selectedStoreID: testCase.selected,
                    activeStoreIDs: active
                ) == testCase.expectedAvailability,
                "case \(index)"
            )
        }

        let activeWithoutB: Set<UUID> = [a, c]
        let retained = PurchaseRuleValue(explicitStoreIDs: [a, b], anyStore: false)
        #expect(PurchaseFilter().availability(of: retained, selectedStoreID: a, activeStoreIDs: activeWithoutB) == .mustBuyHere)
        #expect(PurchaseFilter().availability(of: retained, selectedStoreID: b, activeStoreIDs: activeWithoutB) == .unavailable)
        #expect(PurchaseFilter().availability(
            of: .init(explicitStoreIDs: [b], anyStore: false),
            selectedStoreID: nil,
            activeStoreIDs: activeWithoutB
        ) == .needsStore)
    }

    @Test("One-time rules use generic purchase filtering")
    func genericRuleValueCoversOneTimeRulesWithoutCatalogIdentity() {
        let a = UUID()
        let b = UUID()
        let oneTime = PurchaseRuleValue(explicitStoreIDs: [a], anyStore: false)
        #expect(PurchaseFilter().availability(of: oneTime, selectedStoreID: a, activeStoreIDs: [a, b]) == .mustBuyHere)
        #expect(!PurchaseFilter(selectedStoreID: b).matches(oneTime, activeStoreIDs: [a, b]))
        let untagged = PurchaseRuleValue(explicitStoreIDs: [], anyStore: false)
        #expect(PurchaseFilter().availability(of: untagged, selectedStoreID: a, activeStoreIDs: [a, b]) == .flexibleHere)
        #expect(PurchaseFilter(requiresAnyStore: true).matches(untagged, activeStoreIDs: [a, b]))
        #expect(!PurchaseFilter(requiresAnyStore: false).matches(untagged, activeStoreIDs: [a, b]))
    }

    @Test("Filter sanitization drops inactive scope")
    func groceryFilterSanitizationDropsInactiveScopeAndPreservesOtherCriteria() {
        let activeStore = UUID()
        let archivedStore = UUID()
        let activeCategory = UUID()
        let removedCategory = UUID()
        let filter = GroceryNeedFilter(
            purchase: PurchaseFilter(
                selectedStoreID: archivedStore,
                includedStoreIDs: [activeStore, archivedStore],
                excludedStoreIDs: [activeStore, archivedStore],
                requiresAnyStore: false
            ),
            text: "berries",
            categoryID: removedCategory,
            carted: true,
            urgency: NeedUrgency.urgent.rawValue
        )

        let sanitized = filter.sanitized(
            activeStoreIDs: [activeStore], activeCategoryIDs: [activeCategory])

        #expect(sanitized.purchase.selectedStoreID == nil)
        #expect(sanitized.purchase.includedStoreIDs == [activeStore])
        #expect(sanitized.purchase.excludedStoreIDs == [activeStore])
        #expect(sanitized.purchase.requiresAnyStore == false)
        #expect(sanitized.text == "berries")
        #expect(sanitized.categoryID == nil)
        #expect(sanitized.carted == true)
        #expect(sanitized.urgency == NeedUrgency.urgent.rawValue)
    }
}

@MainActor
@Suite("Grocery navigation state", .tags(.unit, .critical))
struct GroceryNavigationUnitTests {
    @Test("Selecting All clears only the store projection")
    func selectingAllClearsOnlyStoreProjection() throws {
        let suiteName = "GroceryNavigationUnitTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let householdID = UUID()
        let storeID = UUID()
        let includedID = UUID()
        let state = GroceryNavigationState(defaults: defaults, keyPrefix: "test.filter")
        state.configure(householdID: householdID, activeStoreIDs: [storeID, includedID])
        state.selectStore(storeID)
        state.setIncluded(true, storeID: includedID)

        state.selectAll()

        #expect(state.selectedStoreID == nil)
        #expect(state.includedStoreIDs == [includedID])
    }

    @Test("Need focus switches tabs and is consumed only by its owner")
    func requestedNeedFocusIsConsumedByMatchingNeed() throws {
        let suiteName = "GroceryNavigationUnitTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = GroceryNavigationState(
            defaults: defaults,
            keyPrefix: "test.filter"
        )
        let requestedID = UUID()
        state.selectedTab = .settings

        state.requestNeedFocus(requestedID)
        #expect(state.selectedTab == .groceries)
        #expect(state.pendingNeedFocusID == requestedID)

        state.consumeNeedFocus(UUID())
        #expect(state.pendingNeedFocusID == requestedID)
        state.consumeNeedFocus(requestedID)
        #expect(state.pendingNeedFocusID == nil)
    }

    @Test("Add errors explain recovery")
    func addErrorsExplainRecovery() {
        #expect(
            GroceryAddError.householdUnavailable.errorDescription ==
                "This household is not available yet. Try again when loading finishes."
        )
        #expect(
            GroceryAddError.selectionChanged.errorDescription ==
                "The selected household changed. Close this draft and add the grocery again."
        )
    }
}
