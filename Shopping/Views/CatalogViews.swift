import CoreData
import SwiftUI

struct CatalogFilterState: Equatable {
    var selectedStoreID: UUID?
    var includedStoreIDs: Set<UUID> = []
    var excludedStoreIDs: Set<UUID> = []
    var categoryID: UUID?
    var showArchived = false

    var count: Int {
        includedStoreIDs.count + excludedStoreIDs.count + (categoryID == nil ? 0 : 1) + (showArchived ? 1 : 0)
    }

    func query(text: String) -> CatalogItemFilter {
        CatalogItemFilter(purchase: PurchaseFilter(
            selectedStoreID: selectedStoreID,
            includedStoreIDs: includedStoreIDs,
            excludedStoreIDs: excludedStoreIDs
        ), text: text, categoryID: categoryID)
    }
}

enum CatalogScope {
    static func canonicalList(
        lists: [GroceryList],
        households: [Household],
        selection: PersistenceSelection
    ) -> GroceryList? {
        GroceryRowScope.canonicalList(lists, households: households, selection: selection)
    }

    static func items(_ items: [Item], household: Household?) -> [Item] {
        guard let household else { return [] }
        let counts = Dictionary(grouping: items, by: \.id).mapValues(\.count)
        return items.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 && $0.household == household &&
                $0.objectID.persistentStore == household.objectID.persistentStore
        }
    }

    static func categories(_ categories: [Category], household: Household?) -> [Category] {
        guard let household else { return [] }
        let counts = Dictionary(grouping: categories, by: \.id).mapValues(\.count)
        return categories.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 && $0.household == household &&
                $0.objectID.persistentStore == household.objectID.persistentStore
        }
    }
}

private struct CatalogEditSession: Identifiable {
    let id = UUID()
    let selection: PersistenceSelection
    let itemID: UUID?
    let values: CatalogItemValues
}

