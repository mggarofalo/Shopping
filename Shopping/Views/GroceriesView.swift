import CoreData
import SwiftUI
import UIKit

struct GroceriesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.needService) private var service
    @Environment(\.hapticFeedback) private var hapticFeedback
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
    @State private var savedFeedbackMessage = "Saved to groceries. Current filters hide this item."
    @State private var actionFeedbackMessage: String?
    @State private var pendingSavedNeed: PendingSavedNeed?
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
                GroceryEditorView(
                    target: target,
                    onSaved: saved,
                    onFocusNeed: requestFocus,
                    onRemoved: removed
                )
                    .id(target.id)
            }
            .alert("Couldn’t load groceries", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error?.localizedDescription ?? "Unknown error") }

            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if savedWhileFiltered {
                        ShoppingFeedbackBar(
                            message: savedFeedbackMessage
                        ) {
                            Button("Show all") { resetView(); savedWhileFiltered = false }
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("shopping.grocery.showAll")
                        }
                    }
                    if let actionFeedbackMessage {
                        ShoppingFeedbackBar(message: actionFeedbackMessage)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let removedOperationID {
                        ShoppingFeedbackBar(message: "Item removed") {
                            Button("Undo") { undo(removedOperationID) }
                                .frame(minHeight: 44)
                                .disabled(removedScope?.householdID != selection.householdID ||
                                    removedScope?.listID != selection.listID || canonicalList == nil)
                                .accessibilityIdentifier("shopping.grocery.undoRemove")
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("shopping.grocery.feedback")
            }
            .task(id: actionFeedbackMessage) {
                guard let message = actionFeedbackMessage else { return }
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, actionFeedbackMessage == message else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    actionFeedbackMessage = nil
                }
            }
            .onAppear {
                completeSaveFeedback()
                focusRequestedNeed()
            }
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
            .onChange(of: navigation.pendingNeedFocusID) { _, _ in focusRequestedNeed() }
            .onReceive(NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange,
                object: viewContext
            )) { _ in
                configureAndRefresh()
                completeSaveFeedback()
                focusRequestedNeed()
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
                                Section("Only buy here") {
                                    shoppingRows(mustBuy)
                                }
                            }
                            if !flexible.isEmpty {
                                Section("Can buy here") {
                                    shoppingRows(flexible)
                                }
                            }
                        } else {
                            Section {
                                shoppingRows(visibleNeeds)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .contentMargins(
                        .bottom, dynamicTypeSize.isAccessibilitySize ? 96 : nil, for: .scrollContent
                    )
                }
            }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: !hasActiveUncartedNeeds ? "cart" : "line.3.horizontal.decrease.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(emptyTitle)
                .font(.title2.bold())
                .shoppingMultilineText()
            Text(emptyDescription)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .shoppingMultilineText()
                .accessibilityIdentifier("shopping.emptyState.description")
            if !hasActiveUncartedNeeds {
                Button("Add item") { presentAdd() }
                    .buttonStyle(.borderedProminent)
                    .disabled(canonicalList == nil)
            } else {
                Button("Reset filters", action: resetView)
            }
        }
        .padding()
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
                        filterChip("Includes \(store.name)") { navigation.setIncluded(false, storeID: store.id) }
                    }
                    ForEach(activeStores.filter { navigation.excludedStoreIDs.contains($0.id) }, id: \.objectID) { store in
                        filterChip("Excludes \(store.name)") { navigation.setExcluded(false, storeID: store.id) }
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
            ? "Add an item to get started."
            : "Try All, another store, search, or filters. Your shared grocery list is unchanged."
    }

    private func presentAdd() {
        guard let canonicalList, let householdID = canonicalList.household?.id else { return }
        let selectedStore = activeStores.first { $0.id == navigation.selectedStoreID }
        editor = GroceryEditorTarget(scope: GroceryAddScope(
            householdID: householdID,
            listID: canonicalList.id,
            selectedStoreID: selectedStore?.id,
            selectedStoreName: selectedStore?.name,
            includedStoreIDs: navigation.includedStoreIDs,
            excludedStoreIDs: navigation.excludedStoreIDs,
            categoryID: navigation.categoryID,
            textFilter: searchText,
            urgentOnly: navigation.urgentOnly
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

    private func requestFocus(_ needID: UUID) {
        navigation.requestNeedFocus(needID)
        focusRequestedNeed()
    }

    private func focusRequestedNeed() {
        guard let id = navigation.pendingNeedFocusID,
              let need = GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList)
                .first(where: { $0.id == id && !$0.archived }) else { return }
        navigation.consumeNeedFocus(id)
        focus(need)
    }

    private func saved(_ id: UUID, categoryID: UUID?) {
        if let scope = editor?.scope {
            pendingSavedNeed = PendingSavedNeed(
                id: id,
                scope: scope,
                expectsUncarted: editor?.need?.carted != true,
                originalCategoryID: editor?.originalCategoryID,
                savedCategoryID: categoryID,
                wasEditing: editor?.needID != nil
            )
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
        guard !pending.wasEditing || categoryID(for: need) == pending.savedCategoryID else { return }
        pendingSavedNeed = nil
        refreshProjection()
        savedWhileFiltered = !need.carted && hasViewNarrowing && !visibleNeedObjectIDs.contains(need.objectID)
        let name = need.item?.name ?? need.title
        if pending.wasEditing, pending.originalCategoryID != pending.savedCategoryID {
            let message = "\(name) moved to \(categoryName(for: need))."
            if savedWhileFiltered {
                savedFeedbackMessage = message + " Current filters hide this item."
                announce(message)
            } else {
                showActionFeedback(message)
            }
        } else {
            savedFeedbackMessage = "Saved to groceries. Current filters hide this item."
        }
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
            pendingSavedNeed = PendingSavedNeed(
                id: id,
                scope: GroceryAddScope(householdID: householdID, listID: canonicalList.id,
                    selectedStoreID: navigation.selectedStoreID, selectedStoreName: selectedStoreName),
                expectsUncarted: true,
                originalCategoryID: nil,
                savedCategoryID: categoryID(for: need),
                wasEditing: false
            )
            refreshProjection()
            completeSaveFeedback()
        } catch { self.error = error }
    }

    private func uncarted(_ needID: UUID, householdID: UUID, listID: UUID) {
        pendingSavedNeed = PendingSavedNeed(
            id: needID,
            scope: GroceryAddScope(
                householdID: householdID, listID: listID,
                selectedStoreID: navigation.selectedStoreID, selectedStoreName: selectedStoreName
            ),
            expectsUncarted: true,
            originalCategoryID: nil,
            savedCategoryID: nil,
            wasEditing: false
        )
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

    private func shoppingRows(_ values: [Need]) -> some View {
        ForEach(sorted(values), id: \.objectID) { need in
            GroceryNeedRow(
                need: need,
                activeStores: activeStores,
                onEdit: focus,
                onCartedChange: setCarted,
                onQuantityChange: setQuantity,
                onRemoved: { operationID, householdID, listID in
                    removed(operationID, scope: GroceryAddScope(
                        householdID: householdID, listID: listID,
                        selectedStoreID: nil, selectedStoreName: nil
                    ))
                }
            )
            .shoppingListRowInsets()
        }
    }

    private func storePartition(_ availability: PurchaseAvailability, selectedStoreID: UUID) -> [Need] {
        let activeIDs = Set(activeStores.map(\.id))
        return sorted(visibleNeeds.filter { need in
            let item = need.item
            let oneTime = need.kind == NeedKind.oneTime.rawValue
            let value = PurchaseRuleValue(
                explicitStoreIDs: item.map { Set($0.stores?.map(\.id) ?? []) } ?? (oneTime ? Set(need.oneTimeStores?.map(\.id) ?? []) : []),
                anyStore: item?.anyStore ?? (oneTime && need.oneTimeAnyStore),
                hasResolvedIdentity: item != nil || oneTime
            )
            return PurchaseFilter().availability(of: value, selectedStoreID: selectedStoreID, activeStoreIDs: activeIDs) == availability
        })
    }

    private func setCarted(_ need: Need, _ carted: Bool) {
        guard let service, let canonicalList, let householdID = canonicalList.household?.id,
              GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList).contains(need) else { return }
        let needID = need.id
        let name = need.item?.name ?? need.title
        do {
            try service.setNeedCarted(
                needID: needID,
                householdID: householdID,
                listID: canonicalList.id,
                carted: carted
            )
            hapticFeedback.play(.lightImpact)
            refreshProjection()
            if carted { showActionFeedback("\(name) moved to In cart.") }
        } catch { self.error = error }
    }

    private func categoryID(for need: Need) -> UUID? {
        need.item?.category?.id ?? (need.kind == NeedKind.oneTime.rawValue ? need.oneTimeCategory?.id : nil)
    }

    private func categoryName(for need: Need) -> String {
        guard let id = categoryID(for: need),
              let category = activeCategories.first(where: { $0.id == id }) else { return "Uncategorized" }
        return category.name
    }

    private func showActionFeedback(_ message: String) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            actionFeedbackMessage = message
        }
        announce(message)
    }

    private func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
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
