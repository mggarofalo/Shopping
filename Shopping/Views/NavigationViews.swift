import CoreData
import SwiftUI
import UIKit

enum NavigationFetchRequests {
    static func stores() -> NSFetchRequest<Store> {
        let request = configured(Store.fetchRequest(), sortKey: "displayOrder")
        request.sortDescriptors?.append(NSSortDescriptor(key: "id", ascending: true))
        return request
    }

    static func needs() -> NSFetchRequest<Need> {
        configured(Need.fetchRequest(), sortKey: "title")
    }

    static func clearOperations() -> NSFetchRequest<ClearOperation> {
        configured(ClearOperation.fetchRequest(), sortKey: "createdAt", ascending: false)
    }

    static func items() -> NSFetchRequest<Item> {
        configured(Item.fetchRequest(), sortKey: "name")
    }

    static func categories() -> NSFetchRequest<Category> {
        let request = configured(Category.fetchRequest(), sortKey: "displayOrder")
        request.sortDescriptors?.append(NSSortDescriptor(key: "id", ascending: true))
        return request
    }

    static func lists() -> NSFetchRequest<GroceryList> {
        configured(GroceryList.fetchRequest(), sortKey: "id")
    }

    static func households() -> NSFetchRequest<Household> {
        configured(Household.fetchRequest(), sortKey: "id")
    }

    private static func configured<Result: NSFetchRequestResult>(
        _ request: NSFetchRequest<Result>,
        sortKey: String,
        ascending: Bool = true
    ) -> NSFetchRequest<Result> {
        request.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: ascending)]
        return request
    }
}

