import CoreData
import SwiftUI

enum GroceryCatalogAddCompletion {
    case added(UUID)
    case focusExisting(UUID)
}

struct GroceryCatalogAddView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hapticFeedback) private var hapticFeedback
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.items()) private var items: FetchedResults<Item>
    @FetchRequest(fetchRequest: NavigationFetchRequests.needs()) private var needs: FetchedResults<Need>
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: NavigationFetchRequests.people()) private var people: FetchedResults<Person>
    @FetchRequest(fetchRequest: NavigationFetchRequests.lists()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @State private var searchText: String
    @State private var catalogEditor: CatalogEditSession?
    @State private var pendingCompletion: GroceryCatalogAddCompletion?
    @State private var errorMessage: String?
    @State private var personID: UUID?
    @State private var personSelectionWasChanged = false
    let scope: GroceryAddScope
    let onCompleted: (GroceryCatalogAddCompletion) -> Void
    let onOneTime: (String, UUID?) -> Void

    init(
        scope: GroceryAddScope,
        onCompleted: @escaping (GroceryCatalogAddCompletion) -> Void,
        onOneTime: @escaping (String, UUID?) -> Void
    ) {
        self.scope = scope
        self.onCompleted = onCompleted
        self.onOneTime = onOneTime
        _searchText = State(initialValue: scope.textFilter)
    }

    private var canonicalList: GroceryList? {
        GroceryRowScope.canonicalList(Array(lists), households: Array(households), selection: selection)
    }

    private var scopedItems: [Item] {
        GroceryRowScope.validItems(Array(items), canonicalList: canonicalList)
    }

    private var activeStores: [Store] {
        GroceryRowScope.validStores(Array(stores), canonicalList: canonicalList).filter { !$0.isArchived }
    }

    private var scopedPeople: [Person] {
        GroceryRowScope.validPeople(Array(people), canonicalList: canonicalList)
    }

    private var activePeople: [Person] { scopedPeople.filter { !$0.isArchived } }

    private var personSelectionValid: Bool {
        personID == nil || activePeople.contains(where: { $0.id == personID })
    }

    private var purchaseFilter: PurchaseFilter {
        PurchaseFilter(
            selectedStoreID: scope.selectedStoreID,
            includedStoreIDs: scope.includedStoreIDs,
            excludedStoreIDs: scope.excludedStoreIDs
        )
    }

    private var activeNeedsByItemID: [UUID: Need] {
        let active = GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList)
            .filter { !$0.archived && $0.kind == NeedKind.remembered.rawValue && $0.item != nil }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return Dictionary(grouping: active, by: { $0.item?.id ?? PersistenceModel.unsetID })
            .compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    private var eligibleItems: [Item] {
        let activeStoreIDs = Set(activeStores.map(\.id))
        return scopedItems.filter { item in
            guard !item.isArchived,
                  scope.categoryID == nil || item.category?.id == scope.categoryID,
                  !scope.urgentOnly || activeNeedsByItemID[item.id]?.urgency == NeedUrgency.urgent.rawValue
            else { return false }
            return purchaseFilter.matches(
                PurchaseRuleValue(
                    explicitStoreIDs: Set(item.stores?.map(\.id) ?? []),
                    anyStore: item.anyStore
                ),
                activeStoreIDs: activeStoreIDs
            )
        }
    }

    private var visibleItems: [Item] {
        eligibleItems
            .filter {
                CatalogProjection.textMatches($0.name, query: scope.textFilter) &&
                    CatalogProjection.textMatches($0.name, query: searchText)
            }
            .sorted(by: itemComesFirst)
    }

    private var normalizedSearch: String { CatalogProjection.normalizedName(searchText) }

    var body: some View {
        NavigationStack {
            List {
                if !activePeople.isEmpty || personID != nil {
                    Section("Person") {
                        Picker("For", selection: $personID) {
                            Text("No person").tag(UUID?.none)
                            ForEach(activePeople, id: \.objectID) { person in
                                Text(person.name).tag(Optional(person.id))
                            }
                            if let personID, !activePeople.contains(where: { $0.id == personID }) {
                                Text("Person unavailable").tag(Optional(personID))
                            }
                        }
                        .onChange(of: personID) { _, _ in
                            personSelectionWasChanged = true
                        }
                        .accessibilityIdentifier("shopping.grocery.catalogPerson")
                        if !personSelectionValid {
                            Text("This person is no longer available. Choose another person or No person.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .shoppingMultilineText()
                        }
                    }
                }
                if visibleItems.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .listRowBackground(Color.clear)
                } else {
                    Section("Catalog") {
                        ForEach(visibleItems, id: \.objectID) { item in
                            Button { select(item) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                    Text(summary(for: item))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                            .disabled(!personSelectionValid)
                            .accessibilityIdentifier("shopping.grocery.catalogResult.\(item.id.uuidString)")
                        }
                    }
                }
                Section("Other options") {
                    Button("Add New “\(displaySearch)”", systemImage: "plus") { createCatalogItem() }
                        .disabled(!canCreateNew || !personSelectionValid)
                        .accessibilityIdentifier("shopping.grocery.catalogAddNew")
                    Button("Add One-Time Item", systemImage: "1.circle") {
                        onOneTime(displaySearch, personID)
                        dismiss()
                    }
                    .disabled(!personSelectionValid)
                    .accessibilityIdentifier("shopping.grocery.addOneTime")
                }
            }
            .listStyle(.plain)
            .navigationTitle("Add from Catalog")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search catalog")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(item: $catalogEditor, onDismiss: finishPendingCompletion) { session in
                CatalogEditorView(
                    session: session,
                    allowsSaveWithoutAdding: false,
                    onSaved: { _ in }
                ) { result in
                    if let message = addSavedCatalogItem(result) {
                        return .failed(message)
                    }
                    return .completed
                }
            }
            .alert(
                "Couldn’t add item",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
    }

    private var displaySearch: String {
        searchText.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private var canCreateNew: Bool {
        !normalizedSearch.isEmpty &&
            CatalogProjection.textMatches(displaySearch, query: scope.textFilter)
    }

    private var addScopeConstraint: CatalogAddScopeConstraint {
        CatalogAddScopeConstraint(
            purchaseFilter: purchaseFilter,
            categoryID: scope.categoryID,
            textFilters: [scope.textFilter, searchText],
            urgentOnly: scope.urgentOnly,
            newNeedUrgency: scope.urgentOnly ? .urgent : .normal
        )
    }

    private func itemComesFirst(_ lhs: Item, _ rhs: Item) -> Bool {
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        return comparison == .orderedSame
            ? lhs.id.uuidString < rhs.id.uuidString
            : comparison == .orderedAscending
    }

    private func summary(for item: Item) -> String {
        let needState: String
        if let need = activeNeedsByItemID[item.id] {
            needState = need.carted ? "In cart" : "On grocery list"
        } else {
            needState = "Saved in Catalog"
        }
        let assigned = item.stores ?? []
        let storeLabels = activeStores.filter { assigned.contains($0) }.map(\.name)
        let storeSummary = CatalogSuggestionPurchaseSummary.text(
            anyStore: item.anyStore,
            savedStoreLabels: storeLabels,
            hasSavedStores: !assigned.isEmpty
        )
        return "\(item.category?.name ?? "Uncategorized") · \(storeSummary) · \(needState)"
    }

    private func select(_ item: Item) {
        guard let service, let householdID = scope.householdID, let listID = scope.listID else { return }
        let expectedNeed = activeNeedsByItemID[item.id]
        do {
            let result = try service.applyCatalogSuggestion(
                itemID: item.id,
                itemRevision: item.revision,
                expectedNeedID: expectedNeed?.id,
                expectedNeedRevision: expectedNeed?.revision,
                listID: listID,
                householdID: householdID,
                purchaseFilter: purchaseFilter,
                categoryID: scope.categoryID,
                textFilter: scope.textFilter,
                urgentOnly: scope.urgentOnly,
                renewCarted: false,
                personID: personID,
                applyPersonToFocusedNeed: personSelectionWasChanged
            )
            hapticFeedback.play(.success)
            complete(with: completion(for: result))
        } catch {
            errorMessage = CatalogErrorCopy.message(error)
        }
    }

    private func completion(for result: CatalogSuggestionSelectionResult) -> GroceryCatalogAddCompletion {
        switch result {
        case .added(let id), .renewed(let id): return .added(id)
        case .focusExisting(let id): return .focusExisting(id)
        }
    }

    private func createCatalogItem() {
        guard canCreateNew else { return }
        var contextualStoreIDs = scope.includedStoreIDs
        if let selectedStoreID = scope.selectedStoreID {
            contextualStoreIDs.insert(selectedStoreID)
        }
        contextualStoreIDs.subtract(scope.excludedStoreIDs)
        catalogEditor = CatalogEditSession(
            selection: selection,
            itemID: nil,
            values: CatalogItemValues(
                name: displaySearch,
                notes: "",
                categoryID: scope.categoryID,
                anyStore: contextualStoreIDs.isEmpty,
                storeIDs: contextualStoreIDs
            )
        )
    }

    private func addSavedCatalogItem(_ result: CatalogSaveResult) -> String? {
        guard let service, let householdID = scope.householdID, let listID = scope.listID else {
            return "The household is no longer available."
        }
        do {
            let preview = try service.captureCatalogAdd(
                itemIDs: [result.itemID],
                householdID: householdID,
                listID: listID,
                selectedStoreID: scope.selectedStoreID,
                scopeConstraint: addScopeConstraint
            )
            guard preview.needAgainCount == 0 else {
                return "This item is already in the cart. Choose it from the search results to view it."
            }
            let applied = try service.applyCatalogAdd(
                preview.token,
                renewCarted: false,
                scopeConstraint: addScopeConstraint,
                personID: personID
            )
            if let id = applied.addedNeedIDs.first {
                pendingCompletion = .added(id)
                return nil
            }
            if let id = applied.existingNeedIDs.first {
                pendingCompletion = .focusExisting(id)
                return nil
            }
            return CatalogAddCopy.result(applied)
        } catch {
            return CatalogErrorCopy.message(error)
        }
    }

    private func finishPendingCompletion() {
        guard let pendingCompletion else { return }
        self.pendingCompletion = nil
        complete(with: pendingCompletion)
    }

    private func complete(with completion: GroceryCatalogAddCompletion) {
        onCompleted(completion)
        dismiss()
    }
}

#Preview("Add from Catalog") {
    ShoppingPreviewHost(.populated) {
        GroceryCatalogAddView(
            scope: GroceryAddScope(
                householdID: nil,
                listID: nil,
                selectedStoreID: nil,
                selectedStoreName: nil
            ),
            onCompleted: { _ in },
            onOneTime: { _, _ in }
        )
    }
}
