import CoreData
import SwiftUI

struct GroceryEditorTarget: Identifiable {
    let id = UUID()
    let scope: GroceryAddScope
    let need: Need?
    let needID: UUID?

    init(scope: GroceryAddScope, need: Need?) {
        self.scope = scope
        self.need = need
        self.needID = need?.id
    }
}

private struct RemovalTarget {
    let needID: UUID
    let revision: Int64
    let householdID: UUID
    let listID: UUID
    let name: String
}

struct GroceryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.items()) private var items: FetchedResults<Item>
    @FetchRequest(fetchRequest: NavigationFetchRequests.needs()) private var needs: FetchedResults<Need>
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories:
        FetchedResults<Category>
    @FetchRequest(fetchRequest: NavigationFetchRequests.lists()) private var lists:
        FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households:
        FetchedResults<Household>
    @State private var remembered: Bool
    @State private var name: String
    @State private var catalogNotes: String
    @State private var purchaseNotes: String
    @State private var quantity: Int
    @State private var urgency: NeedUrgency
    @State private var categoryID: UUID?
    @State private var storeIDs: Set<UUID>
    @State private var anyStore: Bool
    @State private var error: Error?
    @State private var allowDuplicate = false
    @State private var removal: RemovalTarget?
    let target: GroceryEditorTarget
    let onSaved: (UUID) -> Void
    let onFocusNeed: (Need) -> Void
    let onRemoved: (UUID, GroceryAddScope) -> Void

    init(
        target: GroceryEditorTarget, onSaved: @escaping (UUID) -> Void, onFocusNeed: @escaping (Need) -> Void,
        onRemoved: @escaping (UUID, GroceryAddScope) -> Void
    ) {
        self.target = target
        self.onSaved = onSaved
        self.onFocusNeed = onFocusNeed
        self.onRemoved = onRemoved
        let need = target.need
        let item = need?.item
        _remembered = State(initialValue: need?.kind != NeedKind.oneTime.rawValue)
        _name = State(initialValue: item?.name ?? need?.title ?? "")
        _catalogNotes = State(initialValue: item?.notes ?? "")
        _purchaseNotes = State(initialValue: need?.notes ?? "")
        _quantity = State(initialValue: Int(need?.quantity ?? 1))
        _urgency = State(initialValue: NeedUrgency(rawValue: need?.urgency ?? "") ?? .normal)
        if let need {
            if let item {
                _categoryID = State(initialValue: item.category?.id)
                _storeIDs = State(initialValue: Set(item.stores?.map(\.id) ?? []))
                _anyStore = State(initialValue: item.anyStore)
            } else {
                _categoryID = State(initialValue: need.oneTimeCategory?.id)
                _storeIDs = State(initialValue: Set(need.oneTimeStores?.map(\.id) ?? []))
                _anyStore = State(initialValue: need.oneTimeAnyStore)
            }
        } else {
            _categoryID = State(initialValue: nil)
            _storeIDs = State(initialValue: Set(target.scope.selectedStoreID.map { [$0] } ?? []))
            _anyStore = State(initialValue: false)
        }
    }

    private var isEditing: Bool { target.needID != nil }
    private var canonicalList: GroceryList? {
        GroceryRowScope.canonicalList(Array(lists), households: Array(households), selection: selection)
    }
    private var scopedItems: [Item] {
        GroceryRowScope.validItems(Array(items), canonicalList: canonicalList)
    }
    private var canonicalNeed: Need? {
        guard let needID = target.needID else { return nil }
        return GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList).first {
            $0.id == needID && $0.objectID == target.need?.objectID && !$0.archived
        }
    }
    private var scopeValid: Bool {
        guard service != nil, let householdID = target.scope.householdID,
            let listID = target.scope.listID, let canonicalList,
            selection.householdID == householdID, selection.listID == listID,
            canonicalList.id == listID, canonicalList.household?.id == householdID
        else { return false }
        guard isEditing else { return true }
        guard let need = canonicalNeed else { return false }
        if remembered {
            return need.kind == NeedKind.remembered.rawValue && scopedItems.contains { $0 == need.item }
        }
        return need.kind == NeedKind.oneTime.rawValue && need.item == nil
    }
    private var validQuantity: Bool { (1...99).contains(quantity) }
    private var canSave: Bool {
        scopeValid && validQuantity && !CatalogProjection.normalizedName(name).isEmpty
            && (anyStore || !storeIDs.isEmpty)
    }
    private var scopedCategories: [Category] {
        GroceryRowScope.validCategories(Array(categories), canonicalList: canonicalList)
    }
    private var normalizedSearch: String { CatalogProjection.normalizedName(name) }
    private var activeMatches: [Need] {
        guard scopeValid, !normalizedSearch.isEmpty else { return [] }
        return GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList).filter { need in
            !need.archived && need.id != target.needID
                && CatalogProjection.normalizedName(need.item?.name ?? need.title).contains(normalizedSearch)
                && (need.kind == NeedKind.oneTime.rawValue || scopedItems.contains { $0 == need.item })
        }
    }
    private var catalogMatches: [Item] {
        guard scopeValid, !normalizedSearch.isEmpty else { return [] }
        let activeItemIDs = Set(activeMatches.compactMap { $0.item?.id })
        return scopedItems.filter {
            CatalogProjection.normalizedName($0.name).contains(normalizedSearch)
                && !activeItemIDs.contains($0.id)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(isEditing ? "Current grocery" : "New grocery") {
                    if isEditing {
                        Label(
                            remembered ? "Remembered grocery" : "One-time grocery",
                            systemImage: remembered ? "bookmark" : "1.circle"
                        ).accessibilityIdentifier(
                            remembered ? "shopping.grocery.remembered" : "shopping.grocery.oneTime")
                    } else if target.need?.kind == NeedKind.oneTime.rawValue {
                        Label("One-time grocery", systemImage: "1.circle").accessibilityIdentifier(
                            "shopping.grocery.oneTime")
                    } else {
                        Toggle("Remember this item", isOn: $remembered).accessibilityIdentifier(
                            "shopping.grocery.remembered")
                    }
                    TextField("Grocery name", text: $name).accessibilityIdentifier("shopping.grocery.name")
                    if !isEditing { matches }
                    if !remembered {
                        Text("This grocery won’t be remembered in Catalog.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if remembered {
                        TextField("Catalog notes", text: $catalogNotes, axis: .vertical)
                            .accessibilityIdentifier("shopping.grocery.catalogNotes")
                    }
                    TextField("Purchase notes", text: $purchaseNotes, axis: .vertical)
                        .accessibilityIdentifier("shopping.grocery.purchaseNotes")
                }
                Section("Quantity and urgency") {
                    TextField("Quantity", value: $quantity, format: .number).keyboardType(.numberPad)
                        .accessibilityIdentifier("shopping.grocery.quantity")
                    Stepper("Quantity \(quantity)", value: $quantity, in: 1...99).accessibilityIdentifier(
                        "shopping.grocery.quantityStepper")
                    Picker("Urgency", selection: $urgency) {
                        Text("Normal").tag(NeedUrgency.normal)
                        Text("Urgent").tag(NeedUrgency.urgent)
                    }.pickerStyle(.segmented).accessibilityIdentifier("shopping.grocery.urgency")
                }
                Section("Category") {
                    Picker("Category", selection: $categoryID) {
                        Text("Uncategorized").tag(nil as UUID?)
                        ForEach(scopedCategories, id: \.objectID) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                PurchaseRulesPicker(
                    storeIDs: $storeIDs, anyStore: $anyStore, householdID: target.scope.householdID,
                    listID: target.scope.listID)
                if !scopeValid {
                    Text(
                        "This grocery or household is no longer available. Your draft has been kept; close it and try again."
                    ).foregroundStyle(.secondary)
                }
                if let error {
                    Text(message(for: error)).foregroundStyle(.red)
                    if case NeedServiceError.catalogNameCollision = error {
                        Button("Create distinct item") {
                            allowDuplicate = true
                            save()
                        }.accessibilityIdentifier("shopping.grocery.createDistinct")
                    }
                }
                if isEditing {
                    Button("Remove grocery", role: .destructive) { captureRemoval() }.disabled(!scopeValid)
                        .accessibilityIdentifier("shopping.grocery.remove")
                }
            }
            .navigationTitle(isEditing ? "Edit grocery" : "Add grocery")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("shopping.grocery.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave).accessibilityIdentifier(
                        "shopping.grocery.save")
                }
            }
            .alert(
                "Remove \(removal?.name ?? name)?",
                isPresented: Binding(
                    get: { removal != nil }, set: { if !$0 { removal = nil } }
                ), presenting: removal
            ) { captured in
                Button("Remove", role: .destructive) { remove(captured) }
                    .accessibilityIdentifier("shopping.grocery.confirmRemove")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("You can undo this removal or restore the grocery from Recently cleared.")
            }
            .onChange(of: name) { _, _ in allowDuplicate = false }
        }
    }

    @ViewBuilder
    private var matches: some View {
        if !activeMatches.isEmpty {
            Section("Current groceries") {
                ForEach(activeMatches, id: \.objectID) { need in
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Edit current \(need.item?.name ?? need.title)") { focus(need) }
                            .buttonStyle(.borderless)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("shopping.grocery.activeMatch.\(need.id.uuidString)")
                        if remembered, need.carted, let item = need.item {
                            needAgainButton(item)
                        }
                    }
                }
            }
        }
        if !catalogMatches.isEmpty && remembered {
            Section("Remembered items") {
                ForEach(catalogMatches, id: \.objectID) { item in
                    if item.isArchived {
                        Text("\(item.name) · Archived in Catalog")
                            .font(.subheadline)
                    } else {
                        needAgainButton(item)
                    }
                }
            }
        }
    }

    private func needAgainButton(_ item: Item) -> some View {
        Button("Need again \(item.name)") { needAgain(item) }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            .disabled(!scopeValid)
            .accessibilityIdentifier("shopping.grocery.needAgain.\(item.id.uuidString)")
    }

    private func message(for error: Error) -> String {
        guard let serviceError = error as? NeedServiceError else { return error.localizedDescription }
        switch serviceError {
        case .catalogNameCollision:
            return
                "A remembered item already has this name. Choose an existing match above or explicitly create a distinct item."
        case .invalidQuantity:
            return "Enter a quantity from 1 to 99."
        case .invalidName:
            return "Enter a grocery name."
        case .storeNotFound, .invalidStoreIdentity:
            return "A selected store is unavailable. Choose an active store or Any store and try again."
        case .categoryNotFound:
            return "This category is unavailable. Choose another category or Uncategorized."
        case .itemArchived:
            return "This item is archived in Catalog. Restore it there before adding it again."
        case .activeRememberedNeedDuplicates, .invalidCatalogIdentity, .invalidOccurrenceIdentity:
            return
                "This grocery has conflicting saved records. Your draft has been kept and nothing was changed."
        case .scopeChanged, .householdNotFound, .listNotFound, .itemNotFound, .needNotFound:
            return
                "The grocery or household changed. Your draft has been kept; close it and reopen the current grocery."
        default:
            return "The grocery could not be saved. Your draft has been kept; try again."
        }
    }

    private func values() -> RememberedNeedValues {
        RememberedNeedValues(quantity: Int64(quantity), purchaseNotes: purchaseNotes, urgency: urgency)
    }

    private func save() {
        guard canSave, let service, let householdID = target.scope.householdID,
            let listID = target.scope.listID
        else { return }
        defer { allowDuplicate = false }
        do {
            let savedID: UUID
            let catalog = CatalogItemValues(
                name: name, notes: catalogNotes, categoryID: categoryID,
                anyStore: anyStore, storeIDs: storeIDs)
            if let needID = target.needID {
                if remembered {
                    try service.saveRememberedGrocery(
                        needID: needID, householdID: householdID,
                        listID: listID, catalog: catalog, need: values(),
                        allowingCatalogNameCollision: allowDuplicate)
                } else {
                    try service.saveOneTimeGrocery(
                        needID: needID, householdID: householdID,
                        listID: listID, title: name, categoryID: categoryID, storeIDs: storeIDs,
                        anyStore: anyStore, need: values())
                }
                savedID = needID
            } else if remembered {
                savedID = try service.createRememberedGrocery(
                    householdID: householdID, listID: listID,
                    catalog: catalog, need: values(), allowingCatalogNameCollision: allowDuplicate
                ).needID
            } else {
                savedID = try service.addOneTimeNeed(
                    title: name, notes: purchaseNotes,
                    categoryID: categoryID, storeIDs: storeIDs, anyStore: anyStore,
                    quantity: Int64(quantity), urgency: urgency, householdID: householdID, listID: listID)
            }
            onSaved(savedID)
            dismiss()
        } catch { self.error = error }
    }

    private func focus(_ need: Need) {
        guard scopeValid, activeMatches.contains(need) else { return }
        onFocusNeed(need)
    }

    private func needAgain(_ item: Item) {
        guard scopeValid, scopedItems.contains(item), let service,
            let householdID = target.scope.householdID, let listID = target.scope.listID
        else { return }
        do {
            let needID = try service.addRememberedNeed(
                itemID: item.id, listID: listID, householdID: householdID)
            onSaved(needID)
            dismiss()
        } catch { self.error = error }
    }

    private func captureRemoval() {
        guard scopeValid, let need = canonicalNeed, let householdID = target.scope.householdID,
            let listID = target.scope.listID
        else { return }
        removal = RemovalTarget(
            needID: need.id, revision: need.revision,
            householdID: householdID, listID: listID, name: need.item?.name ?? need.title)
    }

    private func remove(_ removal: RemovalTarget) {
        guard scopeValid, let service else { return }
        do {
            let operationID = try service.removeNeed(
                needID: removal.needID, householdID: removal.householdID,
                listID: removal.listID, expectedRevision: removal.revision)
            onRemoved(operationID, target.scope)
            dismiss()
        } catch { self.error = error }
    }

}

private struct GroceryEditorPreview: View {
    @Environment(\.persistenceSelection) private var selection

    var body: some View {
        GroceryEditorView(
            target: GroceryEditorTarget(
                scope: GroceryAddScope(
                    householdID: selection.householdID, listID: selection.listID, selectedStoreID: nil,
                    selectedStoreName: nil), need: nil),
            onSaved: { _ in }, onFocusNeed: { _ in }, onRemoved: { _, _ in }
        )
    }
}

#Preview("Add grocery") { ShoppingPreviewHost(.populated) { GroceryEditorPreview() } }