struct GroceriesView: View {
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: NavigationFetchRequests.needs()) private var needs: FetchedResults<Need>
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories: FetchedResults<Category>
    @FetchRequest(fetchRequest: NavigationFetchRequests.lists()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @ObservedObject var navigation: GroceryNavigationState
    @State private var searchText = ""
    @State private var visibleNeedObjectIDs: Set<NSManagedObjectID> = []
    @State private var showingFilters = false
    @State private var showingStorePicker = false
    @State private var editor: GroceryEditorTarget?
    @State private var removedOperationID: UUID?
    @State private var removedScope: GroceryAddScope?
    @State private var savedWhileFiltered = false
    @State private var pendingSavedNeed: (id: UUID, scope: GroceryAddScope, expectsUncarted: Bool)?
    @State private var error: Error?

    private var activeStores: [Store] {
        GroceryRowScope.validStores(
            Array(stores), canonicalList: canonicalList
        ).filter { !$0.isArchived }
    }

    private var activeCategories: [Category] {
        GroceryRowScope.validCategories(Array(categories), canonicalList: canonicalList)
    }

    private var canonicalList: GroceryList? {
        GroceryRowScope.canonicalList(Array(lists), households: Array(households), selection: selection)
    }

    private var visibleNeeds: [Need] {
        needs.filter {
            visibleNeedObjectIDs.contains($0.objectID) && GroceryRowScope.matches($0, canonicalList: canonicalList) &&
                !$0.carted && !$0.archived
        }
    }

    private var hasActiveUncartedNeeds: Bool {
        GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList).contains {
            !$0.carted && !$0.archived
        }
    }

    private var hasViewNarrowing: Bool {
        navigation.selectedStoreID != nil || navigation.activeFilterCount > 0 || !searchText.isEmpty
    }

    var body: some View {
        NavigationStack {
            groceryContent
            .navigationTitle("Groceries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .searchable(text: $searchText, prompt: "Search groceries")
            .onSubmit(of: .search, refreshProjection)
            .onChange(of: searchText) { _, _ in refreshProjection() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: GroceryDestination.recentlyCleared) {
                        Label("Recently cleared", systemImage: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    recoveryLinks
                        .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { presentAdd() } label: { Label("Add item", systemImage: "plus") }
                        .accessibilityIdentifier("shopping.addGrocery")
                        .disabled(canonicalList == nil)
                }
            }
            .navigationDestination(for: GroceryDestination.self) { destination in
                switch destination {
                case .carted:
                    CartedGroceriesView(
                        initialFilter: currentNeedFilter,
                        onEdit: focus,
                        onNeedAgain: needAgain,
                        onUncarted: uncarted
                    )
                case .recentlyCleared: RecentlyClearedView()
                }
            }
            .sheet(isPresented: $showingFilters) {
                GroceryFiltersView(
                    navigation: navigation,
                    stores: activeStores,
                    categories: activeCategories,
                    onReset: resetView
                )
            }
            .confirmationDialog(
                "Choose store",
                isPresented: $showingStorePicker,
                titleVisibility: .visible
            ) {
                ForEach(activeStores, id: \.objectID) { store in
                    Button(store.name) { navigation.selectStore(store.id) }
                }
            }
            .sheet(item: $editor, onDismiss: completeSaveFeedback) { target in
                GroceryEditorView(target: target, onSaved: saved, onFocusNeed: focus, onRemoved: removed)
                    .id(target.id)
            }
            .alert("Couldn’t load groceries", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error?.localizedDescription ?? "Unknown error") }

            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if savedWhileFiltered {
                        HStack {
                            Text("Saved to groceries. Current filters hide this item.")
                                .font(.subheadline)
                            Spacer()
                            Button("Show all") { resetView(); savedWhileFiltered = false }
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("shopping.grocery.showAll")
                        }
                        .padding()
                        .background(.bar)
                    }
                    if let removedOperationID {
                        HStack {
                            Text("Grocery removed")
                            Spacer()
                            Button("Undo") { undo(removedOperationID) }
                                .frame(minHeight: 44)
                                .disabled(removedScope?.householdID != selection.householdID ||
                                    removedScope?.listID != selection.listID || canonicalList == nil)
                                .accessibilityIdentifier("shopping.grocery.undoRemove")
                        }
                        .padding()
                        .background(.bar)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("shopping.grocery.feedback")
            }
            .onAppear(perform: completeSaveFeedback)
            .task(id: "\(selection.householdID?.uuidString ?? "nil")-\(selection.listID?.uuidString ?? "nil")") {
                configureAndRefresh()
            }
            .onChange(of: stores.map { "\($0.id)-\($0.isArchived)" }) { _, _ in configureAndRefresh() }
            .onChange(of: navigation.selectedStoreID) { _, _ in refreshProjection() }
            .onChange(of: navigation.includedStoreIDs) { _, _ in refreshProjection() }
            .onChange(of: navigation.excludedStoreIDs) { _, _ in refreshProjection() }
            .onChange(of: navigation.urgentOnly) { _, _ in refreshProjection() }
            .onChange(of: navigation.categoryID) { _, _ in refreshProjection() }
            .onChange(of: needs.count) { _, _ in refreshProjection() }
            .onReceive(NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange,
                object: viewContext
            )) { _ in
                configureAndRefresh()
                completeSaveFeedback()
            }
        }
    }

    private var groceryContent: some View {
            Group {
                if visibleNeeds.isEmpty {
                    ScrollView {
                        VStack(spacing: 16) { scopeControls; emptyState }
                    }
                } else {
                    List {
                        Section {
                            scopeControls
                                .buttonStyle(.borderless)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowBackground(Color.clear)
                        }
                        if let selectedStoreID = navigation.selectedStoreID {
                            let mustBuy = storePartition(.mustBuyHere, selectedStoreID: selectedStoreID)
                            let flexible = storePartition(.flexibleHere, selectedStoreID: selectedStoreID)
                            if !mustBuy.isEmpty {
                                Section {
                                    groupedRows(mustBuy, sectionTitle: "Must buy here")
                                }
                            }
                            if !flexible.isEmpty {
                                Section {
                                    groupedRows(flexible, sectionTitle: "Flexible here")
                                }
                            }
                        } else {
                            Section {
                                groupedRows(visibleNeeds)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .contentMargins(
                        .bottom, dynamicTypeSize.isAccessibilitySize ? 96 : nil, for: .scrollContent
                    )
                }
            }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                emptyTitle,
                systemImage: !hasActiveUncartedNeeds ? "cart" : "line.3.horizontal.decrease.circle")
        } description: {
            Text(emptyDescription)
        } actions: {
            if !hasActiveUncartedNeeds {
                Button("Add item") { presentAdd() }
                    .buttonStyle(.borderedProminent)
                    .disabled(canonicalList == nil)
            } else {
                Button("Reset filters", action: resetView)
            }
        }
        .accessibilityIdentifier("shopping.emptyState")
    }

    @ViewBuilder
    private var scopeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                allButton
                storeMenu
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                filtersButton
            }
            activeFilterChips
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var activeFilterChips: some View {
        if navigation.activeFilterCount > 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if navigation.urgentOnly {
                        filterChip("Urgent") { navigation.urgentOnly = false }
                    }
                    if let categoryID = navigation.categoryID,
                       let category = activeCategories.first(where: { $0.id == categoryID }) {
                        filterChip(category.name) { navigation.categoryID = nil }
                    }
                    ForEach(activeStores.filter { navigation.includedStoreIDs.contains($0.id) }, id: \.objectID) { store in
                        filterChip("Tagged \(store.name)") { navigation.setIncluded(false, storeID: store.id) }
                    }
                    ForEach(activeStores.filter { navigation.excludedStoreIDs.contains($0.id) }, id: \.objectID) { store in
                        filterChip("Not tagged \(store.name)") { navigation.setExcluded(false, storeID: store.id) }
                    }
                }
            }
        }
    }

    private func filterChip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            Label(title, systemImage: "xmark")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(title) filter")
    }

    private var allButton: some View {
        SelectionPill(
            title: "All",
            isSelected: navigation.selectedStoreID == nil,
            identifier: "shopping.store.all"
        ) { navigation.selectAll() }
    }

    private var storeMenu: some View {
        HStack(spacing: 0) {
            Button { showingStorePicker = true } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "storefront").accessibilityHidden(true)
                    Text(selectedStoreName).fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(selectedStoreName)
            .accessibilityIdentifier("shopping.store.menu")
            if navigation.selectedStoreID != nil {
                Button { navigation.selectAll() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Clear selected store")
                .accessibilityIdentifier("shopping.store.clear")
            }
        }
    }

    private var filtersButton: some View {
        Button { showingFilters = true } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle").accessibilityHidden(true)
                Text(filterLabel).fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(filterLabel)
        .accessibilityIdentifier("shopping.filters")
    }

    @ViewBuilder
    private var recoveryLinks: some View {
        NavigationLink(value: GroceryDestination.carted) {
            Label("In cart (\(cartedCount))", systemImage: "cart.fill")
                .frame(minHeight: 44)
        }
    }

    private var selectedStoreName: String {
        guard let id = navigation.selectedStoreID else { return "Choose store" }
        return activeStores.first(where: { $0.id == id })?.name ?? "Choose store"
    }

    private var filterLabel: String {
        navigation.activeFilterCount == 0 ? "Filters" : "Filters \(navigation.activeFilterCount)"
    }

    private var cartedCount: Int {
        GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList)
            .filter { !$0.archived && $0.carted && visibleNeedObjectIDs.contains($0.objectID) }.count
    }

    private var emptyTitle: String {
        !hasActiveUncartedNeeds ? "Your grocery list" : "No matching groceries"
    }

    private var emptyDescription: String {
        !hasActiveUncartedNeeds
            ? "Add a grocery to get started."
            : "Try All, another store, search, or filters. Your shared grocery list is unchanged."
    }

    private func presentAdd() {
        guard let canonicalList, let householdID = canonicalList.household?.id else { return }
        let selectedStore = activeStores.first { $0.id == navigation.selectedStoreID }
        editor = GroceryEditorTarget(scope: GroceryAddScope(
            householdID: householdID,
            listID: canonicalList.id,
            selectedStoreID: selectedStore?.id,
            selectedStoreName: selectedStore?.name
        ), need: nil)
    }

    private func focus(_ need: Need) {
        guard let canonicalList,
              GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList).contains(need),
              !need.archived else { return }
        editor = GroceryEditorTarget(scope: GroceryAddScope(
            householdID: canonicalList.household?.id, listID: canonicalList.id,
            selectedStoreID: navigation.selectedStoreID, selectedStoreName: selectedStoreName
        ), need: need)
    }

    private func saved(_ id: UUID) {
        if let scope = editor?.scope {
            pendingSavedNeed = (id, scope, editor?.need?.carted != true)
        }
        editor = nil
        refreshProjection()
    }

    private func completeSaveFeedback() {
        guard let pending = pendingSavedNeed else { return }
        guard editor == nil else { return }
        guard selection.householdID == pending.scope.householdID,
              selection.listID == pending.scope.listID, canonicalList != nil else {
            pendingSavedNeed = nil
            savedWhileFiltered = false
            return
        }
        guard let need = GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList)
            .first(where: { $0.id == pending.id && !$0.archived }) else { return }
        // A writer save can precede its queued main-context merge. Retain the acknowledgement
        // until the renewed occurrence is actually visible to this context.
        guard !pending.expectsUncarted || !need.carted else { return }
        pendingSavedNeed = nil
        refreshProjection()
        savedWhileFiltered = !need.carted && hasViewNarrowing && !visibleNeedObjectIDs.contains(need.objectID)
    }

    private func needAgain(_ need: Need) {
        guard let service, let canonicalList, let householdID = canonicalList.household?.id,
              GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList).contains(need),
              !need.archived else { return }
        do {
            let id: UUID
            if let item = need.item {
                id = try service.addRememberedNeed(itemID: item.id, listID: canonicalList.id,
                    householdID: householdID)
            } else if need.kind == NeedKind.oneTime.rawValue {
                try service.uncartNeed(needID: need.id, householdID: householdID, listID: canonicalList.id)
                id = need.id
            } else { return }
            pendingSavedNeed = (id, GroceryAddScope(householdID: householdID, listID: canonicalList.id,
                selectedStoreID: navigation.selectedStoreID, selectedStoreName: selectedStoreName), true)
            refreshProjection()
            completeSaveFeedback()
        } catch { self.error = error }
    }

    private func uncarted(_ needID: UUID, householdID: UUID, listID: UUID) {
        pendingSavedNeed = (needID, GroceryAddScope(
            householdID: householdID, listID: listID,
            selectedStoreID: navigation.selectedStoreID, selectedStoreName: selectedStoreName
        ), true)
        completeSaveFeedback()
    }

    private func removed(_ operationID: UUID, scope: GroceryAddScope) {
        editor = nil
        removedOperationID = operationID
        removedScope = scope
        savedWhileFiltered = false
        refreshProjection()
    }

    private func undo(_ operationID: UUID) {
        guard let service, let scope = removedScope, let householdID = scope.householdID,
              let listID = scope.listID, selection.householdID == householdID,
              selection.listID == listID, canonicalList != nil else { return }
        do {
            _ = try service.undoClear(operationID: operationID,
                expectedHouseholdID: householdID, expectedListID: listID)
            removedOperationID = nil
            removedScope = nil
            refreshProjection()
        } catch { self.error = error }
    }

    private func configureAndRefresh() {
        navigation.configure(
            householdID: selection.householdID,
            activeStoreIDs: Set(activeStores.map(\.id)),
            activeCategoryIDs: Set(activeCategories.map(\.id))
        )
        refreshProjection()
    }

    private func refreshProjection() {
        guard let householdID = selection.householdID, canonicalList != nil, let service else {
            visibleNeedObjectIDs = []
            return
        }
        do {
            let matchingIDs = Set(try service.filteredActiveNeedIDs(householdID: householdID, filter: currentNeedFilter))
            visibleNeedObjectIDs = Set(GroceryRowScope.validNeeds(
                Array(needs), canonicalList: canonicalList
            ).filter { matchingIDs.contains($0.id) }.map(\.objectID))
        } catch {
            self.error = error
            visibleNeedObjectIDs = []
        }
    }

    private var currentNeedFilter: GroceryNeedFilter {
        GroceryNeedFilter(
            purchase: PurchaseFilter(
                selectedStoreID: navigation.selectedStoreID,
                includedStoreIDs: navigation.includedStoreIDs,
                excludedStoreIDs: navigation.excludedStoreIDs
            ),
            text: searchText,
            categoryID: navigation.categoryID,
            urgency: navigation.urgentOnly ? NeedUrgency.urgent.rawValue : nil
        )
    }

    private func resetView() {
        searchText = ""
        navigation.selectAll()
        navigation.resetFilters()
        refreshProjection()
    }

    private func sorted(_ values: [Need]) -> [Need] {
        values.sorted {
            if $0.urgency != $1.urgency { return $0.urgency == NeedUrgency.urgent.rawValue }
            return ($0.item?.name ?? $0.title).localizedCaseInsensitiveCompare($1.item?.name ?? $1.title) == .orderedAscending
        }
    }

    @ViewBuilder
    private func groupedRows(_ values: [Need], sectionTitle: String? = nil) -> some View {
        let groups = CategoryGrouping.groups(
            needs: values,
            categories: activeCategories,
            household: canonicalList?.household
        )
        ForEach(groups) { priority in
            ForEach(priority.categories) { category in
                ForEach(category.needs, id: \.objectID) { need in
                    VStack(alignment: .leading, spacing: 8) {
                        if need.objectID == category.needs.first?.objectID {
                            let isFirstGroup = priority.id == groups.first?.id && category.id == priority.categories.first?.id
                            Text(isFirstGroup ? [sectionTitle, category.title].compactMap { $0 }.joined(separator: " · ") : category.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.grocerySecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                        }
                        GroceryNeedRow(
                            need: need,
                            activeStores: activeStores,
                            onEdit: focus,
                            onCartedChange: setCarted,
                            onQuantityChange: setQuantity
                        )
                    }
                }
            }
        }
    }

    private func storePartition(_ availability: PurchaseAvailability, selectedStoreID: UUID) -> [Need] {
        let activeIDs = Set(activeStores.map(\.id))
        return sorted(visibleNeeds.filter { need in
            let item = need.item
            let oneTime = need.kind == NeedKind.oneTime.rawValue
            let value = PurchaseRuleValue(
                explicitStoreIDs: item.map { Set($0.stores?.map(\.id) ?? []) } ?? (oneTime ? Set(need.oneTimeStores?.map(\.id) ?? []) : []),
                anyStore: item?.anyStore ?? (oneTime && need.oneTimeAnyStore)
            )
            return PurchaseFilter().availability(of: value, selectedStoreID: selectedStoreID, activeStoreIDs: activeIDs) == availability
        })
    }

    private func setCarted(_ need: Need, _ carted: Bool) {
        guard let service, let canonicalList, let householdID = canonicalList.household?.id,
              GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList).contains(need) else { return }
        let needID = need.id
        do {
            try service.setNeedCarted(
                needID: needID,
                householdID: householdID,
                listID: canonicalList.id,
                carted: carted
            )
            refreshProjection()
        } catch { self.error = error }
    }

    private func setQuantity(_ need: Need, _ quantity: Int64?) {
        guard let service, let canonicalList, let householdID = canonicalList.household?.id,
              quantity.map({ (1...99).contains($0) }) ?? true,
              GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList).contains(need) else { return }
        let needID = need.id
        do {
            try service.setNeedQuantity(
                needID: needID,
                householdID: householdID,
                listID: canonicalList.id,
                quantity: quantity
            )
        } catch { self.error = error }
    }
}