struct CatalogView: View {
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(fetchRequest: NavigationFetchRequests.items()) private var items: FetchedResults<Item>
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories: FetchedResults<Category>
    @FetchRequest(fetchRequest: PurchaseRulesStoreScope.listsRequest()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @State private var searchText = ""
    @State private var filters = CatalogFilterState()
    @State private var projectedIDs: Set<UUID> = []
    @State private var showingFilters = false
    @State private var showingStores = false
    @State private var editor: CatalogEditSession?
    @State private var errorMessage: String?

    private var canonicalList: GroceryList? {
        CatalogScope.canonicalList(
            lists: Array(lists), households: Array(households), selection: selection
        )
    }
    private var household: Household? { canonicalList?.household }
    private var scopedItems: [Item] { CatalogScope.items(Array(items), household: household) }
    private var scopedCategories: [Category] { CatalogScope.categories(Array(categories), household: household) }
    private var activeStores: [Store] {
        GroceryRowScope.validStores(Array(stores), canonicalList: canonicalList)
            .filter { !$0.isArchived }
    }
    private var visibleItems: [Item] {
        scopedItems.filter { projectedIDs.contains($0.id) && $0.isArchived == filters.showArchived }
    }
    private var hasNarrowing: Bool {
        !searchText.isEmpty || filters.selectedStoreID != nil || filters.count > 0
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterHeader
                List {
                    ForEach(visibleItems, id: \.objectID) { item in
                        Button { edit(item) } label: {
                            CatalogItemRow(item: item)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("shopping.catalog.item.\(item.id.uuidString)")
                    }
                }
                .contentMargins(.top, 0, for: .scrollContent)
                .overlay {
                    if visibleItems.isEmpty {
                        ContentUnavailableView {
                            Label(hasNarrowing ? "No matching items" : "No remembered items", systemImage: "books.vertical")
                        } description: {
                            Text(hasNarrowing ? "Your filters may hide saved items." : "Save items here to reuse their purchase tags.")
                        } actions: {
                            if hasNarrowing { Button("Reset filters", action: resetFilters) }
                            else { Button("New catalog item", action: create).disabled(household == nil) }
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("Catalog")
            .searchable(text: $searchText, prompt: "Search catalog")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New catalog item", systemImage: "plus", action: create)
                        .accessibilityIdentifier("shopping.catalog.add")
                        .disabled(household == nil || service == nil)
                }
            }
            .confirmationDialog("Available at store", isPresented: $showingStores, titleVisibility: .visible) {
                Button("All items") { filters.selectedStoreID = nil }
                ForEach(activeStores, id: \.objectID) { store in
                    Button(store.name) { filters.selectedStoreID = store.id }
                }
            }
            .sheet(isPresented: $showingFilters) {
                CatalogFiltersView(filters: $filters, stores: activeStores, categories: scopedCategories)
            }
            .sheet(item: $editor) { session in
                CatalogEditorView(session: session) { refresh() }
            }
            .alert("Couldn’t load catalog", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
            .onAppear(perform: refresh)
            .onChange(of: searchText) { _, _ in refresh() }
            .onChange(of: filters) { _, _ in refresh() }
            .onChange(of: selection) { _, _ in resetFilters() }
            .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: viewContext)) { _ in
                sanitizeFilters()
                refresh()
            }
        }
    }

    private var filterHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            PillFlowLayout {
                SelectionPill(
                    title: activeStores.first { $0.id == filters.selectedStoreID }
                        .map { "Available: \($0.name)" } ?? "All items",
                    isSelected: filters.selectedStoreID != nil,
                    systemImage: "storefront",
                    identifier: "shopping.catalog.available"
                ) { showingStores = true }
                SelectionPill(
                    title: "Filters\(filters.count == 0 ? "" : " (\(filters.count))")",
                    isSelected: filters.count > 0,
                    systemImage: "line.3.horizontal.decrease.circle",
                    identifier: "shopping.catalog.filters"
                ) { showingFilters = true }
            }
            if filters.count > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(activeStores.filter { filters.includedStoreIDs.contains($0.id) }, id: \.objectID) { store in
                            chip("Tagged: \(store.name)") { filters.includedStoreIDs.remove(store.id) }
                        }
                        ForEach(activeStores.filter { filters.excludedStoreIDs.contains($0.id) }, id: \.objectID) { store in
                            chip("Not tagged: \(store.name)") { filters.excludedStoreIDs.remove(store.id) }
                        }
                        if let category = scopedCategories.first(where: { $0.id == filters.categoryID }) {
                            chip(category.name) { filters.categoryID = nil }
                        }
                        if filters.showArchived { chip("Archived") { filters.showArchived = false } }
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func chip(_ title: String, remove: @escaping () -> Void) -> some View {
        SelectionPill(title: title, isSelected: true, systemImage: "xmark", action: remove)
            .accessibilityLabel("Remove filter: \(title)")
    }

    private func sanitizeFilters() {
        let ids = Set(activeStores.map(\.id))
        if let selected = filters.selectedStoreID, !ids.contains(selected) { filters.selectedStoreID = nil }
        filters.includedStoreIDs.formIntersection(ids)
        filters.excludedStoreIDs.formIntersection(ids)
        if let category = filters.categoryID, !scopedCategories.contains(where: { $0.id == category }) { filters.categoryID = nil }
    }

    private func refresh() {
        guard let service, let householdID = selection.householdID else { projectedIDs = []; return }
        do {
            projectedIDs = Set(try service.filteredCatalogItemIDs(
                householdID: householdID, filter: filters.query(text: searchText), includeArchived: filters.showArchived
            ))
        } catch { projectedIDs = []; errorMessage = CatalogErrorCopy.message(error) }
    }

    private func resetFilters() { searchText = ""; filters = CatalogFilterState(); refresh() }

    private func create() {
        guard household != nil else { return }
        editor = CatalogEditSession(selection: selection, itemID: nil, values: CatalogItemValues(
            name: searchText, notes: "", categoryID: nil,
            anyStore: false, storeIDs: filters.selectedStoreID.map { [$0] } ?? []
        ))
    }

    private func edit(_ item: Item) {
        editor = CatalogEditSession(selection: selection, itemID: item.id, values: item.catalogValues)
    }
}

private struct CatalogItemRow: View {
    @ObservedObject var item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name).foregroundStyle(.primary)
            Text(item.purchaseDescription).font(.caption).foregroundStyle(Color.grocerySecondary)
            if let category = item.category { Text(category.name).font(.caption).foregroundStyle(Color.grocerySecondary) }
            if !item.notes.isEmpty { Text(item.notes).font(.subheadline).foregroundStyle(Color.grocerySecondary) }
            if item.isArchived { Text("Archived").font(.caption).foregroundStyle(Color.grocerySecondary) }
        }
        .padding(.vertical, 3)
    }
}

