import CoreData
import SwiftUI

struct GroceryEditorTarget: Identifiable {
    let id = UUID()
    let scope: GroceryAddScope
    let need: Need?
    let needID: UUID?
    let originalCategoryID: UUID?

    init(scope: GroceryAddScope, need: Need?) {
        self.scope = scope
        self.need = need
        self.needID = need?.id
        self.originalCategoryID = need?.item?.category?.id
            ?? (need?.kind == NeedKind.oneTime.rawValue ? need?.oneTimeCategory?.id : nil)
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

private enum GroceryEditorField: Hashable {
    case name
    case catalogNotes
    case purchaseNotes
}

struct GroceryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.needService) private var service
    @Environment(\.hapticFeedback) private var hapticFeedback
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
    @State private var quantity: Int?
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
    @State private var showingCategoryCreation = false
    @State private var showingStoreCreation = false
    @State private var didRequestInitialFocus = false
    @State private var isSaving = false
    @FocusState private var focusedField: GroceryEditorField?
    let target: GroceryEditorTarget
    let onSaved: (UUID, UUID?) -> Void
    let onFocusNeed: (UUID) -> Void
    let onRemoved: (UUID, GroceryAddScope) -> Void

    init(
        target: GroceryEditorTarget, onSaved: @escaping (UUID, UUID?) -> Void, onFocusNeed: @escaping (UUID) -> Void,
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
        _quantity = State(initialValue: need?.quantity.map(Int.init))
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
            _anyStore = State(initialValue: target.scope.selectedStoreID == nil)
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
    private var validQuantity: Bool { quantity.map { (1...99).contains($0) } ?? true }
    private var canSave: Bool {
        guard scopeValid, validQuantity else { return false }
        if isPromotingOneTime && promotionChoice == .existing {
            return selectedCatalogItem != nil
        }
        return !CatalogProjection.normalizedName(name).isEmpty
    }
    private var scopedCategories: [Category] {
        GroceryRowScope.validCategories(Array(categories), canonicalList: canonicalList)
    }
    private var activeStoreIDs: Set<UUID> {
        Set(GroceryRowScope.validStores(Array(stores), canonicalList: canonicalList)
            .filter { !$0.isArchived }.map(\.id))
    }
    private var activeRememberedNeedState: (byItemID: [UUID: Need], ambiguousItemIDs: Set<UUID>) {
        let validItems = Set(scopedItems.map(\.objectID))
        let activeNeeds = GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList)
            .filter {
                !$0.archived && $0.kind == NeedKind.remembered.rawValue &&
                    $0.item.map { validItems.contains($0.objectID) } == true
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        var needsByItemID: [UUID: Need] = [:]
        var ambiguousItemIDs: Set<UUID> = []
        for need in activeNeeds {
            guard let itemID = need.item?.id, !ambiguousItemIDs.contains(itemID) else { continue }
            guard needsByItemID.removeValue(forKey: itemID) == nil else {
                ambiguousItemIDs.insert(itemID)
                continue
            }
            needsByItemID[itemID] = need
        }
        return (needsByItemID, ambiguousItemIDs)
    }
    private var activeRememberedNeedsByItemID: [UUID: Need] {
        activeRememberedNeedState.byItemID
    }
    private var suggestedItems: [Item] {
        guard scopeValid, !isEditing, remembered else { return [] }
        let activeNeedState = activeRememberedNeedState
        let eligibleItems = scopedItems.filter { item in
            !activeNeedState.ambiguousItemIDs.contains(item.id) &&
            CatalogProjection.textMatches(item.name, query: target.scope.textFilter) &&
                (!target.scope.urgentOnly ||
                    activeNeedState.byItemID[item.id]?.urgency == NeedUrgency.urgent.rawValue)
        }
        let itemsByID = Dictionary(uniqueKeysWithValues: eligibleItems.map { ($0.id, $0) })
        let suggestions = CatalogSuggestionMatcher.suggestions(
            for: name,
            candidates: eligibleItems.map {
                CatalogSuggestionCandidate(
                    id: $0.id,
                    name: $0.name,
                    categoryID: $0.category?.id,
                    explicitStoreIDs: Set($0.stores?.map(\.id) ?? []),
                    anyStore: $0.anyStore,
                    isArchived: $0.isArchived
                )
            },
            purchaseFilter: PurchaseFilter(
                selectedStoreID: target.scope.selectedStoreID,
                includedStoreIDs: target.scope.includedStoreIDs,
                excludedStoreIDs: target.scope.excludedStoreIDs
            ),
            activeStoreIDs: activeStoreIDs,
            categoryID: target.scope.categoryID
        )
        return suggestions.compactMap { itemsByID[$0.candidate.id] }
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
                Section(isEditing ? "Current item" : "New item") {
                    if isEditing {
                        Label(
                            remembered ? "Remembered item" : "One-time item",
                            systemImage: remembered ? "bookmark" : "1.circle"
                        ).accessibilityIdentifier(
                            remembered ? "shopping.grocery.remembered" : "shopping.grocery.oneTime")
                    } else if target.need?.kind == NeedKind.oneTime.rawValue {
                        Label("One-time item", systemImage: "1.circle").accessibilityIdentifier(
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
                                .shoppingMultilineText()
                        }
                        .accessibilityIdentifier("shopping.grocery.promotion.selectedName")
                    } else {
                        TextField("Item name", text: $name)
                            .accessibilityIdentifier("shopping.grocery.name")
                            .focused($focusedField, equals: .name)
                            .submitLabel(.done)
                            .onSubmit { focusedField = nil }
                    }
                    if !remembered && !isPromotingOneTime {
                        Text("This item won’t be remembered in Catalog.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .shoppingMultilineText()
                    }
                    if remembered || (isPromotingOneTime && promotionChoice == .create) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Item notes")
                                .font(.subheadline).fontWeight(.semibold)
                                .shoppingMultilineText()
                                .accessibilityIdentifier("shopping.grocery.catalogNotesHeading")
                            TextField(
                                "Saved for future needs",
                                text: $catalogNotes,
                                axis: .vertical
                            )
                            .lineLimit(2...4)
                            .focused($focusedField, equals: .catalogNotes)
                            .accessibilityIdentifier("shopping.grocery.catalogNotes")
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(remembered ? "Temporary notes" : "Notes")
                            .font(.subheadline).fontWeight(.semibold)
                            .shoppingMultilineText()
                            .accessibilityIdentifier("shopping.grocery.purchaseNotesHeading")
                        TextField(
                            remembered ? "Only for this need" : "Notes for this one-time need",
                            text: $purchaseNotes,
                            axis: .vertical
                        )
                        .lineLimit(2...4)
                        .focused($focusedField, equals: .purchaseNotes)
                        .accessibilityIdentifier("shopping.grocery.purchaseNotes")
                    }
                }
                if !isEditing { matches }
                if isEditing, !remembered {
                    promotionSection
                }
                Section {
                    if let quantity {
                        HStack(spacing: 8) {
                            Stepper(
                                value: Binding(
                                    get: { self.quantity ?? 1 },
                                    set: { self.quantity = $0 }
                                ),
                                in: 1...99
                            ) {
                                LabeledContent("Quantity") { Text("\(quantity)") }
                            }
                            .accessibilityValue("\(quantity)")
                            .accessibilityIdentifier("shopping.grocery.quantity")
                            Button { self.quantity = nil } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Clear quantity")
                            .accessibilityIdentifier("shopping.grocery.quantity.clear")
                        }
                    } else {
                        Button("Add quantity") { quantity = 1 }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("shopping.grocery.quantity.add")
                    }
                    Toggle("Urgent", isOn: Binding(
                        get: { urgency == .urgent },
                        set: { urgency = $0 ? .urgent : .normal }
                    ))
                    .accessibilityIdentifier("shopping.grocery.urgency")
                }
                if !isPromotingOneTime || promotionChoice == .create {
                    CategoryPills(
                        selection: $categoryID,
                        categories: scopedCategories,
                        onAddCategory: { showingCategoryCreation = true }
                    )
                    PurchaseRulesPicker(
                        storeIDs: $storeIDs, anyStore: $anyStore, householdID: target.scope.householdID,
                        listID: target.scope.listID, onAddStore: { showingStoreCreation = true })
                }
                if !scopeValid {
                    Text(
                        "This item or household is no longer available. Your draft has been kept; close it and try again."
                    )
                    .foregroundStyle(.secondary)
                    .shoppingMultilineText()
                }
                if let error {
                    Text(message(for: error))
                        .foregroundStyle(.red)
                        .shoppingMultilineText()
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
                        Button("View existing item") { onFocusNeed(conflictingNeed.id) }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("shopping.grocery.promotion.viewConflict")
                    }
                }
                if isEditing {
                    Button("Remove item", systemImage: "trash", role: .destructive) { captureRemoval() }
                        .disabled(!scopeValid)
                        .accessibilityIdentifier("shopping.grocery.remove")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(isSaving)
            .navigationTitle(isEditing ? "Edit item" : "Add item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("shopping.grocery.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().accessibilityLabel("Saving item")
                    } else {
                        Button(
                            isPromotingOneTime ? "Remember" : "Save",
                            systemImage: "checkmark",
                            action: save
                        )
                        .disabled(!canSave)
                        .accessibilityIdentifier("shopping.grocery.save")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                        .accessibilityIdentifier("shopping.grocery.keyboardDone")
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
            .sheet(isPresented: $showingCategoryCreation) {
                CategoryCreationView(
                    householdID: target.scope.householdID,
                    listID: target.scope.listID
                ) { categoryID = $0 }
            }
            .sheet(isPresented: $showingStoreCreation) {
                StoreCreationView(
                    householdID: target.scope.householdID,
                    listID: target.scope.listID
                ) { id in
                    if storeIDs.isEmpty { anyStore = false }
                    storeIDs.insert(id)
                }
            }
            .onAppear {
                guard !isEditing, !didRequestInitialFocus else { return }
                didRequestInitialFocus = true
                DispatchQueue.main.async { focusedField = .name }
            }
            .onChange(of: name) { _, _ in allowDuplicate = false; error = nil }
            .onChange(of: promotionChoice) { _, _ in
                allowDuplicate = false
                conflictingNeedID = nil
                error = nil
            }
        }
        .interactiveDismissDisabled(isSaving)
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
                    Text("The item name, category, and purchase rules in this editor will become a new Catalog item. Notes, quantity, and urgency stay with this item.")
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
        if !suggestedItems.isEmpty {
            Section {
                ForEach(suggestedItems, id: \.objectID) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { selectSuggestion(item.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                Text(suggestionSummary(item))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .frame(minHeight: 44)
                        .accessibilityLabel(
                            activeRememberedNeedsByItemID[item.id] == nil
                                ? "Need again \(item.name)"
                                : "Edit current \(item.name)"
                        )
                        .accessibilityValue(suggestionSummary(item))
                        .accessibilityIdentifier(suggestionIdentifier(item))
                        if activeRememberedNeedsByItemID[item.id]?.carted == true {
                            needAgainButton(item)
                        }
                    }
                }
            } header: {
                Text("Suggestions")
            } footer: {
                if let selectedStoreName = target.scope.selectedStoreName {
                    Text("Showing saved items available for \(selectedStoreName). Use All on Groceries to reuse other Catalog items.")
                } else {
                    Text("Choosing a suggestion is explicit. Typing does not change your Catalog or grocery list.")
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

    private func suggestionSummary(_ item: Item) -> String {
        let status: String
        if let need = activeRememberedNeedsByItemID[item.id] {
            status = need.carted ? "In cart" : "On grocery list"
        } else {
            status = "Saved in Catalog"
        }
        return "\(catalogSummary(item)) · \(status)"
    }

    private func suggestionIdentifier(_ item: Item) -> String {
        if let need = activeRememberedNeedsByItemID[item.id] {
            return "shopping.grocery.activeMatch.\(need.id.uuidString)"
        }
        return "shopping.grocery.suggestion.\(item.id.uuidString)"
    }

    private func message(for error: Error) -> String {
        guard let serviceError = error as? NeedServiceError else { return error.localizedDescription }
        switch serviceError {
        case .catalogNameCollision:
            return
                "A remembered item already has this name. Choose an existing match above or explicitly create a distinct item."
        case .activeRememberedNeedConflict:
            return
                "That Catalog item is already on the current list. Both items were kept; you can view the existing item or choose another Catalog item."
        case .invalidQuantity:
            return "Enter a quantity from 1 to 99, or clear it."
        case .invalidName:
            return "Enter an item name."
        case .storeNotFound, .invalidStoreIdentity:
            return "A selected store is unavailable. Choose an active store or Any store and try again."
        case .categoryNotFound:
            return "This category is unavailable. Choose another category or Uncategorized."
        case .itemArchived:
            return "This item is archived in Catalog. Restore it there before adding it again."
        case .activeRememberedNeedDuplicates, .invalidCatalogIdentity, .invalidOccurrenceIdentity:
            return
                "This item has conflicting saved records. Your draft has been kept and nothing was changed."
        case .scopeChanged, .householdNotFound, .listNotFound, .itemNotFound, .needNotFound:
            return
                "The item or household changed. Your draft has been kept; close it and reopen the current item."
        default:
            return "The item could not be saved. Your draft has been kept; try again."
        }
    }

    private func values() -> RememberedNeedValues {
        RememberedNeedValues(quantity: quantity.map(Int64.init), purchaseNotes: purchaseNotes, urgency: urgency)
    }

    private func save() {
        guard canSave, !isSaving else { return }
        isSaving = true
        Task { await saveItem() }
    }

    @MainActor
    private func saveItem() async {
        defer {
            allowDuplicate = false
            isSaving = false
        }
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
                    try await service.saveRememberedGrocery(
                        needID: needID, householdID: householdID,
                        listID: listID, catalog: catalog, need: values(),
                        allowingCatalogNameCollision: allowDuplicate)
                } else {
                    try await service.saveOneTimeGrocery(
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
                    quantity: quantity.map(Int64.init), urgency: urgency, householdID: householdID, listID: listID)
            }
            hapticFeedback.play(.success)
            onSaved(savedID, categoryID)
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
            let savedCategoryID: UUID?
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
                savedCategoryID = categoryID
            case .existing:
                guard let item = selectedCatalogItem else { return }
                _ = try service.rememberOneTimeGrocery(
                    needID: needID, householdID: householdID, listID: listID,
                    existingItemID: item.id, need: values()
                )
                savedCategoryID = item.category?.id
            }
            hapticFeedback.play(.success)
            onSaved(needID, savedCategoryID)
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
        let validStores = GroceryRowScope.validStores(Array(stores), canonicalList: canonicalList)
        let savedStoreLabels = validStores.filter { (item.stores ?? []).contains($0) }
            .map { $0.isArchived ? "\($0.name) (archived)" : $0.name }
        purchaseRule = CatalogSuggestionPurchaseSummary.text(
            anyStore: item.anyStore,
            savedStoreLabels: savedStoreLabels,
            hasSavedStores: !(item.stores ?? []).isEmpty
        )
        return "\(category) · \(purchaseRule)"
    }

    private func selectSuggestion(_ itemID: UUID) {
        guard scopeValid, let item = suggestedItems.first(where: { $0.id == itemID }) else { return }
        applySuggestion(item, renewCarted: false)
    }

    private func needAgain(_ item: Item) {
        guard scopeValid, suggestedItems.contains(item) else { return }
        applySuggestion(item, renewCarted: true)
    }

    private func applySuggestion(_ item: Item, renewCarted: Bool) {
        guard scopeValid, suggestedItems.contains(item), let service,
              let householdID = target.scope.householdID, let listID = target.scope.listID else { return }
        let expectedNeed = activeRememberedNeedsByItemID[item.id]
        do {
            switch try service.applyCatalogSuggestion(
                itemID: item.id,
                itemRevision: item.revision,
                expectedNeedID: expectedNeed?.id,
                expectedNeedRevision: expectedNeed?.revision,
                listID: listID,
                householdID: householdID,
                purchaseFilter: PurchaseFilter(
                    selectedStoreID: target.scope.selectedStoreID,
                    includedStoreIDs: target.scope.includedStoreIDs,
                    excludedStoreIDs: target.scope.excludedStoreIDs
                ),
                categoryID: target.scope.categoryID,
                textFilter: target.scope.textFilter,
                urgentOnly: target.scope.urgentOnly,
                renewCarted: renewCarted
            ) {
            case .added(let needID), .renewed(let needID):
                onSaved(needID, item.category?.id)
                dismiss()
            case .focusExisting(let needID):
                onFocusNeed(needID)
            }
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
            onSaved: { _, _ in }, onFocusNeed: { _ in }, onRemoved: { _, _ in }
        )
    }
}

#Preview("Add item") { ShoppingPreviewHost(.populated) { GroceryEditorPreview() } }
