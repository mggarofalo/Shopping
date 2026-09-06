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

private enum OneTimePromotionChoice: String, CaseIterable {
    case create
    case existing
}

struct GroceryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.items()) private var items: FetchedResults<Item>
    @FetchRequest(fetchRequest: NavigationFetchRequests.needs()) private var needs: FetchedResults<Need>
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories:
        FetchedResults<Category>
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
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
    @State private var isPromotingOneTime = false
    @State private var promotionChoice = OneTimePromotionChoice.create
    @State private var catalogSearch = ""
    @State private var selectedCatalogItemID: UUID?
    @State private var conflictingNeedID: UUID?
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
        guard scopeValid, validQuantity else { return false }
        if isPromotingOneTime && promotionChoice == .existing {
            return selectedCatalogItem != nil
        }
        return !CatalogProjection.normalizedName(name).isEmpty && (anyStore || !storeIDs.isEmpty)
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
    private var promotionCatalogMatches: [Item] {
        let query = CatalogProjection.normalizedName(catalogSearch)
        return scopedItems.filter { item in
            !item.isArchived && (query.isEmpty || CatalogProjection.normalizedName(item.name).contains(query))
        }
    }
    private var selectedCatalogItem: Item? {
        guard let selectedCatalogItemID else { return nil }
        return promotionCatalogMatches.first { $0.id == selectedCatalogItemID }
            ?? scopedItems.first { $0.id == selectedCatalogItemID && !$0.isArchived }
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
                    if isPromotingOneTime && promotionChoice == .existing {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selectedCatalogItem?.name ?? "Choose an item from Catalog")
                            Text("The selected item’s name and saved Catalog details are read-only.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("shopping.grocery.promotion.selectedName")
                    } else {
                        TextField("Grocery name", text: $name)
                            .accessibilityIdentifier("shopping.grocery.name")
                    }
                    if !isEditing { matches }
                    if !remembered && !isPromotingOneTime {
                        Text("This grocery won’t be remembered in Catalog.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if remembered || (isPromotingOneTime && promotionChoice == .create) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Item notes").font(.subheadline).fontWeight(.semibold)
                            TextField("Add reusable details", text: $catalogNotes, axis: .vertical)
                                .accessibilityIdentifier("shopping.grocery.catalogNotes")
                            Text("Saved with this item and reused each time you add it.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Grocery notes").font(.subheadline).fontWeight(.semibold)
                        TextField("Add instructions for this grocery", text: $purchaseNotes, axis: .vertical)
                            .accessibilityIdentifier("shopping.grocery.purchaseNotes")
                        Text("Applies only to this grocery on the current list.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if isEditing, !remembered {
                    promotionSection
                }
                Section {
                    Stepper(value: $quantity, in: 1...99) {
                        LabeledContent("Quantity") { Text("\(quantity)") }
                    }
                    .accessibilityValue("\(quantity)")
                    .accessibilityIdentifier("shopping.grocery.quantity")
                    Toggle("Urgent", isOn: Binding(
                        get: { urgency == .urgent },
                        set: { urgency = $0 ? .urgent : .normal }
                    ))
                    .accessibilityIdentifier("shopping.grocery.urgency")
                }
                if !isPromotingOneTime || promotionChoice == .create {
                    CategoryPills(selection: $categoryID, categories: scopedCategories)
                    PurchaseRulesPicker(
                        storeIDs: $storeIDs, anyStore: $anyStore, householdID: target.scope.householdID,
                        listID: target.scope.listID)
                }
                if !scopeValid {
                    Text(
                        "This grocery or household is no longer available. Your draft has been kept; close it and try again."
                    ).foregroundStyle(.secondary)
                }
                if let error {
                    Text(message(for: error)).foregroundStyle(.red)
                    if case NeedServiceError.catalogNameCollision = error {
                        if isPromotingOneTime { collisionChoices }
                        Button("Create distinct item") {
                            allowDuplicate = true
                            if isPromotingOneTime { promoteOneTime() } else { save() }
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("shopping.grocery.createDistinct")
                    }
                    if let conflictingNeedID,
                       let conflictingNeed = activeRememberedNeed(id: conflictingNeedID) {
                        Button("View existing grocery") { onFocusNeed(conflictingNeed) }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("shopping.grocery.promotion.viewConflict")
                    }
                }
                if isEditing {
                    Button("Remove grocery", systemImage: "trash", role: .destructive) { captureRemoval() }
                        .disabled(!scopeValid)
                        .accessibilityIdentifier("shopping.grocery.remove")
                }
            }
            .navigationTitle(isEditing ? "Edit grocery" : "Add grocery")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("shopping.grocery.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        isPromotingOneTime ? "Remember" : "Save",
                        systemImage: "checkmark",
                        action: save
                    )
                    .disabled(!canSave)
                    .accessibilityIdentifier("shopping.grocery.save")
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
            .onChange(of: name) { _, _ in allowDuplicate = false; error = nil }
            .onChange(of: promotionChoice) { _, _ in
                allowDuplicate = false
                conflictingNeedID = nil
                error = nil
            }
        }
    }

    @ViewBuilder
    private var promotionSection: some View {
        if isPromotingOneTime {
            Section("Remember this item") {
                Picker("Save to Catalog", selection: $promotionChoice) {
                    Text("Create new").tag(OneTimePromotionChoice.create)
                        .accessibilityIdentifier("shopping.grocery.promotion.choice.create")
                    Text("Use existing").tag(OneTimePromotionChoice.existing)
                        .accessibilityIdentifier("shopping.grocery.promotion.choice.existing")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("shopping.grocery.promotion.choice")

                if promotionChoice == .create {
                    Text("The grocery name, category, and purchase rules in this editor will become a new Catalog item. Purchase notes, quantity, and urgency stay with this grocery.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    TextField("Search Catalog", text: $catalogSearch)
                        .accessibilityIdentifier("shopping.grocery.promotion.search")
                    if promotionCatalogMatches.isEmpty {
                        Text("No active Catalog items match your search.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(promotionCatalogMatches, id: \.objectID) { item in
                        Button { selectedCatalogItemID = item.id; error = nil } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                    Text(catalogSummary(item))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedCatalogItemID == item.id {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("shopping.grocery.promotion.item.\(item.id.uuidString)")
                    }
                    if let item = selectedCatalogItem {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Saved Catalog details").font(.headline)
                            Text(catalogSummary(item))
                            if !item.notes.isEmpty { Text(item.notes).foregroundStyle(.secondary) }
                            Text("These saved details won’t be changed.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("shopping.grocery.promotion.selectedMetadata")
                    }
                }
                Button("Keep as one-time") { exitPromotion() }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("shopping.grocery.promotion.keepOneTime")
            }
        } else {
            Section {
                Button("Remember this item") { enterPromotion() }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("shopping.grocery.promotion.start")
            } footer: {
                Text("Review Catalog details before saving. Nothing changes until you tap Remember.")
            }
        }
    }

    @ViewBuilder
    private var collisionChoices: some View {
        if let serviceError = error as? NeedServiceError,
           case .catalogNameCollision(let ids) = serviceError {
            ForEach(scopedItems.filter { ids.contains($0.id) && !$0.isArchived }, id: \.objectID) { item in
                Button("Use existing \(item.name)") {
                    promotionChoice = .existing
                    selectedCatalogItemID = item.id
                    error = nil
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("shopping.grocery.promotion.collision.\(item.id.uuidString)")
            }
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
        case .activeRememberedNeedConflict:
            return
                "That Catalog item is already on the current list. Both groceries were kept; you can view the existing grocery or choose another Catalog item."
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
        defer { allowDuplicate = false }
        guard canSave, let service, let householdID = target.scope.householdID,
            let listID = target.scope.listID
        else { return }
        if isPromotingOneTime {
            promoteOneTime()
            return
        }
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

    private func enterPromotion() {
        guard scopeValid, canonicalNeed?.kind == NeedKind.oneTime.rawValue else { return }
        isPromotingOneTime = true
        promotionChoice = .create
        catalogSearch = ""
        selectedCatalogItemID = nil
        conflictingNeedID = nil
        allowDuplicate = false
        error = nil
    }

    private func exitPromotion() {
        isPromotingOneTime = false
        selectedCatalogItemID = nil
        conflictingNeedID = nil
        allowDuplicate = false
        error = nil
    }

    private func promoteOneTime() {
        defer { allowDuplicate = false }
        guard isPromotingOneTime, canSave, let service, let needID = target.needID,
              let householdID = target.scope.householdID, let listID = target.scope.listID else { return }
        do {
            switch promotionChoice {
            case .create:
                let catalog = CatalogItemValues(
                    name: name, notes: catalogNotes, categoryID: categoryID,
                    anyStore: anyStore, storeIDs: storeIDs
                )
                _ = try service.rememberOneTimeGroceryCreatingItem(
                    needID: needID, householdID: householdID, listID: listID,
                    catalog: catalog, need: values(), allowingCatalogNameCollision: allowDuplicate
                )
            case .existing:
                guard let item = selectedCatalogItem else { return }
                _ = try service.rememberOneTimeGrocery(
                    needID: needID, householdID: householdID, listID: listID,
                    existingItemID: item.id, need: values()
                )
            }
            onSaved(needID)
            dismiss()
        } catch {
            self.error = error
            if case NeedServiceError.activeRememberedNeedConflict(let needID) = error {
                conflictingNeedID = needID
            } else {
                conflictingNeedID = nil
            }
        }
    }

    private func activeRememberedNeed(id: UUID) -> Need? {
        GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList).first {
            $0.id == id && !$0.archived && $0.kind == NeedKind.remembered.rawValue && $0.item != nil
        }
    }

    private func catalogSummary(_ item: Item) -> String {
        let validCategories = GroceryRowScope.validCategories(Array(categories), canonicalList: canonicalList)
        let category: String
        if let itemCategory = item.category {
            category = validCategories.contains(itemCategory) ? itemCategory.name : "Unavailable category"
        } else {
            category = "Uncategorized"
        }
        let purchaseRule: String
        if item.anyStore {
            purchaseRule = "Any store"
        } else {
            let validStores = GroceryRowScope.validStores(Array(stores), canonicalList: canonicalList)
            let names = validStores.filter { !$0.isArchived && (item.stores ?? []).contains($0) }
                .map(\.name)
                .sorted()
            purchaseRule = names.isEmpty ? "Needs store" : names.joined(separator: ", ")
        }
        return "\(category) · \(purchaseRule)"
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