enum GroceryRowScope {
    static func canonicalList(
        _ lists: [GroceryList],
        households: [Household],
        selection: PersistenceSelection
    ) -> GroceryList? {
        guard let householdID = selection.householdID, let listID = selection.listID,
              householdID != PersistenceModel.unsetID, listID != PersistenceModel.unsetID else { return nil }
        let matches = lists.filter { $0.id == listID }
        let matchingHouseholds = households.filter { $0.id == householdID }
        guard matches.count == 1, matchingHouseholds.count == 1,
              matches[0].household == matchingHouseholds[0],
              let household = matches[0].household,
              let store = household.objectID.persistentStore,
              matches[0].objectID.persistentStore == store else { return nil }
        return matches[0]
    }

    static func validStores(_ stores: [Store], canonicalList: GroceryList?) -> [Store] {
        guard let household = canonicalList?.household,
              let persistentStore = household.objectID.persistentStore else { return [] }
        let counts = Dictionary(grouping: stores, by: \.id).mapValues(\.count)
        return stores.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 &&
                $0.household == household && $0.objectID.persistentStore == persistentStore
        }
    }

    static func validCategories(_ categories: [Category], canonicalList: GroceryList?) -> [Category] {
        guard let household = canonicalList?.household,
              let persistentStore = household.objectID.persistentStore else { return [] }
        let counts = Dictionary(grouping: categories, by: \.id).mapValues(\.count)
        return categories.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 &&
                $0.household == household && $0.objectID.persistentStore == persistentStore
        }
    }

    static func validItems(_ items: [Item], canonicalList: GroceryList?) -> [Item] {
        guard let household = canonicalList?.household,
              let persistentStore = household.objectID.persistentStore else { return [] }
        let counts = Dictionary(grouping: items, by: \.id).mapValues(\.count)
        return items.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 &&
                $0.household == household && $0.objectID.persistentStore == persistentStore
        }
    }

    static func validNeeds(_ needs: [Need], canonicalList: GroceryList?) -> [Need] {
        let counts = Dictionary(grouping: needs, by: \.id).mapValues(\.count)
        return needs.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 &&
                matches($0, canonicalList: canonicalList)
        }
    }

    static func validClearOperations(
        _ operations: [ClearOperation],
        canonicalList: GroceryList?
    ) -> [ClearOperation] {
        guard let canonicalList, let household = canonicalList.household,
              let persistentStore = canonicalList.objectID.persistentStore else { return [] }
        let counts = Dictionary(grouping: operations, by: \.id).mapValues(\.count)
        return operations.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 &&
                $0.list == canonicalList && $0.household == household &&
                $0.objectID.persistentStore == persistentStore
        }
    }

    static func needsStore(_ need: Need) -> Bool {
        guard let household = need.list?.household else { return true }
        let tags: Set<Store>
        let anyStore: Bool
        if let item = need.item {
            tags = item.stores ?? []
            anyStore = item.anyStore
        } else if need.kind == NeedKind.oneTime.rawValue {
            tags = need.oneTimeStores ?? []
            anyStore = need.oneTimeAnyStore
        } else {
            return true
        }
        return !anyStore && !tags.contains {
            !$0.isArchived && $0.id != PersistenceModel.unsetID &&
                $0.household == household && $0.objectID.persistentStore == household.objectID.persistentStore
        }
    }

    static func needsStore(_ need: Need, activeStores: [Store]) -> Bool {
        let anyStore: Bool
        let tags: Set<Store>
        if let item = need.item {
            anyStore = item.anyStore
            tags = item.stores ?? []
        } else if need.kind == NeedKind.oneTime.rawValue {
            anyStore = need.oneTimeAnyStore
            tags = need.oneTimeStores ?? []
        } else {
            return true
        }
        return !anyStore && activeStores.allSatisfy { !tags.contains($0) }
    }

    static func matches(_ need: Need, canonicalList: GroceryList?) -> Bool {
        guard let canonicalList else { return false }
        return need.list == canonicalList &&
            need.objectID.persistentStore == canonicalList.objectID.persistentStore
    }
}