private struct CatalogFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filters: CatalogFilterState
    let stores: [Store]
    let categories: [Category]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PillFlowLayout {
                        ForEach(stores, id: \.objectID) { store in
                            SelectionPill(
                                title: store.name,
                                isSelected: filters.includedStoreIDs.contains(store.id),
                                identifier: "shopping.catalog.filters.include.\(store.id.uuidString)"
                            ) { toggle(store.id, in: $filters.includedStoreIDs) }
                        }
                    }
                } header: { Text("Tagged (any selected)") } footer: {
                    Text("Match at least one explicit tag. Any store does not add tags.")
                }
                Section {
                    PillFlowLayout {
                        ForEach(stores, id: \.objectID) { store in
                            SelectionPill(
                                title: store.name,
                                isSelected: filters.excludedStoreIDs.contains(store.id),
                                identifier: "shopping.catalog.filters.exclude.\(store.id.uuidString)"
                            ) { toggle(store.id, in: $filters.excludedStoreIDs) }
                        }
                    }
                } header: { Text("Not tagged (none selected)") } footer: {
                    Text("Exclude every selected tag. Exclusions win over included tags.")
                }
                Section("Category") {
                    PillFlowLayout {
                        SelectionPill(title: "All categories", isSelected: filters.categoryID == nil) {
                            filters.categoryID = nil
                        }
                        ForEach(categories, id: \.objectID) { category in
                            SelectionPill(
                                title: category.name,
                                isSelected: filters.categoryID == category.id
                            ) { filters.categoryID = category.id }
                        }
                    }
                }
                Section {
                    SelectionPill(title: "Archived items", isSelected: filters.showArchived) {
                        filters.showArchived.toggle()
                    }
                    .accessibilityIdentifier("shopping.catalog.archived")
                    Button("Reset filters", systemImage: "arrow.counterclockwise") {
                        filters = CatalogFilterState()
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("shopping.catalog.reset")
                }
            }
            .navigationTitle("Catalog filters")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func toggle(_ id: UUID, in ids: Binding<Set<UUID>>) {
        if ids.wrappedValue.contains(id) { ids.wrappedValue.remove(id) }
        else { ids.wrappedValue.insert(id) }
    }
}

