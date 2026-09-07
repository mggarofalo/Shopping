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

enum CatalogGrouping: String, CaseIterable, Identifiable {
    case category
    case store
    case none

    var id: Self { self }
    var title: String {
        switch self {
        case .category: "Category"
        case .store: "Store"
        case .none: "None"
        }
    }
}

private struct CatalogItemGroup: Identifiable {
    let id: String
    let title: String?
    let items: [Item]
}

private struct CatalogGroupKey: Hashable {
    let id: String
    let title: String
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

private struct CatalogArchiveTarget {
    let itemID: UUID
    let householdID: UUID
    let listID: UUID
    let name: String
    let archived: Bool
}

private struct CatalogRemovalTarget {
    let itemID: UUID
    let householdID: UUID
    let listID: UUID
    let name: String
    let preview: CatalogRemovalPreview
}

private struct CatalogAddConfirmation: Identifiable {
    let id = UUID()
    let preview: CatalogAddPreview
    let itemName: String?
}

private struct CatalogAddNotice: Identifiable {
    let id = UUID()
    let message: String
    let needID: UUID?
}

struct CatalogView: View {
    @Environment(\.needService) private var service
    @Environment(\.hapticFeedback) private var hapticFeedback
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(fetchRequest: NavigationFetchRequests.items()) private var items: FetchedResults<Item>
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories: FetchedResults<Category>
    @FetchRequest(fetchRequest: NavigationFetchRequests.needs()) private var needs: FetchedResults<Need>
    @FetchRequest(fetchRequest: PurchaseRulesStoreScope.listsRequest()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @State private var searchText = ""
    @State private var filters = CatalogFilterState()
    @State private var projectedIDs: Set<UUID> = []
    @State private var showingFilters = false
    @State private var showingStores = false
    @State private var showingGrouping = false
    @State private var grouping = CatalogGrouping.category
    @State private var editor: CatalogEditSession?
    @State private var archiveTarget: CatalogArchiveTarget?
    @State private var removalTarget: CatalogRemovalTarget?
    @State private var removalNotice: String?
    @State private var errorMessage: String?
    @State private var selectedIDs: Set<UUID> = []
    @State private var editMode: EditMode = .inactive
    @State private var batchPreview: ManagementBatchPreview?
    @State private var batchNotice: String?
    @State private var addConfirmation: CatalogAddConfirmation?
    @State private var addNotice: CatalogAddNotice?
    @ObservedObject var navigation: GroceryNavigationState

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
    private var visibleGroups: [CatalogItemGroup] {
        let sortedItems = visibleItems.sorted(by: catalogItemComesFirst)
        switch grouping {
        case .none:
            return [CatalogItemGroup(id: "all", title: nil, items: sortedItems)]
        case .category:
            return groups(items: sortedItems) { categoryGroupKey(for: $0) }
        case .store:
            var grouped: [CatalogGroupKey: [Item]] = [:]
            for item in sortedItems {
                for key in storeGroupKeys(for: item) {
                    grouped[key, default: []].append(item)
                }
            }
            return catalogGroups(from: grouped)
        }
    }

    private func groups(items: [Item], key: (Item) -> CatalogGroupKey) -> [CatalogItemGroup] {
        catalogGroups(from: Dictionary(grouping: items, by: key))
    }

    private func catalogGroups(from grouped: [CatalogGroupKey: [Item]]) -> [CatalogItemGroup] {
        grouped.keys.sorted(by: groupComesFirst).map { key in
            CatalogItemGroup(id: key.id, title: key.title, items: grouped[key] ?? [])
        }
    }

    private func groupComesFirst(_ lhs: CatalogGroupKey, _ rhs: CatalogGroupKey) -> Bool {
        if alphabetically(lhs.title, rhs.title) { return true }
        if alphabetically(rhs.title, lhs.title) { return false }
        return lhs.id < rhs.id
    }

    private var hasNarrowing: Bool {
        !searchText.isEmpty || filters.selectedStoreID != nil || filters.count > 0
    }
    private var removalAction: CatalogRemovalAction? { removalTarget?.preview.action }
    private var removalDialogTitle: String {
        guard let target = removalTarget else { return "Remove catalog item?" }
        switch target.preview.action {
        case .archive: return "Archive \(target.name)?"
        case .keepArchived: return "Can’t delete \(target.name)"
        case .delete: return "Delete \(target.name)?"
        }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selectedIDs) {
                catalogListRows
            }
            .environment(\.editMode, $editMode)
            .listStyle(.insetGrouped)
            .contentMargins(.top, 0, for: .scrollContent)
            .accessibilityIdentifier("shopping.catalog.list")
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("Catalog")
            .searchable(text: $searchText, prompt: "Search catalog")
            .toolbar {
                if editMode.isEditing {
                    ToolbarItem(placement: .cancellationAction) { Button("Done", action: clearSelection) }
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Actions", systemImage: "ellipsis.circle") {
                            Button(selectedIDs == visibleItemIDs ? "Deselect All" : "Select All") {
                                selectedIDs = selectedIDs == visibleItemIDs ? [] : visibleItemIDs
                            }
                            Divider()
                            if selectedItems.contains(where: { !$0.isArchived }) {
                                Button("Add to list", systemImage: "cart.badge.plus") { prepareBatchAdd() }
                            }
                            if selectedItems.contains(where: { !$0.isArchived }) {
                                Button("Archive", systemImage: "archivebox") { prepareBatch(.archive) }
                            }
                            if selectedItems.contains(where: \.isArchived) {
                                Button("Restore", systemImage: "arrow.uturn.backward") { prepareBatch(.restore) }
                            }
                            if !selectedIDs.isEmpty {
                                Button("Delete", systemImage: "trash", role: .destructive) { prepareBatch(.delete) }
                            }
                        }
                        .accessibilityIdentifier("shopping.catalog.batchActions")
                    }
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New catalog item", systemImage: "plus", action: create)
                            .accessibilityIdentifier("shopping.catalog.add")
                            .disabled(household == nil || service == nil)
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Select") { editMode = .active }
                            .disabled(household == nil || service == nil || visibleItems.isEmpty)
                            .accessibilityIdentifier("shopping.catalog.select")
                    }
                }
            }
            .confirmationDialog("Available at store", isPresented: $showingStores, titleVisibility: .visible) {
                Button("All items") { filters.selectedStoreID = nil }
                ForEach(activeStores, id: \.objectID) { store in
                    Button(store.name) { filters.selectedStoreID = store.id }
                }
            }
            .confirmationDialog("Group catalog", isPresented: $showingGrouping, titleVisibility: .visible) {
                ForEach(CatalogGrouping.allCases) { choice in
                    Button(choice.title) { grouping = choice }
                }
            }
            .sheet(isPresented: $showingFilters) {
                CatalogFiltersView(filters: $filters, stores: activeStores, categories: scopedCategories)
            }
            .sheet(item: $editor) { session in
                CatalogEditorView(session: session) { refresh() }
            }
            .alert(archiveTarget?.archived == true ? "Archive catalog item?" : "Restore catalog item?",
                   isPresented: Binding(
                    get: { archiveTarget != nil }, set: { if !$0 { archiveTarget = nil } }
                   ), presenting: archiveTarget) { target in
                Button(target.archived ? "Archive" : "Restore") { applyArchive(target) }
                    .accessibilityIdentifier("shopping.catalog.confirmSwipeArchive")
                Button("Cancel", role: .cancel) {}
            } message: { target in
                Text(target.archived
                     ? "Hide \(target.name) from the catalog? Current groceries and saved details are kept. Restore it with the Archived items filter."
                     : "Show \(target.name) in the active catalog again?")
            }
            .confirmationDialog(
                removalDialogTitle,
                isPresented: Binding(
                    get: { removalTarget != nil }, set: { if !$0 { removalTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                if removalAction == .archive {
                    Button("Archive item", action: applyRemoval)
                } else if removalAction == .delete {
                    Button("Delete item", role: .destructive, action: applyRemoval)
                }
                Button(removalAction == .keepArchived ? "OK" : "Cancel", role: .cancel) {
                    removalTarget = nil
                }
            } message: {
                if removalAction == .archive {
                    Text("A grocery still uses this catalog item. Archiving keeps that grocery and its saved details available for recovery.")
                } else if removalAction == .keepArchived {
                    Text("A grocery still uses this archived item, so its saved details must remain available for recovery.")
                } else {
                    Text("This item has no grocery history and will be permanently removed from Catalog.")
                }
            }
            .alert("Catalog item archived", isPresented: Binding(
                get: { removalNotice != nil }, set: { if !$0 { removalNotice = nil } }
            )) {
                Button("OK", role: .cancel) { removalNotice = nil }
            } message: {
                Text(removalNotice ?? "")
            }
            .alert("Couldn’t load catalog", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
            .modifier(CatalogBatchDialogs(
                preview: $batchPreview, notice: $batchNotice, apply: applyBatch
            ))
            .modifier(CatalogAddDialogs(
                confirmation: $addConfirmation,
                notice: $addNotice,
                apply: applyCatalogAdd,
                viewNeed: viewNeed
            ))
            .onAppear(perform: refresh)
            .onChange(of: searchText) { _, _ in refreshAndSanitizeSelection() }
            .onChange(of: filters) { _, _ in refreshAndSanitizeSelection() }
            .onChange(of: selection) { _, _ in clearSelection(); resetFilters() }
            .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: viewContext)) { _ in
                sanitizeFilters()
                refreshAndSanitizeSelection()
            }
        }
    }

    @ViewBuilder
    private var catalogListRows: some View {
        Section {
            filterHeader
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
        }
        if visibleItems.isEmpty {
            Section {
                ContentUnavailableView {
                    Label(hasNarrowing ? "No matching items" : "No remembered items", systemImage: "books.vertical")
                } description: {
                    Text(hasNarrowing ? "Your filters may hide saved items." : "Save items here to reuse their purchase tags.")
                } actions: {
                    if hasNarrowing { Button("Reset filters", action: resetFilters) }
                    else { Button("New catalog item", action: create).disabled(household == nil) }
                }
                .listRowBackground(Color.clear)
            }
        } else {
            ForEach(visibleGroups) { group in
                Section {
                    ForEach(group.items, id: \.objectID) { item in catalogRow(item) }
                } header: {
                    if let title = group.title { Text(title) }
                }
            }
        }
    }

    private var visibleItemIDs: Set<UUID> { Set(visibleItems.map(\.id)) }
    private var selectedItems: [Item] { visibleItems.filter { selectedIDs.contains($0.id) } }

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
                SelectionPill(
                    title: "Group: \(grouping.title)",
                    isSelected: grouping != .none,
                    systemImage: "rectangle.3.group",
                    identifier: "shopping.catalog.grouping"
                ) { showingGrouping = true }
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

    private func catalogRow(_ item: Item) -> AnyView {
        AnyView(HStack(spacing: 8) {
            Button {
                if !editMode.isEditing { edit(item) }
            } label: {
                CatalogItemRow(item: item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("shopping.catalog.item.\(item.id.uuidString)")
            if !editMode.isEditing && !item.isArchived {
                Button { prepareIndividualAdd(item) } label: {
                    Label("Add \(item.name) to list", systemImage: "cart.badge.plus")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("shopping.catalog.addToList.\(item.id.uuidString)")
            }
        }
        .shoppingListRowInsets()
        .tag(item.id)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { prepareArchive(item) } label: {
                Image(systemName: item.isArchived ? "arrow.uturn.backward" : "archivebox")
                    .font(.caption2)
            }
            .tint(item.isArchived ? .green : .orange)
            .accessibilityLabel(item.isArchived ? "Restore" : "Archive")
            .accessibilityIdentifier("shopping.catalog.swipeArchive.\(item.id.uuidString)")
            Button(role: .destructive) { prepareRemoval(item) } label: {
                Image(systemName: "trash").font(.caption2)
            }
            .tint(.red)
            .accessibilityLabel("Delete")
            .accessibilityIdentifier("shopping.catalog.swipeDelete.\(item.id.uuidString)")
        }
        .accessibilityAction(named: Text(item.isArchived ? "Restore" : "Archive")) {
            prepareArchive(item)
        }
        .catalogAddAccessibilityAction(
            enabled: !editMode.isEditing && !item.isArchived,
            name: item.name
        ) { prepareIndividualAdd(item) }
        .accessibilityAction(named: Text("Delete \(item.name)")) {
            prepareRemoval(item)
        })
    }

    private func catalogItemComesFirst(_ lhs: Item, _ rhs: Item) -> Bool {
        if alphabetically(lhs.name, rhs.name) { return true }
        if alphabetically(rhs.name, lhs.name) { return false }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func alphabetically(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(
            rhs, options: [.caseInsensitive, .diacriticInsensitive, .numeric], locale: .current
        ) == .orderedAscending
    }

    private func categoryGroupKey(for item: Item) -> CatalogGroupKey {
        guard let category = item.category else {
            return CatalogGroupKey(id: "category:none", title: "Uncategorized")
        }
        guard scopedCategories.contains(category) else {
            return CatalogGroupKey(id: "category:unavailable", title: "Unavailable category")
        }
        return CatalogGroupKey(id: "category:\(category.id.uuidString)", title: category.name)
    }

    private func storeGroupKeys(for item: Item) -> [CatalogGroupKey] {
        if item.anyStore || (item.stores ?? []).isEmpty {
            return [CatalogGroupKey(id: "store:any", title: "Any store")]
        }
        let tagged = item.stores ?? []
        let validStores = GroceryRowScope.validStores(Array(stores), canonicalList: canonicalList)
        var keys = validStores.filter { tagged.contains($0) }.map {
            CatalogGroupKey(id: "store:\($0.id.uuidString)", title: $0.name)
        }
        if keys.count < tagged.count {
            keys.append(CatalogGroupKey(id: "store:unavailable", title: "Unavailable stores"))
        }
        return keys.isEmpty
            ? [CatalogGroupKey(id: "store:unavailable", title: "Unavailable stores")]
            : keys
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

    private func refreshAndSanitizeSelection() {
        refresh()
        selectedIDs.formIntersection(visibleItemIDs)
    }

    private func resetFilters() { searchText = ""; filters = CatalogFilterState(); refresh() }

    private func create() {
        guard household != nil else { return }
        editor = CatalogEditSession(selection: selection, itemID: nil, values: CatalogItemValues(
            name: searchText, notes: "", categoryID: nil,
            anyStore: filters.selectedStoreID == nil, storeIDs: filters.selectedStoreID.map { [$0] } ?? []
        ))
    }

    private func edit(_ item: Item) {
        editor = CatalogEditSession(selection: selection, itemID: item.id, values: item.catalogValues)
    }

    private func prepareArchive(_ item: Item) {
        guard let list = canonicalList, let householdID = list.household?.id,
              scopedItems.contains(item), service != nil else { return }
        archiveTarget = CatalogArchiveTarget(
            itemID: item.id, householdID: householdID, listID: list.id,
            name: item.name, archived: !item.isArchived
        )
    }

    private func applyArchive(_ target: CatalogArchiveTarget) {
        guard let service, selection.householdID == target.householdID,
              selection.listID == target.listID, canonicalList != nil else {
            errorMessage = "Return to the household where you started this change."
            return
        }
        do {
            try service.setCatalogItemArchived(
                itemID: target.itemID, householdID: target.householdID,
                listID: target.listID, archived: target.archived
            )
            refresh()
        } catch { errorMessage = CatalogErrorCopy.message(error) }
    }

    private func prepareRemoval(_ item: Item) {
        guard let service, let list = canonicalList, let householdID = list.household?.id,
              scopedItems.contains(item) else { return }
        do {
            let preview = try service.catalogItemRemovalPreview(
                itemID: item.id, householdID: householdID, listID: list.id
            )
            removalTarget = CatalogRemovalTarget(
                itemID: item.id, householdID: householdID, listID: list.id,
                name: item.name, preview: preview
            )
        } catch { errorMessage = CatalogErrorCopy.message(error) }
    }

    private func applyRemoval() {
        guard let target = removalTarget, let service,
              selection.householdID == target.householdID,
              selection.listID == target.listID, canonicalList != nil else {
            removalTarget = nil
            errorMessage = "Return to the household where you started this change."
            return
        }
        do {
            guard target.preview.action != .keepArchived else {
                removalTarget = nil
                return
            }
            let appliedAction = try service.removeCatalogItem(
                itemID: target.itemID, householdID: target.householdID,
                listID: target.listID, preview: target.preview
            )
            hapticFeedback.play(.warning)
            removalTarget = nil
            refresh()
            if target.preview.action == .delete, appliedAction == .archive {
                removalNotice = "A grocery began using this item, so it was archived instead of permanently deleted."
            }
        } catch {
            removalTarget = nil
            errorMessage = CatalogErrorCopy.message(error)
        }
    }

    private func prepareBatch(_ action: ManagementBatchAction) {
        guard let service, let list = canonicalList, let householdID = list.household?.id else { return }
        do {
            batchPreview = try service.captureManagementBatch(
                entity: .catalogItem, action: action, ids: selectedIDs,
                householdID: householdID, listID: list.id
            )
        } catch { errorMessage = CatalogErrorCopy.message(error) }
    }

    private func prepareIndividualAdd(_ item: Item) {
        guard let preview = captureCatalogAdd(ids: [item.id]) else { return }
        guard let entry = preview.token.entries.first else {
            addNotice = CatalogAddNotice(message: "This catalog item is no longer available.", needID: nil)
            return
        }
        switch entry.disposition {
        case .add:
            applyCatalogAdd(preview.token, renewCarted: false)
        case .focusExisting:
            let result = applyCatalogAddResult(preview.token, renewCarted: false)
            if let id = result?.existingNeedIDs.first { viewNeed(id) }
        case .needAgain:
            addConfirmation = CatalogAddConfirmation(preview: preview, itemName: item.name)
        case .archived:
            addNotice = CatalogAddNotice(message: "Restore this catalog item before adding it.", needID: nil)
        case .ineligible:
            addNotice = CatalogAddNotice(message: "This item is not available for the selected store.", needID: nil)
        }
    }

    private func prepareBatchAdd() {
        guard let preview = captureCatalogAdd(ids: selectedIDs) else { return }
        addConfirmation = CatalogAddConfirmation(preview: preview, itemName: nil)
    }

    private func captureCatalogAdd(ids: Set<UUID>) -> CatalogAddPreview? {
        guard let service, let list = canonicalList, let householdID = list.household?.id else { return nil }
        do {
            return try service.captureCatalogAdd(
                itemIDs: ids, householdID: householdID, listID: list.id,
                selectedStoreID: filters.selectedStoreID
            )
        } catch {
            errorMessage = CatalogErrorCopy.message(error)
            return nil
        }
    }

    private func applyCatalogAdd(_ token: CatalogAddToken) {
        _ = applyCatalogAddResult(token, renewCarted: true)
    }

    private func applyCatalogAdd(_ token: CatalogAddToken, renewCarted: Bool) {
        _ = applyCatalogAddResult(token, renewCarted: renewCarted)
    }

    private func applyCatalogAddResult(_ token: CatalogAddToken, renewCarted: Bool) -> CatalogAddResult? {
        guard let service, selection.householdID == token.householdID,
              selection.listID == token.listID else {
            addConfirmation = nil
            clearSelection()
            addNotice = CatalogAddNotice(message: "The household changed. Select the items again.", needID: nil)
            return nil
        }
        do {
            let result = try service.applyCatalogAdd(token, renewCarted: renewCarted)
            addConfirmation = nil
            clearSelection()
            let visibleNeedID = result.addedNeedIDs.first ?? result.renewedNeedIDs.first
            addNotice = CatalogAddNotice(message: CatalogAddCopy.result(result), needID: visibleNeedID)
            hapticFeedback.play(result.addedNeedIDs.isEmpty && result.renewedNeedIDs.isEmpty ? .lightImpact : .success)
            return result
        } catch {
            addConfirmation = nil
            errorMessage = CatalogErrorCopy.message(error)
            return nil
        }
    }

    private func viewNeed(_ id: UUID) {
        addNotice = nil
        navigation.requestNeedFocus(id)
    }

    private func applyBatch(_ token: ManagementBatchToken) {
        guard let service, selection.householdID == token.householdID, selection.listID == token.listID else {
            batchPreview = nil; clearSelection(); return
        }
        do {
            let result = try service.applyManagementBatch(token)
            batchPreview = nil
            clearSelection()
            refresh()
            batchNotice = ManagementBatchCopy.result(result)
            hapticFeedback.play(token.action == .delete ? .warning : .success)
        } catch { batchPreview = nil; errorMessage = CatalogErrorCopy.message(error) }
    }

    private func clearSelection() { selectedIDs = []; editMode = .inactive }

}

private extension View {
    @ViewBuilder
    func catalogAddAccessibilityAction(
        enabled: Bool,
        name: String,
        action: @escaping () -> Void
    ) -> some View {
        if enabled {
            accessibilityAction(named: Text("Add \(name) to list"), action)
        } else {
            self
        }
    }
}

private struct CatalogBatchDialogs: ViewModifier {
    @Binding var preview: ManagementBatchPreview?
    @Binding var notice: String?
    let apply: (ManagementBatchToken) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                preview.map(ManagementBatchCopy.title) ?? "Update selected catalog items?",
                isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } }),
                titleVisibility: .visible
            ) {
                if let preview {
                    switch preview.token.action {
                    case .archive: Button("Archive") { apply(preview.token) }
                    case .restore: Button("Restore") { apply(preview.token) }
                    case .delete: Button("Delete", role: .destructive) { apply(preview.token) }
                    }
                }
                Button("Cancel", role: .cancel) { preview = nil }
            } message: {
                if let preview { Text(ManagementBatchCopy.message(preview)) }
            }
            .alert("Batch update complete", isPresented: Binding(
                get: { notice != nil }, set: { if !$0 { notice = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(notice ?? "") }
    }
}

private enum CatalogAddCopy {
    static func preview(_ value: CatalogAddPreview) -> String {
        var parts: [String] = []
        if value.addCount > 0 { parts.append("\(value.addCount) will be added") }
        if value.existingCount > 0 { parts.append("\(value.existingCount) already on the list will be kept") }
        if value.needAgainCount > 0 { parts.append("\(value.needAgainCount) in the cart will be needed again") }
        if value.archivedCount > 0 { parts.append("\(value.archivedCount) archived will be skipped") }
        if value.ineligibleCount > 0 { parts.append("\(value.ineligibleCount) unavailable at this store will be skipped") }
        return (parts.isEmpty ? "No selected items are available" : parts.joined(separator: ". "))
            + ". Changes made after this review will be skipped."
    }

    static func result(_ value: CatalogAddResult) -> String {
        var parts: [String] = []
        if !value.addedNeedIDs.isEmpty { parts.append("Added \(value.addedNeedIDs.count)") }
        if !value.renewedNeedIDs.isEmpty { parts.append("Needed again \(value.renewedNeedIDs.count)") }
        if !value.existingNeedIDs.isEmpty { parts.append("Already on list \(value.existingNeedIDs.count)") }
        if value.archivedCount > 0 { parts.append("Skipped \(value.archivedCount) archived") }
        if value.ineligibleCount > 0 { parts.append("Skipped \(value.ineligibleCount) unavailable at this store") }
        if value.changedCount > 0 { parts.append("Skipped \(value.changedCount) changed") }
        if value.missingCount > 0 { parts.append("Skipped \(value.missingCount) unavailable") }
        return parts.isEmpty ? "No catalog items were added." : parts.joined(separator: ". ") + "."
    }
}

private struct CatalogAddDialogs: ViewModifier {
    @Binding var confirmation: CatalogAddConfirmation?
    @Binding var notice: CatalogAddNotice?
    let apply: (CatalogAddToken) -> Void
    let viewNeed: (UUID) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                confirmation?.itemName.map { "Need \($0) again?" } ?? "Add selected items to list?",
                isPresented: Binding(
                    get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let confirmation {
                    Button(confirmation.itemName == nil ? "Add to list" : "Need again") {
                        apply(confirmation.preview.token)
                    }
                }
                Button("Cancel", role: .cancel) { confirmation = nil }
            } message: {
                if let confirmation { Text(CatalogAddCopy.preview(confirmation.preview)) }
            }
            .alert("Catalog update complete", isPresented: Binding(
                get: { notice != nil }, set: { if !$0 { notice = nil } }
            )) {
                if let id = notice?.needID { Button("View in groceries") { viewNeed(id) } }
                Button("OK", role: .cancel) { notice = nil }
            } message: { Text(notice?.message ?? "") }
    }
}

