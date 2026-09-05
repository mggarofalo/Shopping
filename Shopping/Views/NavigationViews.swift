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
    @State private var addScope: GroceryAddScope?
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
            Group {
                if visibleNeeds.isEmpty {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: !hasActiveUncartedNeeds ? "cart" : "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(emptyDescription)
                    } actions: {
                        if !hasActiveUncartedNeeds {
                            Button("Add grocery") { presentAdd() }
                                .buttonStyle(.borderedProminent)
                                .disabled(canonicalList == nil)
                        } else {
                            Button("Reset filters", action: resetView)
                        }
                    }
                    .accessibilityIdentifier("shopping.emptyState")
                } else {
                    List {
                        if let selectedStoreID = navigation.selectedStoreID {
                            Section("Must buy here") {
                                groupedRows(storePartition(.mustBuyHere, selectedStoreID: selectedStoreID))
                            }
                            Section("Flexible here") {
                                groupedRows(storePartition(.flexibleHere, selectedStoreID: selectedStoreID))
                            }
                        } else {
                            Section("Needed") {
                                groupedRows(visibleNeeds)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Groceries")
            .searchable(text: $searchText, prompt: "Search groceries")
            .onSubmit(of: .search, refreshProjection)
            .onChange(of: searchText) { _, _ in refreshProjection() }
            .safeAreaInset(edge: .top) { scopeControls }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { presentAdd() } label: { Label("Add grocery", systemImage: "plus") }
                        .accessibilityIdentifier("shopping.addGrocery")
                        .disabled(canonicalList == nil)
                }
            }
            .navigationDestination(for: GroceryDestination.self) { destination in
                switch destination {
                case .carted: CartedGroceriesView()
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
            .sheet(item: $addScope) { scope in
                OneTimeGrocerySheet(scope: scope) {
                    addScope = nil
                    refreshProjection()
                }
            }
            .alert("Couldn’t load groceries", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error?.localizedDescription ?? "Unknown error") }
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
            )) { _ in configureAndRefresh() }
        }
    }

    @ViewBuilder
    private var scopeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                HStack {
                    allButton
                    Spacer()
                    filtersButton
                }
                storeMenu
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) { recoveryLinks }
            } else {
                HStack {
                    allButton
                    storeMenu
                    Spacer()
                    filtersButton
                }
                HStack { recoveryLinks }
            }
            activeFilterChips
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
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
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Remove \(title) filter")
    }

    private var allButton: some View {
        Button("All") { navigation.selectAll() }
            .buttonStyle(.borderedProminent)
            .tint(navigation.selectedStoreID == nil ? .groceryAccent : .secondary)
            .frame(minHeight: 44)
            .accessibilityIdentifier("shopping.store.all")
    }

    private var storeMenu: some View {
        Button { showingStorePicker = true } label: {
            Label(selectedStoreName, systemImage: dynamicTypeSize.isAccessibilitySize ? "chevron.down" : "storefront")
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("shopping.store.menu")
    }

    private var filtersButton: some View {
        Button { showingFilters = true } label: {
            Label(filterLabel, systemImage: "line.3.horizontal.decrease.circle")
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("shopping.filters")
    }

    @ViewBuilder
    private var recoveryLinks: some View {
        NavigationLink(value: GroceryDestination.carted) {
            Label("Carted (\(cartedCount))", systemImage: "cart.fill")
                .frame(minHeight: 44)
        }
        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
        NavigationLink(value: GroceryDestination.recentlyCleared) {
            Label("Recently cleared", systemImage: "clock.arrow.circlepath")
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
            .filter { !$0.archived && $0.carted }.count
    }

    private var emptyTitle: String {
        !hasActiveUncartedNeeds ? "Your grocery list" : "No matching groceries"
    }

    private var emptyDescription: String {
        !hasActiveUncartedNeeds
            ? "Add a one-time grocery to get started."
            : "Try All, another store, search, or filters. Your shared grocery list is unchanged."
    }

    private func presentAdd() {
        guard let canonicalList, let householdID = canonicalList.household?.id else { return }
        let selectedStore = activeStores.first { $0.id == navigation.selectedStoreID }
        addScope = GroceryAddScope(
            householdID: householdID,
            listID: canonicalList.id,
            selectedStoreID: selectedStore?.id,
            selectedStoreName: selectedStore?.name
        )
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
            let filter = GroceryNeedFilter(
                purchase: PurchaseFilter(
                    selectedStoreID: navigation.selectedStoreID,
                    includedStoreIDs: navigation.includedStoreIDs,
                    excludedStoreIDs: navigation.excludedStoreIDs
                ),
                text: searchText,
                categoryID: navigation.categoryID,
                urgency: navigation.urgentOnly ? NeedUrgency.urgent.rawValue : nil
            )
            let matchingIDs = Set(try service.filteredActiveNeedIDs(householdID: householdID, filter: filter))
            visibleNeedObjectIDs = Set(GroceryRowScope.validNeeds(
                Array(needs), canonicalList: canonicalList
            ).filter { matchingIDs.contains($0.id) }.map(\.objectID))
        } catch {
            self.error = error
            visibleNeedObjectIDs = []
        }
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
    private func groupedRows(_ values: [Need]) -> some View {
        let groups = CategoryGrouping.groups(
            needs: values,
            categories: activeCategories,
            household: canonicalList?.household
        )
        ForEach(groups) { priority in
            ForEach(priority.categories) { category in
                Text("\(priority.title) · \(category.title)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(category.needs, id: \.objectID) { need in
                    GroceryNeedRow(need: need, activeStores: activeStores)
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

private struct GroceryNeedRow: View {
    @ObservedObject var need: Need
    let activeStores: [Store]

    private var needsStore: Bool { GroceryRowScope.needsStore(need, activeStores: activeStores) }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(need.item?.name ?? need.title).font(.body)
                if need.urgency == NeedUrgency.urgent.rawValue {
                    Label("Urgent", systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(Color(red: 0.71, green: 0.29, blue: 0.12))
                }
                if need.kind == NeedKind.oneTime.rawValue {
                    Label("One-time", systemImage: "1.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let purchaseRuleLabel {
                    Text(purchaseRuleLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if needsStore { Label("Needs store", systemImage: "storefront").font(.caption).foregroundStyle(.secondary) }
                if !need.notes.isEmpty { Text(need.notes).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text("\(need.quantity)").foregroundStyle(.secondary).accessibilityLabel("Quantity \(need.quantity)")
        }
        .accessibilityElement(children: .combine)
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
                    Button("Any category") { navigation.categoryID = nil }
                    ForEach(categories, id: \.objectID) { category in
                        Button {
                            navigation.categoryID = navigation.categoryID == category.id ? nil : category.id
                        } label: {
                            HStack {
                                Text(category.name)
                                Spacer()
                                if navigation.categoryID == category.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Section("Include a store tag") {
                    ForEach(stores, id: \.objectID) { store in
                        Toggle(store.name, isOn: Binding(
                            get: { navigation.includedStoreIDs.contains(store.id) },
                            set: { navigation.setIncluded($0, storeID: store.id) }
                        ))
                    }
                }
                Section("Exclude a store tag") {
                    ForEach(stores, id: \.objectID) { store in
                        Toggle(store.name, isOn: Binding(
                            get: { navigation.excludedStoreIDs.contains(store.id) },
                            set: { navigation.setExcluded($0, storeID: store.id) }
                        ))
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

struct CartedGroceriesView: View {
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.needs()) private var needs: FetchedResults<Need>
    @FetchRequest(fetchRequest: NavigationFetchRequests.lists()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    var body: some View {
        let canonicalList = GroceryRowScope.canonicalList(
            Array(lists), households: Array(households), selection: selection
        )
        let carted = GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList)
            .filter { $0.carted && !$0.archived }
        let activeStores = GroceryRowScope.validStores(Array(stores), canonicalList: canonicalList)
            .filter { !$0.isArchived }
        List(carted, id: \.objectID) { GroceryNeedRow(need: $0, activeStores: activeStores) }
            .overlay { if carted.isEmpty { ContentUnavailableView("Nothing carted", systemImage: "cart") } }
            .navigationTitle("Carted")
    }
}

struct RecentlyClearedView: View {
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.clearOperations()) private var operations: FetchedResults<ClearOperation>
    @FetchRequest(fetchRequest: NavigationFetchRequests.lists()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @State private var error: Error?

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
                }
            }
        }
        .overlay { if scopedOperations.isEmpty { ContentUnavailableView("Nothing recently cleared", systemImage: "clock.arrow.circlepath") } }
        .navigationTitle("Recently cleared")
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
            _ = try service.undoClear(
                operationID: operationID,
                expectedHouseholdID: householdID,
                expectedListID: list.id
            )
        } catch { self.error = error }
    }
}

#Preview("Groceries") { ShoppingPreviewHost(.populated) { GroceriesView(navigation: GroceryNavigationState()) } }
#Preview("Settings") { ShoppingPreviewHost(.archivedStore) { SettingsView() } }


extension Color {
    static let groceryAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.35, green: 0.72, blue: 0.55, alpha: 1)
            : UIColor(red: 0.15, green: 0.39, blue: 0.29, alpha: 1)
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
#Preview("Carted groceries") { ShoppingPreviewHost(.populated) { NavigationStack { CartedGroceriesView() } } }
#Preview("Recently cleared") { ShoppingPreviewHost(.populated) { NavigationStack { RecentlyClearedView() } } }