private struct CatalogEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.needService) private var service
    @Environment(\.hapticFeedback) private var hapticFeedback
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.items()) private var items: FetchedResults<Item>
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories: FetchedResults<Category>
    @FetchRequest(fetchRequest: PurchaseRulesStoreScope.listsRequest()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @State private var itemID: UUID?
    @State private var values: CatalogItemValues
    @State private var allowingNameCollision = false
    @State private var errorMessage: String?
    @State private var showingArchiveConfirmation = false
    @State private var requestedArchived = true
    let session: CatalogEditSession
    let onSaved: () -> Void

    init(session: CatalogEditSession, onSaved: @escaping () -> Void) {
        self.session = session
        self.onSaved = onSaved
        _itemID = State(initialValue: session.itemID)
        _values = State(initialValue: session.values)
    }

    private var household: Household? {
        CatalogScope.canonicalList(
            lists: Array(lists), households: Array(households), selection: session.selection
        )?.household
    }
    private var scopedItems: [Item] { CatalogScope.items(Array(items), household: household) }
    private var scopedCategories: [Category] { CatalogScope.categories(Array(categories), household: household) }
    private var currentItem: Item? { scopedItems.first { $0.id == itemID } }
    private var scopeAvailable: Bool { selection == session.selection && household != nil && service != nil }
    private var matches: [Item] {
        guard !CatalogProjection.normalizedName(values.name).isEmpty else { return [] }
        if let currentItem, CatalogProjection.normalizedName(currentItem.name) == CatalogProjection.normalizedName(values.name) { return [] }
        return scopedItems.filter { $0.id != itemID && CatalogProjection.textMatches($0.name, query: values.name) }
    }
    private var hasExactMatch: Bool {
        matches.contains { CatalogProjection.normalizedName($0.name) == CatalogProjection.normalizedName(values.name) }
    }
    private var canSave: Bool {
        scopeAvailable && !CatalogProjection.normalizedName(values.name).isEmpty &&
            (values.anyStore || !values.storeIDs.isEmpty) &&
            (itemID == nil || currentItem != nil) && (!hasExactMatch || allowingNameCollision)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Remembered item") {
                    TextField("Item name", text: $values.name).accessibilityIdentifier("shopping.catalog.name")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Item notes").font(.subheadline).fontWeight(.semibold)
                        TextField("Add reusable details", text: $values.notes, axis: .vertical)
                            .accessibilityIdentifier("shopping.catalog.notes")
                        Text("Reused whenever you add this item.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !matches.isEmpty {
                    Section("Existing items") {
                        ForEach(matches, id: \.objectID) { item in
                            Button(
                                "Edit \(item.name)\(item.isArchived ? " (archived)" : "")",
                                systemImage: "pencil"
                            ) {
                                itemID = item.id
                                values = item.catalogValues
                                allowingNameCollision = false
                                errorMessage = nil
                            }
                        }
                        if hasExactMatch {
                            Toggle("Create a distinct item", isOn: $allowingNameCollision)
                            Text("Use this for an intentional brand or size variant. Existing items stay separate.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                CategoryPills(
                    selection: $values.categoryID,
                    categories: scopedCategories,
                    includeUnavailable: true
                )
                PurchaseRulesPicker(
                    storeIDs: $values.storeIDs,
                    anyStore: $values.anyStore,
                    householdID: session.selection.householdID,
                    listID: session.selection.listID
                )
                if let item = currentItem {
                    Section {
                        Button(
                            item.isArchived ? "Restore item" : "Archive item",
                            systemImage: item.isArchived ? "arrow.uturn.backward" : "archivebox"
                        ) {
                            if item.isArchived && values == item.catalogValues { archive(false) }
                            else { requestedArchived = !item.isArchived; showingArchiveConfirmation = true }
                        }
                        .accessibilityIdentifier("shopping.catalog.archive")
                        .disabled(!scopeAvailable)
                        Text("Archiving hides this catalog item. Groceries already on your list stay there.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !scopeAvailable {
                    Text("This household is unavailable. Your draft is still here.")
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle(itemID == nil ? "New catalog item" : "Edit catalog item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("shopping.catalog.save")
                }
            }
            .onChange(of: values.name) { _, _ in allowingNameCollision = false }
            .alert(requestedArchived ? "Archive this catalog item?" : "Restore this catalog item?", isPresented: $showingArchiveConfirmation) {
                Button(requestedArchived ? "Archive item" : "Restore item") { archive(requestedArchived) }
                    .accessibilityIdentifier("shopping.catalog.confirmArchiveState")
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Current groceries and saved tags are preserved. Unsaved edits in this form will be discarded.")
            }
        }
    }

    private func save() {
        guard scopeAvailable, let service, let householdID = session.selection.householdID,
              let listID = session.selection.listID else { return }
        do {
            if let itemID {
                try service.saveCatalogItem(
                    itemID: itemID, householdID: householdID, listID: listID,
                    values: values, allowingNameCollision: allowingNameCollision
                )
            } else {
                _ = try service.createCatalogItem(
                    values: values, householdID: householdID, listID: listID,
                    allowingNameCollision: allowingNameCollision
                )
            }
            hapticFeedback.play(.success)
            onSaved()
            dismiss()
        } catch { errorMessage = CatalogErrorCopy.message(error) }
    }

    private func archive(_ archived: Bool) {
        guard scopeAvailable, let service, let householdID = session.selection.householdID,
              let listID = session.selection.listID, let itemID else { return }
        do {
            try service.setCatalogItemArchived(
                itemID: itemID, householdID: householdID, listID: listID,
                archived: archived
            )
            onSaved()
            dismiss()
        } catch { errorMessage = CatalogErrorCopy.message(error) }
    }
}

private extension Item {
    var catalogValues: CatalogItemValues {
        CatalogItemValues(name: name, notes: notes, categoryID: category?.id,
            anyStore: anyStore, storeIDs: Set(stores?.map(\.id) ?? []))
    }

    var purchaseDescription: String {
        let names = (stores ?? []).filter {
            !$0.isArchived && $0.id != PersistenceModel.unsetID && $0.household != nil &&
                $0.household == household && $0.objectID.persistentStore == objectID.persistentStore
        }.sorted(by: NeedService.storeDisplayOrder).map(\.name)
        if anyStore { return names.isEmpty ? "Any store" : "Any store · Tagged: \(names.joined(separator: ", "))" }
        if names.isEmpty { return "Needs store" }
        return "\(names.count == 1 ? "Only buy at" : "Buy at") \(names.joined(separator: ", "))"
    }
}

private enum CatalogErrorCopy {
    static func message(_ error: Error) -> String {
        switch error as? NeedServiceError {
        case .invalidName: return "Enter an item name."
        case .storeNotFound: return "Choose an active store or turn on Any store. Check for unavailable tags."
        case .categoryNotFound: return "Choose an available category or Uncategorized."
        case .catalogNameCollision: return "An item with this name already exists. Choose it or confirm a distinct item."
        case .scopeChanged, .householdNotFound, .listNotFound: return "The household or selected details changed. Review your draft and try again."
        case .itemNotFound: return "This catalog item is no longer available. Your draft has been kept."
        case .invalidCatalogIdentity, .invalidStoreIdentity: return "Some shared items have conflicting identities. Your draft has been kept."
        default: return error.localizedDescription
        }
    }
}

#Preview("Catalog · populated") { ShoppingPreviewHost(.populated) { CatalogView() } }
#Preview("Catalog · empty") { ShoppingPreviewHost(.empty) { CatalogView() } }
#Preview("Catalog · large text") {
    ShoppingPreviewHost(.largeText) { CatalogView().environment(\.dynamicTypeSize, .accessibility3) }
}