private enum GroceryDestination: Hashable { case carted, recentlyCleared }

enum GroceryPurchaseRuleLabel {
    static func text(anyStore: Bool, stores: Set<Store>, activeStores: [Store]) -> String? {
        let names = activeStores.filter { stores.contains($0) }.map(\.name).sorted()
        if anyStore {
            return names.isEmpty ? "Buy at any store" : "Buy at any store · Tagged: \(names.joined(separator: ", "))"
        }
        guard !names.isEmpty else { return nil }
        return names.count == 1 ? "Only buy at \(names[0])" : "Buy at \(names.joined(separator: ", "))"
    }
}

struct GroceryNeedRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var need: Need
    let activeStores: [Store]
    var onEdit: ((Need) -> Void)? = nil
    var onCartedChange: ((Need, Bool) -> Void)? = nil
    var onQuantityChange: ((Need, Int64?) -> Void)? = nil

    private var needsStore: Bool { GroceryRowScope.needsStore(need, activeStores: activeStores) }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            detailsControl
            controls.fixedSize(horizontal: true, vertical: false).frame(
                maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                alignment: .trailing
            )
        }
        .frame(minHeight: 44)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let onCartedChange {
                Button {
                    onCartedChange(need, !need.carted)
                } label: {
                    Label(cartActionTitle, systemImage: cartActionSymbol)
                }
                .tint(need.carted ? .orange : .blue)
                .accessibilityIdentifier("shopping.checklist.cart.\(need.id.uuidString)")
            }
        }
        .accessibilityAction(named: Text(cartActionAccessibilityTitle)) {
            onCartedChange?(need, !need.carted)
        }
    }

    @ViewBuilder
    private var detailsControl: some View {
        if let onEdit {
            Button {
                onEdit(need)
            } label: {
                details
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(title)")
            .accessibilityValue(accessibilityDetails)
            .accessibilityIdentifier("shopping.grocery.row.\(need.id.uuidString)")
        } else {
            details
                .accessibilityLabel(title)
                .accessibilityValue(accessibilityDetails)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if let quantity = need.quantity {
                if let onQuantityChange {
                    quantityButton("minus", quantity: quantity, change: -1, action: onQuantityChange)
                    Text("\(quantity)")
                        .monospacedDigit()
                        .fixedSize()
                        .foregroundStyle(Color.grocerySecondary)
                        .accessibilityLabel("Quantity \(quantity)")
                        .accessibilityIdentifier("shopping.checklist.quantity.value.\(need.id.uuidString)")
                    quantityButton("plus", quantity: quantity, change: 1, action: onQuantityChange)
                } else {
                    Text("\(quantity)").foregroundStyle(Color.grocerySecondary)
                        .accessibilityLabel("Quantity \(quantity)")
                        .accessibilityIdentifier("shopping.checklist.quantity.value.\(need.id.uuidString)")
                }
            }
        }
    }

    private var cartActionTitle: String {
        need.carted ? "Remove from cart" : "In cart"
    }

    private var cartActionSymbol: String {
        need.carted ? "cart.badge.minus" : "cart.fill"
    }

    private var cartActionAccessibilityTitle: String {
        "\(cartActionTitle) \(title)"
    }

    private func quantityButton(
        _ symbol: String, quantity: Int64, change: Int64, action: @escaping (Need, Int64?) -> Void
    ) -> some View {
        Button {
            action(need, quantity + change)
        } label: {
            Image(systemName: symbol).frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .disabled(change < 0 ? quantity <= 1 : quantity >= 99)
        .accessibilityLabel("\(change < 0 ? "Decrease" : "Increase") quantity for \(title)")
        .accessibilityIdentifier(
            "shopping.checklist.quantity.\(change < 0 ? "decrease" : "increase").\(need.id.uuidString)")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.body)
                if need.urgency == NeedUrgency.urgent.rawValue {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(Color.groceryUrgent)
                        .accessibilityHidden(true)
                }
            }
            if need.kind == NeedKind.oneTime.rawValue {
                Label("One-time", systemImage: "1.circle")
                    .font(.caption).foregroundStyle(Color.grocerySecondary)
            }
            if let purchaseRuleLabel {
                Text(purchaseRuleLabel)
                    .font(.caption)
                    .foregroundStyle(Color.grocerySecondary)
            }
            if needsStore {
                Label("Needs store", systemImage: "storefront").font(.caption).foregroundStyle(Color.grocerySecondary)
            }
            if !need.notes.isEmpty { Text(need.notes).font(.caption).foregroundStyle(Color.grocerySecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var title: String { need.item?.name ?? need.title }

    private var accessibilityDetails: String {
        var values: [String] = []
        if need.urgency == NeedUrgency.urgent.rawValue { values.append("Urgent") }
        if need.kind == NeedKind.oneTime.rawValue { values.append("One-time") }
        if need.carted { values.append("In cart") }
        if let purchaseRuleLabel { values.append(purchaseRuleLabel) }
        if needsStore { values.append("Needs store") }
        if !need.notes.isEmpty { values.append(need.notes) }
        return values.joined(separator: ", ")
    }

    private var purchaseRuleLabel: String? {
        let anyStore: Bool
        let stores: Set<Store>
        if let item = need.item {
            anyStore = item.anyStore
            stores = item.stores ?? []
        } else if need.kind == NeedKind.oneTime.rawValue {
            anyStore = need.oneTimeAnyStore
            stores = need.oneTimeStores ?? []
        } else {
            return nil
        }
        return GroceryPurchaseRuleLabel.text(
            anyStore: anyStore,
            stores: stores,
            activeStores: activeStores
        )
    }
}

struct GroceryFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var navigation: GroceryNavigationState
    let stores: [Store]
    let categories: [Category]
    let onReset: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Urgent only", isOn: $navigation.urgentOnly)
                Section("Category") {
                    PillFlowLayout {
                        SelectionPill(title: "Any category", isSelected: navigation.categoryID == nil) {
                            navigation.categoryID = nil
                        }
                        ForEach(categories, id: \.objectID) { category in
                            SelectionPill(title: category.name, isSelected: navigation.categoryID == category.id) {
                                navigation.categoryID = navigation.categoryID == category.id ? nil : category.id
                            }
                        }
                    }
                }
                Section("Include a store tag") {
                    PillFlowLayout {
                        ForEach(stores, id: \.objectID) { store in
                            SelectionPill(
                                title: store.name,
                                isSelected: navigation.includedStoreIDs.contains(store.id),
                                identifier: "shopping.filters.include.\(store.id.uuidString)"
                            ) { navigation.setIncluded(!navigation.includedStoreIDs.contains(store.id), storeID: store.id) }
                        }
                    }
                }
                Section("Exclude a store tag") {
                    PillFlowLayout {
                        ForEach(stores, id: \.objectID) { store in
                            SelectionPill(
                                title: store.name,
                                isSelected: navigation.excludedStoreIDs.contains(store.id),
                                identifier: "shopping.filters.exclude.\(store.id.uuidString)"
                            ) { navigation.setExcluded(!navigation.excludedStoreIDs.contains(store.id), storeID: store.id) }
                        }
                    }
                }
                Button("Reset filters", action: onReset)
            }
            .navigationTitle("Filters")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct OneTimeGrocerySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var currentSelection
    @State private var name = ""
    @State private var selectedStoreIDs: Set<UUID>
    @State private var anyStore: Bool
    @State private var error: Error?
    let scope: GroceryAddScope
    let onSaved: () -> Void

    init(scope: GroceryAddScope, onSaved: @escaping () -> Void) {
        self.scope = scope
        self.onSaved = onSaved
        _selectedStoreIDs = State(initialValue: scope.selectedStoreID.map { [$0] } ?? [])
        _anyStore = State(initialValue: scope.selectedStoreID == nil)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            service != nil && scope.listID != nil && scope.householdID != nil &&
            (anyStore || !selectedStoreIDs.isEmpty) &&
            currentSelection == PersistenceSelection(householdID: scope.householdID, listID: scope.listID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("One-time grocery") {
                    TextField("Grocery name", text: $name)
                    Text("This grocery won’t be remembered in Catalog.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                PurchaseRulesPicker(
                    storeIDs: $selectedStoreIDs, anyStore: $anyStore,
                    householdID: scope.householdID, listID: scope.listID
                )
                if service == nil || scope.listID == nil || scope.householdID == nil {
                    Text("This household is still loading. Your draft will remain here.")
                        .foregroundStyle(.secondary)
                } else if currentSelection != PersistenceSelection(householdID: scope.householdID, listID: scope.listID) {
                    Text(GroceryAddError.selectionChanged.localizedDescription)
                        .foregroundStyle(.secondary)
                }
                if let error { Text(error.localizedDescription).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Add one-time grocery")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        do {
            _ = try scope.addOneTime(
                title: name,
                selectedStoreIDs: selectedStoreIDs,
                anyStore: anyStore,
                currentSelection: currentSelection,
                service: service
            )
            onSaved()
            dismiss()
        } catch { self.error = error }
    }

}

struct RecentlyClearedView: View {
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.clearOperations()) private var operations: FetchedResults<ClearOperation>
    @FetchRequest(fetchRequest: NavigationFetchRequests.lists()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @State private var error: Error?
    @State private var restoreMessage: String?

    var body: some View {
        let canonicalList = GroceryRowScope.canonicalList(
            Array(lists), households: Array(households), selection: selection
        )
        let scopedOperations = GroceryRowScope.validClearOperations(
            Array(operations), canonicalList: canonicalList
        )
        List {
            ForEach(scopedOperations, id: \.objectID) { operation in
                VStack(alignment: .leading) {
                    Text(operation.createdAt, style: .relative)
                    Button("Restore cleared groceries") { restore(operation.id) }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("shopping.recovery.restore.\(operation.id.uuidString)")
                }
            }
        }
        .overlay { if scopedOperations.isEmpty { ContentUnavailableView("Nothing recently cleared", systemImage: "clock.arrow.circlepath") } }
        .navigationTitle("Recently cleared")
        .safeAreaInset(edge: .bottom) {
            if let restoreMessage {
                Text(restoreMessage).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    .padding().background(.bar)
            }
        }
        .alert("Couldn’t restore groceries", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error?.localizedDescription ?? "Unknown error") }
    }

    private func restore(_ operationID: UUID) {
        guard let service,
              let list = GroceryRowScope.canonicalList(
                Array(lists), households: Array(households), selection: selection
              ),
              let householdID = list.household?.id else {
            error = GroceryAddError.householdUnavailable
            return
        }
        do {
            let expected = operationExpectedRestoreCount(operationID)
            let restored = try service.undoClear(
                operationID: operationID,
                expectedHouseholdID: householdID,
                expectedListID: list.id
            )
            let skipped = max(0, expected - restored)
            if restored == 0 {
                restoreMessage = "Nothing restored. These groceries were already restored or have newer changes."
            } else if skipped > 0 {
                restoreMessage = "Restored \(restored); skipped \(skipped) with newer changes."
            } else {
                restoreMessage = restored == 1 ? "Restored 1 grocery" : "Restored \(restored) groceries"
            }
        } catch { self.error = error }
    }

    private func operationExpectedRestoreCount(_ operationID: UUID) -> Int {
        guard let operation = operations.first(where: { $0.id == operationID }),
              let snapshot = operation.snapshot,
              let token = try? JSONDecoder().decode(ClearCartedToken.self, from: snapshot) else { return 0 }
        return token.revisionsByNeedID.count
    }
}

#Preview("Groceries") { ShoppingPreviewHost(.populated) { GroceriesView(navigation: GroceryNavigationState()) } }
#Preview("Settings") { ShoppingPreviewHost(.archivedStore) { SettingsView() } }


extension Color {
    static let grocerySecondary = Color(UIColor { traits in
        UIColor(white: traits.userInterfaceStyle == .dark ? 0.75 : 0.35, alpha: 1)
    })

    static let groceryUrgent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.95, green: 0.58, blue: 0.30, alpha: 1)
            : UIColor(red: 0.60, green: 0.20, blue: 0.07, alpha: 1)
    })

    static let groceryAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.35, green: 0.72, blue: 0.55, alpha: 1)
            : UIColor(red: 0.10, green: 0.32, blue: 0.23, alpha: 1)
    })
}

