import CoreData
import os
import SwiftUI

private struct CatalogItemGroup: Identifiable {
    let id: String
    let title: String?
    let items: [Item]
}

private struct CatalogGroupKey: Hashable {
    let id: String
    let title: String
    let order: Int64
}

struct CatalogView: View {
    @Environment(\.needService) private var service
    @Environment(\.hapticFeedback) private var hapticFeedback
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.shoppingToastCenter) private var toastCenter
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
    @State private var showingGrouping = false
    @State private var grouping = CatalogGrouping.category
    @State private var renderedGroups: [CatalogItemGroup] = []
    @State private var editor: CatalogEditSession?
    @State private var removalTarget: CatalogRemovalTarget?
    @State private var removalNotice: String?
    @State private var errorMessage: String?
    @State private var selectedIDs: Set<UUID> = []
    @State private var editMode: EditMode = .inactive
    @State private var batchPreview: ManagementBatchPreview?
    @State private var addConfirmation: CatalogAddConfirmation?
    @ObservedObject var navigation: GroceryNavigationState

    private var canonicalList: GroceryList? {
        CatalogScope.canonicalList(
            lists: Array(lists), households: Array(households), selection: selection
        )
    }
    private var household: Household? { canonicalList?.household }
    private var scopedItems: [Item] { CatalogScope.items(Array(items), household: household) }
    private var scopedCategories: [Category] { CatalogScope.categories(Array(categories), household: household) }
    private var activeCategories: [Category] { scopedCategories.filter { !$0.isArchived } }
    private var validStores: [Store] {
        GroceryRowScope.validStores(Array(stores), canonicalList: canonicalList)
    }
    private var activeStores: [Store] {
        validStores.filter { !$0.isArchived }
    }
    private var visibleItems: [Item] {
        scopedItems.filter { projectedIDs.contains($0.id) && $0.isArchived == filters.showArchived }
    }
    private var catalogRefreshKeys: [CatalogRefreshKey] {
        scopedItems.map { CatalogRefreshKey(id: $0.id, revision: $0.revision, archived: $0.isArchived) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private func makeVisibleGroups(from items: [Item]) -> [CatalogItemGroup] {
        let signpostID = OSSignpostID(log: ShoppingPerformanceTrace.log)
        os_signpost(.begin, log: ShoppingPerformanceTrace.log, name: "Catalog grouping", signpostID: signpostID)
        defer { os_signpost(.end, log: ShoppingPerformanceTrace.log, name: "Catalog grouping", signpostID: signpostID) }
        let sortedItems = items.sorted(by: catalogItemComesFirst)
        switch grouping {
        case .none:
            return [CatalogItemGroup(id: "all", title: nil, items: sortedItems)]
        case .category:
            let validCategoryIDs = Set(scopedCategories.map(\.id))
            return groups(items: sortedItems) {
                categoryGroupKey(for: $0, validCategoryIDs: validCategoryIDs)
            }
        case .store:
            var grouped: [CatalogGroupKey: [Item]] = [:]
            for item in sortedItems {
                for key in storeGroupKeys(for: item, validStores: validStores) {
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
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        return lhs.id < rhs.id
    }

    private var hasNarrowing: Bool {
        !searchText.isEmpty || filters.count > 0
    }
    private var removalAction: CatalogRemovalAction? { removalTarget?.preview.action }
    private var removalTargetPresented: Binding<Bool> {
        Binding(get: { removalTarget != nil }, set: { if !$0 { removalTarget = nil } })
    }
    private var removalNoticePresented: Binding<Bool> {
        Binding(get: { removalNotice != nil }, set: { if !$0 { removalNotice = nil } })
    }
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
            .listStyle(.plain)
            .contentMargins(.top, 0, for: .scrollContent)
            .accessibilityIdentifier("shopping.catalog.list")
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(editMode.isEditing ? "\(selectedIDs.count) Selected" : "Catalog")
            .searchable(text: $searchText, prompt: "Search catalog")
            .toolbar {
                if editMode.isEditing {
                    ToolbarItem(placement: .cancellationAction) { Button("Done", action: clearSelection) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(selectedIDs == visibleItemIDs ? "Deselect All" : "Select All") {
                            selectedIDs = selectedIDs == visibleItemIDs ? [] : visibleItemIDs
                        }
                        .accessibilityIdentifier("shopping.catalog.selectAll")
                    }
                } else {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Select") { editMode = .active }
                            .disabled(household == nil || service == nil || visibleItems.isEmpty)
                            .accessibilityIdentifier("shopping.catalog.select")
                        Button("New catalog item", systemImage: "plus", action: create)
                            .accessibilityIdentifier("shopping.catalog.add")
                            .disabled(household == nil || service == nil)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if editMode.isEditing {
                        Divider()
                        HStack(spacing: 4) {
                            Button("Delete", systemImage: "trash", role: .destructive) { prepareBatch(.delete) }
                                .tint(.red)
                                .disabled(selectedIDs.isEmpty)
                                .accessibilityIdentifier("shopping.catalog.batchDelete")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        Button("Archive", systemImage: "archivebox") { prepareBatch(.archive) }
                        .disabled(!selectedItems.contains(where: { !$0.isArchived }))
                        .accessibilityIdentifier("shopping.catalog.batchArchive")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        Button("Restore", systemImage: "arrow.uturn.backward") { prepareBatch(.restore) }
                            .disabled(!selectedItems.contains(where: \.isArchived))
                            .accessibilityIdentifier("shopping.catalog.batchRestore")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            Button("Add", systemImage: "note.text.badge.plus") { prepareBatchAdd() }
                                .disabled(!selectedItems.contains(where: { !$0.isArchived }))
                                .accessibilityIdentifier("shopping.catalog.batchAdd")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .labelStyle(.iconOnly)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.bar)
                    }
                }
            }
            .confirmationDialog("Group catalog", isPresented: $showingGrouping, titleVisibility: .visible) {
                ForEach(CatalogGrouping.allCases) { choice in
                    Button(choice.title) { grouping = choice }
                }
            }
            .sheet(isPresented: $showingFilters) {
                CatalogFiltersView(filters: $filters, stores: activeStores, categories: activeCategories)
            }
            .sheet(item: $editor) { session in
                CatalogEditorView(session: session, onSaved: refresh) { itemID in
                    if let item = scopedItems.first(where: { $0.id == itemID }) { prepareIndividualAdd(item) }
                }
            }
            .confirmationDialog(
                removalDialogTitle,
                isPresented: removalTargetPresented,
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
            .alert("Catalog item archived", isPresented: removalNoticePresented) {
                Button("OK", role: .cancel) { removalNotice = nil }
            } message: {
                Text(removalNotice ?? "")
            }
            .modifier(CatalogBatchDialogs(
                preview: $batchPreview, apply: applyBatch
            ))
            .modifier(CatalogAddDialogs(
                confirmation: $addConfirmation,
                apply: applyCatalogAdd
            ))
            .onAppear(perform: refresh)
            .onChange(of: searchText) { _, _ in refreshAndSanitizeSelection() }
            .onChange(of: filters) { _, _ in refreshAndSanitizeSelection() }
            .onChange(of: grouping) { _, _ in rebuildRenderedGroups() }
            .onChange(of: catalogRefreshKeys) { _, _ in refreshAndSanitizeSelection() }
            .onChange(of: selection) { _, _ in clearSelection(); resetFilters() }
            .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: viewContext)) { _ in
                sanitizeFilters()
                refreshAndSanitizeSelection()
            }
            .onDisappear(perform: clearSelection)
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
                    Text(hasNarrowing ? "Your filters may hide saved items." : "Save items here to reuse their purchase rules.")
                } actions: {
                    if hasNarrowing { Button("Reset filters", action: resetFilters) }
                    else { Button("New catalog item", action: create).disabled(household == nil) }
                }
                .listRowBackground(Color.clear)
            }
        } else {
            ForEach(renderedGroups) { group in
                Section {
                    ForEach(group.items, id: \.objectID) { item in
                        if editMode.isEditing {
                            CatalogItemRow(item: item, grouping: grouping, validStores: validStores)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                                .shoppingListRowInsets()
                                .tag(item.id)
                                .accessibilityIdentifier("shopping.catalog.item.\(item.id.uuidString)")
                        } else {
                            catalogRow(item)
                                .tag(item.id)
                        }
                    }
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
                            chip("Includes: \(store.name)") { filters.includedStoreIDs.remove(store.id) }
                        }
                        ForEach(activeStores.filter { filters.excludedStoreIDs.contains($0.id) }, id: \.objectID) { store in
                            chip("Excludes: \(store.name)") { filters.excludedStoreIDs.remove(store.id) }
                        }
                        ForEach(activeCategories.filter { filters.categoryIDs.contains($0.id) }, id: \.objectID) { category in
                            chip(category.name) { filters.categoryIDs.remove(category.id) }
                        }
                        if filters.showArchived { chip("Archived") { filters.showArchived = false } }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func catalogRow(_ item: Item) -> some View {
        Button { edit(item) } label: {
            CatalogItemRow(item: item, grouping: grouping, validStores: validStores)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("shopping.catalog.item.\(item.id.uuidString)")
        .shoppingListRowInsets()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !item.isArchived {
                Button { prepareIndividualCart(item) } label: {
                    Label("Add to cart", systemImage: "cart.badge.plus").labelStyle(.iconOnly)
                }
                .tint(.indigo)
                .accessibilityIdentifier("shopping.catalog.addToCart.\(item.id.uuidString)")
                Button { prepareIndividualAdd(item) } label: {
                    Label("Add to list", systemImage: "note.text.badge.plus").labelStyle(.iconOnly)
                }
                .tint(.green)
                .accessibilityIdentifier("shopping.catalog.addToList.\(item.id.uuidString)")
            }
            Button { edit(item) } label: {
                Label("Edit", systemImage: "pencil").labelStyle(.iconOnly)
            }
            .tint(.blue)
            Button { prepareArchive(item) } label: {
                Label(item.isArchived ? "Restore" : "Archive", systemImage: item.isArchived ? "arrow.uturn.backward" : "archivebox").labelStyle(.iconOnly)
            }
            .tint(item.isArchived ? .green : .orange)
            .accessibilityLabel(item.isArchived ? "Restore" : "Archive")
            .accessibilityIdentifier("shopping.catalog.swipeArchive.\(item.id.uuidString)")
            Button(role: .destructive) { prepareRemoval(item) } label: {
                Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
            }
            .tint(.red)
            .accessibilityIdentifier("shopping.catalog.swipeDelete.\(item.id.uuidString)")
        }
        .contextMenu {
            Button("Select", systemImage: "checkmark.circle") { beginSelection(with: item.id) }
                .accessibilityIdentifier("shopping.catalog.contextSelect.\(item.id.uuidString)")
            Button("Edit", systemImage: "pencil") { edit(item) }
            if !item.isArchived {
                Button("Add to List", systemImage: "note.text.badge.plus") { prepareIndividualAdd(item) }
            }
            Button(item.isArchived ? "Restore" : "Archive",
                   systemImage: item.isArchived ? "arrow.uturn.backward" : "archivebox") {
                prepareArchive(item)
            }
            Button("Delete", systemImage: "trash", role: .destructive) { prepareRemoval(item) }
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
        }
    }

    private func catalogItemComesFirst(_ lhs: Item, _ rhs: Item) -> Bool {
        if alphabetically(lhs.name, rhs.name) { return true }
        if alphabetically(rhs.name, lhs.name) { return false }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func beginSelection(with itemID: UUID) {
        guard !editMode.isEditing, household != nil, service != nil,
              visibleItemIDs.contains(itemID) else { return }
        selectedIDs = [itemID]
        editMode = .active
    }

    private func alphabetically(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(
            rhs, options: [.caseInsensitive, .diacriticInsensitive, .numeric], locale: .current
        ) == .orderedAscending
    }

    private func categoryGroupKey(
        for item: Item,
        validCategoryIDs: Set<UUID>
    ) -> CatalogGroupKey {
        guard let category = item.category else {
            return CatalogGroupKey(id: "category:none", title: "Uncategorized", order: Int64.max - 1)
        }
        guard validCategoryIDs.contains(category.id) else {
            return CatalogGroupKey(id: "category:unavailable", title: "Unavailable category", order: Int64.max)
        }
        return CatalogGroupKey(
            id: "category:\(category.id.uuidString)", title: category.name, order: category.displayOrder
        )
    }

    private func storeGroupKeys(for item: Item, validStores: [Store]) -> [CatalogGroupKey] {
        if item.anyStore || (item.stores ?? []).isEmpty {
            return [CatalogGroupKey(id: "store:any", title: "Any store", order: -1)]
        }
        let assignedStores = item.stores ?? []
        var keys = validStores.filter { assignedStores.contains($0) }.map {
            CatalogGroupKey(id: "store:\($0.id.uuidString)", title: $0.name, order: $0.displayOrder)
        }
        if keys.count < assignedStores.count {
            keys.append(CatalogGroupKey(id: "store:unavailable", title: "Unavailable stores", order: Int64.max))
        }
        return keys.isEmpty
            ? [CatalogGroupKey(id: "store:unavailable", title: "Unavailable stores", order: Int64.max)]
            : keys
    }

    private func chip(_ title: String, remove: @escaping () -> Void) -> some View {
        SelectionPill(title: title, isSelected: true, systemImage: "xmark", action: remove)
            .accessibilityLabel("Remove filter: \(title)")
    }

    private func sanitizeFilters() {
        let ids = Set(activeStores.map(\.id))
        filters.includedStoreIDs.formIntersection(ids)
        filters.excludedStoreIDs.formIntersection(ids)
        filters.categoryIDs.formIntersection(Set(activeCategories.map(\.id)))
    }

    private func refresh() {
        guard let service, let householdID = selection.householdID else {
            projectedIDs = []
            renderedGroups = []
            return
        }
        do {
            let refreshedIDs = Set(try service.filteredCatalogItemIDs(
                householdID: householdID, filter: filters.query(text: searchText), includeArchived: filters.showArchived
            ))
            projectedIDs = refreshedIDs
            rebuildRenderedGroups(projectedIDs: refreshedIDs)
        } catch {
            projectedIDs = []
            renderedGroups = []
            errorMessage = CatalogErrorCopy.message(error)
        }
    }

    private func rebuildRenderedGroups(projectedIDs ids: Set<UUID>? = nil) {
        let ids = ids ?? projectedIDs
        let items = scopedItems.filter {
            ids.contains($0.id) && $0.isArchived == filters.showArchived
        }
        renderedGroups = makeVisibleGroups(from: items)
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
            anyStore: true, storeIDs: []
        ))
    }

    private func edit(_ item: Item) {
        editor = CatalogEditSession(selection: selection, itemID: item.id, values: item.catalogValues)
    }

    private func prepareArchive(_ item: Item) {
        guard let list = canonicalList, let householdID = list.household?.id,
              scopedItems.contains(item), service != nil else { return }
        let target = CatalogArchiveTarget(
            itemID: item.id, householdID: householdID, listID: list.id,
            archived: !item.isArchived
        )
        applyArchive(target)
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
            let preview = try service.captureManagementBatch(
                entity: .catalogItem, action: action, ids: selectedIDs,
                householdID: householdID, listID: list.id
            )
            if action == .delete {
                batchPreview = preview
            } else {
                applyBatch(preview.token)
            }
        } catch { errorMessage = CatalogErrorCopy.message(error) }
    }

    private func prepareIndividualAdd(_ item: Item) {
        guard let preview = captureCatalogAdd(ids: [item.id]) else { return }
        guard let entry = preview.token.entries.first else {
            showCatalogNotice("This catalog item is no longer available.", duration: .attention)
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
            showCatalogNotice("Restore this catalog item before adding it.", duration: .attention)
        case .ineligible:
            showCatalogNotice(
                "This item is not available for the selected store.",
                duration: .attention
            )
        }
    }

    private func prepareBatchAdd() {
        guard let preview = captureCatalogAdd(ids: selectedIDs) else { return }
        addConfirmation = CatalogAddConfirmation(preview: preview, itemName: nil)
    }

    private func prepareIndividualCart(_ item: Item) {
        guard let preview = captureCatalogAdd(ids: [item.id]) else { return }
        guard let entry = preview.token.entries.first else { return }
        switch entry.disposition {
        case .archived:
            showCatalogNotice("Restore this catalog item before adding it.", duration: .attention)
        case .ineligible:
            showCatalogNotice(
                "This item is not available for the selected store.",
                duration: .attention
            )
        default:
            applyCatalogAddToCart(preview.token)
        }
    }

    private func applyCatalogAddToCart(_ token: CatalogAddToken) {
        guard let service, selection.householdID == token.householdID, selection.listID == token.listID else { return }
        do {
            let result = try service.applyCatalogAdd(token, renewCarted: false, destination: .cart)
            let count = result.addedNeedIDs.count + result.existingNeedIDs.count
            showCatalogNotice(
                count == 0 ? "No item was added to cart." : "Added to cart.",
                duration: count == 0 ? .attention : .success
            )
            hapticFeedback.play(count == 0 ? .lightImpact : .success)
        } catch { errorMessage = CatalogErrorCopy.message(error) }
    }

    private func captureCatalogAdd(ids: Set<UUID>) -> CatalogAddPreview? {
        guard let service, let list = canonicalList, let householdID = list.household?.id else { return nil }
        do {
            return try service.captureCatalogAdd(
                itemIDs: ids, householdID: householdID, listID: list.id,
                selectedStoreID: nil
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
            showCatalogNotice(
                "The household changed. Select the items again.",
                duration: .attention
            )
            return nil
        }
        do {
            let result = try service.applyCatalogAdd(token, renewCarted: renewCarted)
            addConfirmation = nil
            clearSelection()
            let visibleNeedID = result.addedNeedIDs.first ?? result.renewedNeedIDs.first
            showCatalogNotice(
                CatalogAddCopy.result(result),
                needID: visibleNeedID,
                duration: result.archivedCount > 0 || result.ineligibleCount > 0
                    || result.changedCount > 0 || result.missingCount > 0
                    ? .attention : .success
            )
            hapticFeedback.play(result.addedNeedIDs.isEmpty && result.renewedNeedIDs.isEmpty ? .lightImpact : .success)
            return result
        } catch {
            addConfirmation = nil
            errorMessage = CatalogErrorCopy.message(error)
            return nil
        }
    }

    private func viewNeed(_ id: UUID) {
        navigation.requestNeedFocus(id)
    }

    private func showCatalogNotice(
        _ message: String,
        needID: UUID? = nil,
        duration: ShoppingToastDuration
    ) {
        let action = needID.map { id in
            ShoppingToastAction(
                title: "View",
                accessibilityIdentifier: "shopping.catalog.viewNeed"
            ) {
                viewNeed(id)
                return true
            }
        }
        toastCenter?.show(message, duration: duration, action: action)
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
            showCatalogNotice(
                ManagementBatchCopy.result(result),
                duration: result.retainedCount > 0 || result.changedCount > 0
                    || result.missingCount > 0
                    ? .attention : .success
            )
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

#Preview("Catalog · populated") { ShoppingPreviewHost(.populated) { CatalogView(navigation: GroceryNavigationState()) } }
#Preview("Catalog · empty") { ShoppingPreviewHost(.empty) { CatalogView(navigation: GroceryNavigationState()) } }
#Preview("Catalog · large text") {
    ShoppingPreviewHost(.largeText) {
        CatalogView(navigation: GroceryNavigationState()).environment(\.dynamicTypeSize, .accessibility3)
    }
}
