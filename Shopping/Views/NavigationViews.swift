import CoreData
import SwiftUI
import UIKit

enum NavigationFetchRequests {
    static func stores() -> NSFetchRequest<Store> {
        configured(Store.fetchRequest(), sortKey: "displayOrder")
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
        configured(Category.fetchRequest(), sortKey: "displayOrder")
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
    @ObservedObject var navigation: GroceryNavigationState
    @State private var searchText = ""
    @State private var visibleNeedIDs: Set<UUID> = []
    @State private var showingFilters = false
    @State private var showingStorePicker = false
    @State private var addScope: GroceryAddScope?
    @State private var error: Error?

    private var activeStores: [Store] {
        let candidates = stores.filter {
            $0.household?.id == selection.householdID && !$0.isArchived && $0.id != PersistenceModel.unsetID
        }
        let counts = Dictionary(grouping: candidates, by: \.id).mapValues(\.count)
        return candidates.filter { counts[$0.id] == 1 }
    }

    private var visibleNeeds: [Need] {
        needs.filter {
            visibleNeedIDs.contains($0.id) && GroceryRowScope.matches($0, selection: selection) &&
                !$0.carted && !$0.archived
        }
    }

    private var hasActiveUncartedNeeds: Bool {
        needs.contains {
            GroceryRowScope.matches($0, selection: selection) && !$0.carted && !$0.archived
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
                        } else {
                            Button("Reset filters") {
                                searchText = ""
                                navigation.selectAll()
                                navigation.resetFilters()
                                refreshProjection()
                            }
                        }
                    }
                    .accessibilityIdentifier("shopping.emptyState")
                } else {
                    List {
                        if let selectedStoreID = navigation.selectedStoreID {
                            Section("Must buy here") {
                                ForEach(storePartition(.mustBuyHere, selectedStoreID: selectedStoreID), id: \.objectID) { need in
                                    GroceryNeedRow(need: need)
                                }
                            }
                            Section("Flexible here") {
                                ForEach(storePartition(.flexibleHere, selectedStoreID: selectedStoreID), id: \.objectID) { need in
                                    GroceryNeedRow(need: need)
                                }
                            }
                        } else {
                            Section("Needed") {
                                ForEach(sorted(visibleNeeds), id: \.objectID) { need in GroceryNeedRow(need: need) }
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
                }
            }
            .navigationDestination(for: GroceryDestination.self) { destination in
                switch destination {
                case .carted: CartedGroceriesView()
                case .recentlyCleared: RecentlyClearedView()
                }
            }
            .sheet(isPresented: $showingFilters) {
                GroceryFiltersView(navigation: navigation, stores: activeStores)
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
            .task(id: selection.householdID) { configureAndRefresh() }
            .onChange(of: stores.map { "\($0.id)-\($0.isArchived)" }) { _, _ in configureAndRefresh() }
            .onChange(of: navigation.selectedStoreID) { _, _ in refreshProjection() }
            .onChange(of: navigation.includedStoreIDs) { _, _ in refreshProjection() }
            .onChange(of: navigation.excludedStoreIDs) { _, _ in refreshProjection() }
            .onChange(of: navigation.urgentOnly) { _, _ in refreshProjection() }
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
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
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
        needs.filter { GroceryRowScope.matches($0, selection: selection) && !$0.archived && $0.carted }.count
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
        let selectedStore = activeStores.first { $0.id == navigation.selectedStoreID }
        addScope = GroceryAddScope(
            householdID: selection.householdID,
            listID: selection.listID,
            selectedStoreID: selectedStore?.id,
            selectedStoreName: selectedStore?.name
        )
    }

    private func configureAndRefresh() {
        navigation.configure(householdID: selection.householdID, activeStoreIDs: Set(activeStores.map(\.id)))
        refreshProjection()
    }

    private func refreshProjection() {
        guard let householdID = selection.householdID, let service else {
            visibleNeedIDs = []
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
                urgency: navigation.urgentOnly ? NeedUrgency.urgent.rawValue : nil
            )
            visibleNeedIDs = Set(try service.filteredActiveNeedIDs(householdID: householdID, filter: filter))
        } catch {
            self.error = error
            visibleNeedIDs = []
        }
    }

    private func sorted(_ values: [Need]) -> [Need] {
        values.sorted {
            if $0.urgency != $1.urgency { return $0.urgency == NeedUrgency.urgent.rawValue }
            return ($0.item?.name ?? $0.title).localizedCaseInsensitiveCompare($1.item?.name ?? $1.title) == .orderedAscending
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
    static func matches(_ need: Need, selection: PersistenceSelection) -> Bool {
        guard let householdID = selection.householdID, let listID = selection.listID else { return false }
        return need.list?.id == listID && need.list?.household?.id == householdID
    }
}

private enum GroceryDestination: Hashable { case carted, recentlyCleared }

private struct GroceryNeedRow: View {
    @ObservedObject var need: Need

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(need.item?.name ?? need.title).font(.body)
                if need.urgency == NeedUrgency.urgent.rawValue {
                    Label("Urgent", systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(Color(red: 0.71, green: 0.29, blue: 0.12))
                }
                if !need.notes.isEmpty { Text(need.notes).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text("\(need.quantity)").foregroundStyle(.secondary).accessibilityLabel("Quantity \(need.quantity)")
        }
        .accessibilityElement(children: .combine)
    }
}

struct GroceryFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var navigation: GroceryNavigationState
    let stores: [Store]

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Urgent only", isOn: $navigation.urgentOnly)
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
                Button("Reset filters") { navigation.resetFilters() }
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
    @State private var usesSelectedStore: Bool
    @State private var error: Error?
    let scope: GroceryAddScope
    let onSaved: () -> Void

    init(scope: GroceryAddScope, onSaved: @escaping () -> Void) {
        self.scope = scope
        self.onSaved = onSaved
        _usesSelectedStore = State(initialValue: scope.selectedStoreID != nil)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            service != nil && scope.listID != nil && scope.householdID != nil &&
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
                Section("Where to buy") {
                    if let selectedStoreName = scope.selectedStoreName {
                        Toggle("Only at \(selectedStoreName)", isOn: $usesSelectedStore)
                        Text(usesSelectedStore ? "Tagged for \(selectedStoreName)" : "Any store")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Purchase rule", value: "Any store")
                    }
                }
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
                usesSelectedStore: usesSelectedStore,
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
    var body: some View {
        let carted = needs.filter { GroceryRowScope.matches($0, selection: selection) && $0.carted && !$0.archived }
        List(carted, id: \.objectID) { GroceryNeedRow(need: $0) }
            .overlay { if carted.isEmpty { ContentUnavailableView("Nothing carted", systemImage: "cart") } }
            .navigationTitle("Carted")
    }
}

struct RecentlyClearedView: View {
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.clearOperations()) private var operations: FetchedResults<ClearOperation>
    @State private var error: Error?

    var body: some View {
        List {
            ForEach(operations.filter { $0.household?.id == selection.householdID }, id: \.objectID) { operation in
                VStack(alignment: .leading) {
                    Text(operation.createdAt, style: .relative)
                    Button("Restore cleared groceries") { restore(operation.id) }
                }
            }
        }
        .overlay { if operations.allSatisfy({ $0.household?.id != selection.householdID }) { ContentUnavailableView("Nothing recently cleared", systemImage: "clock.arrow.circlepath") } }
        .navigationTitle("Recently cleared")
        .alert("Couldn’t restore groceries", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error?.localizedDescription ?? "Unknown error") }
    }

    private func restore(_ operationID: UUID) {
        guard let service, let householdID = selection.householdID, let listID = selection.listID else {
            error = GroceryAddError.householdUnavailable
            return
        }
        do {
            _ = try service.undoClear(
                operationID: operationID,
                expectedHouseholdID: householdID,
                expectedListID: listID
            )
        } catch { self.error = error }
    }
}

struct CatalogView: View {
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.items()) private var items: FetchedResults<Item>
    @State private var searchText = ""
    private var catalogItems: [Item] {
        let candidates = items.filter {
            $0.household?.id == selection.householdID && !$0.isArchived && $0.id != PersistenceModel.unsetID
        }
        let counts = Dictionary(grouping: candidates, by: \.id).mapValues(\.count)
        return candidates.filter {
            counts[$0.id] == 1 && (searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        NavigationStack {
            List(catalogItems, id: \.objectID) { item in
                VStack(alignment: .leading) {
                    Text(item.name)
                    Text(purchaseSummary(item)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .overlay { if items.allSatisfy({ $0.household?.id != selection.householdID || $0.isArchived }) { ContentUnavailableView("No remembered groceries", systemImage: "books.vertical", description: Text("Reusable groceries will appear here.")) } }
            .navigationTitle("Catalog")
            .searchable(text: $searchText, prompt: "Search catalog")
        }
    }

    private func purchaseSummary(_ item: Item) -> String {
        if item.anyStore { return "Any store" }
        let names = (item.stores ?? []).filter { !$0.isArchived }.map(\.name).sorted()
        return names.isEmpty ? "Needs store" : names.joined(separator: ", ")
    }
}

struct SettingsView: View {
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories: FetchedResults<Category>
    var body: some View {
        NavigationStack {
            List {
                Section("Stores") {
                    ForEach(stores.filter { $0.household?.id == selection.householdID }, id: \.objectID) { store in
                        HStack { Text(store.name); Spacer(); if store.isArchived { Text("Archived").foregroundStyle(.secondary) } }
                    }
                }
                Section("Categories") {
                    ForEach(categories.filter { $0.household?.id == selection.householdID }, id: \.objectID) { Text($0.name) }
                }
                Section("Household") {
                    LabeledContent("Sharing status", value: "Not connected")
                    Text("Groceries are available in this app’s current local household store.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview("Groceries") { ShoppingPreviewHost(.populated) { GroceriesView(navigation: GroceryNavigationState()) } }
#Preview("Catalog") { ShoppingPreviewHost(.populated) { CatalogView() } }
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
    @StateObject private var navigation = GroceryNavigationState()

    var body: some View {
        GroceryFiltersView(
            navigation: navigation,
            stores: stores.filter { $0.household?.id == selection.householdID && !$0.isArchived }
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