private struct AddGroceryPreview: View {
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>

    var body: some View {
        let store = stores.first { $0.name == "Costco" && !$0.isArchived }
        OneTimeGrocerySheet(
            scope: GroceryAddScope(
                householdID: selection.householdID,
                listID: selection.listID,
                selectedStoreID: store?.id,
                selectedStoreName: store?.name
            ),
            onSaved: {}
        )
    }
}

private struct GroceryFiltersPreview: View {
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories: FetchedResults<Category>
    @StateObject private var navigation = GroceryNavigationState()

    var body: some View {
        GroceryFiltersView(
            navigation: navigation,
            stores: stores.filter { $0.household?.id == selection.householdID && !$0.isArchived },
            categories: categories.filter { $0.household?.id == selection.householdID },
            onReset: { navigation.resetFilters() }
        )
    }
}

#Preview("Add one-time grocery · Costco") { ShoppingPreviewHost(.populated) { AddGroceryPreview() } }
#Preview("Add one-time grocery · unavailable") {
    OneTimeGrocerySheet(
        scope: GroceryAddScope(householdID: nil, listID: nil, selectedStoreID: nil, selectedStoreName: nil),
        onSaved: {}
    )
}
#Preview("Grocery filters") { ShoppingPreviewHost(.populated) { GroceryFiltersPreview() } }
#Preview("Groceries in cart") { ShoppingPreviewHost(.populated) { NavigationStack { CartedGroceriesView() } } }
#Preview("Recently cleared") { ShoppingPreviewHost(.populated) { NavigationStack { RecentlyClearedView() } } }