private struct CatalogItemRow: View {
    @ObservedObject var item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name).foregroundStyle(.primary)
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
    @State private var showingCategoryCreation = false
    @State private var showingStoreCreation = false
    @State private var requestedArchived = true
    @FocusState private var nameIsFocused: Bool
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
            (itemID == nil || currentItem != nil) && (!hasExactMatch || allowingNameCollision)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Remembered item") {
                    TextField("Item name", text: $values.name)
                        .accessibilityIdentifier("shopping.catalog.name")
                        .focused($nameIsFocused)
                        .submitLabel(.done)
                        .onSubmit { nameIsFocused = false }
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
                                nameIsFocused = false
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
                    includeUnavailable: true,
                    onAddCategory: { showingCategoryCreation = true }
                )
                PurchaseRulesPicker(
                    storeIDs: $values.storeIDs,
                    anyStore: $values.anyStore,
                    householdID: session.selection.householdID,
                    listID: session.selection.listID,
                    onAddStore: { showingStoreCreation = true }
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
            .onAppear {
                guard session.itemID == nil else { return }
                DispatchQueue.main.async { nameIsFocused = true }
            }
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
            .sheet(isPresented: $showingCategoryCreation) {
                CategoryCreationView(
                    householdID: session.selection.householdID,
                    listID: session.selection.listID
                ) { values.categoryID = $0 }
            }
            .sheet(isPresented: $showingStoreCreation) {
                StoreCreationView(
                    householdID: session.selection.householdID,
                    listID: session.selection.listID
                ) { id in
                    if values.storeIDs.isEmpty { values.anyStore = false }
                    values.storeIDs.insert(id)
                }
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

#Preview("Catalog · populated") { ShoppingPreviewHost(.populated) { CatalogView(navigation: GroceryNavigationState()) } }
#Preview("Catalog · empty") { ShoppingPreviewHost(.empty) { CatalogView(navigation: GroceryNavigationState()) } }
#Preview("Catalog · large text") {
    ShoppingPreviewHost(.largeText) {
        CatalogView(navigation: GroceryNavigationState()).environment(\.dynamicTypeSize, .accessibility3)
    }
}
