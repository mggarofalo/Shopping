import CoreData
import SwiftUI
import UIKit

struct GroceriesView: View {
    @Environment(\.persistencePresentation) private var presentation
    @Environment(\.needService) private var service
    @Environment(\.personalCart) private var personalCart
    @Environment(\.hapticFeedback) private var hapticFeedback
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.shoppingToastCenter) private var toastCenter
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: NavigationFetchRequests.needs()) private var needs: FetchedResults<Need>
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories: FetchedResults<Category>
    @FetchRequest(fetchRequest: NavigationFetchRequests.lists()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @ObservedObject var navigation: GroceryNavigationState
    @State private var visibleNeedObjectIDs: Set<NSManagedObjectID> = []
    @State private var projectionTask: Task<Void, Never>?
    @State private var projectionRevision = 0
    @State private var pendingCartActionNeedIDs: Set<UUID> = []
    @State private var pendingNeedQuantityIDs: Set<UUID> = []
    @State private var pendingNeedAgainIDs: Set<UUID> = []
    @State private var showingFilters = false
    @State private var showingCategoryFill = false
    @State private var addPickerScope: GroceryAddScope?
    @State private var pendingCatalogCompletion: GroceryCatalogAddCompletion?
    @State private var pendingCatalogScope: GroceryAddScope?
    @State private var pendingOneTimeTarget: GroceryEditorTarget?
    @State private var editor: GroceryEditorTarget?
    @State private var pendingSavedNeed: PendingSavedNeed?
    @State private var error: Error?

    private var activeStores: [Store] {
        guard presentation?.isActive != false else { return [] }
        return GroceryRowScope.validStores(
            Array(stores), canonicalList: canonicalList
        ).filter { !$0.isArchived }
    }

    private var activeCategories: [Category] {
        guard presentation?.isActive != false else { return [] }
        return GroceryRowScope.validCategories(Array(categories), canonicalList: canonicalList).filter { !$0.isArchived }
    }

    private var canonicalList: GroceryList? {
        guard presentation?.isActive != false else { return nil }
        return GroceryRowScope.canonicalList(Array(lists), households: Array(households), selection: selection)
    }

    private var visibleNeeds: [Need] {
        guard presentation?.isActive != false else { return [] }
        return needs.filter {
            visibleNeedObjectIDs.contains($0.objectID) && GroceryRowScope.matches($0, canonicalList: canonicalList) &&
                isOutstanding($0) && !isInMyCart($0)
        }
    }

    private var grocerySections: [ItemCollectionSection<GroceryCollectionSectionID, Need>] {
        guard presentation?.isActive != false else { return [] }
        return GroceryCollectionProjection.sections(
            needs: visibleNeeds,
            selectedStoreID: navigation.selectedStoreID,
            activeStores: activeStores,
            categories: Array(categories),
            household: canonicalList?.household
        )
    }

    private var hasActiveUncartedNeeds: Bool {
        guard presentation?.isActive != false else { return false }
        return GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList).contains {
            isOutstanding($0) && !isInMyCart($0)
        }
    }

    private var hasViewNarrowing: Bool {
        navigation.selectedStoreID != nil || navigation.activeFilterCount > 0 || !navigation.searchText.isEmpty
    }

    var body: some View {
        Group {
            if presentation?.isActive != false { activeBody }
        }
    }

    private var activeBody: some View {
        NavigationStack {
            groceryContent
            .navigationTitle("Groceries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .searchable(text: $navigation.searchText, prompt: "Search groceries")
            .onSubmit(of: .search, refreshProjection)
            .onChange(of: navigation.searchText) { _, _ in refreshProjection() }
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
                if categoryFillAvailable {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingCategoryFill = true } label: {
                            Label("Suggest saved items for \(selectedCategoryName)", systemImage: "sparkles")
                                .labelStyle(.iconOnly)
                        }
                        .accessibilityHint("Choose saved items to add to this category")
                        .accessibilityIdentifier("shopping.category.fill")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShoppingAddButton(title: "Add item", identifier: "shopping.addGrocery", action: presentAdd)
                        .disabled(canonicalList == nil)
                }
            }
            .navigationDestination(for: GroceryDestination.self) { destination in
                switch destination {
                case .carted:
                    if let personalCart {
                        PersonalCartView(cart: personalCart, navigation: navigation)
                    } else {
                    CartedGroceriesView(
                        navigation: navigation,
                        onEdit: focus,
                        onUncarted: uncarted,
                        onRemoved: { operationID, householdID, listID in
                            removed(operationID, scope: GroceryAddScope(
                                householdID: householdID,
                                listID: listID,
                                selectedStoreID: nil,
                                selectedStoreName: nil
                            ))
                        }
                    )
                }
                case .recentlyCleared:
                    if let personalCart { PersonalPurchaseHistoryView(cart: personalCart) }
                    else { RecentlyClearedView() }
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
            .sheet(isPresented: $showingCategoryFill) {
                if let categoryID = navigation.categoryID,
                   let category = activeCategories.first(where: { $0.id == categoryID }) {
                    CategoryFillSuggestionsView(
                        categoryID: category.id,
                        categoryName: category.name,
                        purchaseFilter: currentPurchaseFilter
                    ) { count in
                        toastCenter?.show(
                            "Added \(count) \(count == 1 ? "item" : "items")",
                            duration: .success
                        )
                        refreshProjection()
                    }
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
            .sheet(item: $addPickerScope, onDismiss: completeCatalogAdd) { scope in
                GroceryCatalogAddView(
                    scope: scope,
                    onCompleted: {
                        pendingCatalogCompletion = $0
                        pendingCatalogScope = scope
                    },
                    onOneTime: { name, personID in
                        pendingOneTimeTarget = GroceryEditorTarget(
                            scope: scope,
                            need: nil,
                            prefilledName: name,
                            initiallyRemembered: false,
                            prefilledPersonID: personID
                        )
                    }
                )
            }
            .alert("Couldn’t load groceries", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error?.localizedDescription ?? "Unknown error") }

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
                guard presentation?.isActive != false else { return }
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
                            .listRowSeparator(.hidden)
                    }
                    CompactGrocerySections(
                        sections: grocerySections,
                        itemID: \.objectID
                    ) { _, need in
                        shoppingRow(need)
                    }
                }
                .listStyle(.insetGrouped)
                .listSectionSpacing(.custom(8))
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
        GroceryScopeControls(
            navigation: navigation,
            stores: activeStores,
            categories: activeCategories,
            showFilters: { showingFilters = true }
        )
    }

    @ViewBuilder
    private var recoveryLinks: some View {
        NavigationLink(value: GroceryDestination.carted) {
            Label("In cart (\(cartedCount))", systemImage: "cart.fill")
                .frame(minHeight: ShoppingListMetrics.minimumRowHeight)
        }
    }

    private var selectedStoreName: String {
        guard let id = navigation.selectedStoreID else { return "Choose store" }
        return activeStores.first(where: { $0.id == id })?.name ?? "Choose store"
    }

    private var selectedCategoryName: String {
        guard let categoryID = navigation.categoryID else { return "category" }
        return activeCategories.first(where: { $0.id == categoryID })?.name ?? "category"
    }

    private var categoryFillAvailable: Bool {
        FoundationModelCategoryClassifier.availability().allowsSuggestions &&
            navigation.categoryID.map { categoryID in
                activeCategories.contains(where: { $0.id == categoryID })
            } == true
    }

    private var currentPurchaseFilter: PurchaseFilter {
        PurchaseFilter(
            selectedStoreID: navigation.selectedStoreID,
            includedStoreIDs: navigation.includedStoreIDs,
            excludedStoreIDs: navigation.excludedStoreIDs
        )
    }

    private var cartedCount: Int {
        if let personalCart {
            return personalCart.visibleEntries(filter: currentNeedFilter, activeStoreIDs: Set(activeStores.map(\.id))).count
        }
        return GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList)
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
        addPickerScope = GroceryAddScope(
            householdID: householdID,
            listID: canonicalList.id,
            selectedStoreID: selectedStore?.id,
            selectedStoreName: selectedStore?.name,
            includedStoreIDs: navigation.includedStoreIDs,
            excludedStoreIDs: navigation.excludedStoreIDs,
            categoryID: navigation.categoryID,
            textFilter: navigation.searchText,
            urgentOnly: navigation.urgentOnly
        )
    }

    private func completeCatalogAdd() {
        if let target = pendingOneTimeTarget {
            pendingOneTimeTarget = nil
            editor = target
            return }
        guard let completion = pendingCatalogCompletion, let scope = pendingCatalogScope else { return }
        pendingCatalogCompletion = nil
        pendingCatalogScope = nil
        switch completion {
        case .added(let id):
            pendingSavedNeed = PendingSavedNeed(
                id: id,
                scope: scope,
                expectsUncarted: true,
                originalCategoryID: nil,
                savedCategoryID: nil,
                wasEditing: false
            )
            refreshProjection()
            completeSaveFeedback()
        case .focusExisting(let id):
            requestFocus(id)
        }
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
                expectsUncarted: editor?.need.map(isInMyCart) != true,
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
            return }
        guard let need = GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList)
            .first(where: { $0.id == pending.id && !$0.archived }) else { return }
        // A writer save can precede its queued main-context merge. Retain the acknowledgement
        // until the renewed occurrence is actually visible to this context.
        guard !pending.expectsUncarted || !isInMyCart(need) else { return }
        guard !pending.wasEditing || categoryID(for: need) == pending.savedCategoryID else { return }
        pendingSavedNeed = nil
        refreshProjection()
        let savedWhileFiltered = !isInMyCart(need) && hasViewNarrowing && !visibleNeedObjectIDs.contains(need.objectID)
        let name = need.item?.name ?? need.title
        if pending.wasEditing, pending.originalCategoryID != pending.savedCategoryID {
            let message = "\(name) moved to \(categoryName(for: need))."
            if savedWhileFiltered {
                toastCenter?.show(
                    message + " Current filters hide this item.",
                    duration: .attention,
                    action: ShoppingToastAction(
                        title: "Show all",
                        accessibilityIdentifier: "shopping.grocery.showAll",
                        perform: {
                            resetView()
                            return true
                        }
                    )
                )
                announce(message)
            } else {
                showActionFeedback(message)
            }
        } else if savedWhileFiltered {
            toastCenter?.show(
                "Saved to groceries. Current filters hide this item.",
                duration: .attention,
                action: ShoppingToastAction(
                    title: "Show all",
                    accessibilityIdentifier: "shopping.grocery.showAll",
                    perform: {
                        resetView()
                        return true
                    }
                )
            )
        }
    }

    private func needAgain(_ need: Need) {
        guard let service, let canonicalList, let householdID = canonicalList.household?.id,
              GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList).contains(need),
              !need.archived else { return }
        let needID = need.id, itemID = need.item?.id, listID = canonicalList.id
        guard pendingNeedAgainIDs.insert(needID).inserted else { return }
        let isOneTime = need.kind == NeedKind.oneTime.rawValue
        let savedCategoryID = categoryID(for: need)
        let scope = GroceryAddScope(householdID: householdID, listID: listID,
            selectedStoreID: navigation.selectedStoreID, selectedStoreName: selectedStoreName)
        let personalCart = self.personalCart
        Task {
            defer { pendingNeedAgainIDs.remove(needID) }
            do {
                let id: UUID
                if let personalCart, let entry = personalCart.entries.first(where: { $0.needID == needID }) {
                    try await personalCart.uncart(entry)
                    id = needID
                } else if let itemID {
                    id = try await Task.detached(priority: .userInitiated) {
                        try service.addRememberedNeed(itemID: itemID, listID: listID, householdID: householdID)
                    }.value
                } else if isOneTime {
                    try await Task.detached(priority: .userInitiated) {
                        try service.uncartNeed(needID: needID, householdID: householdID, listID: listID)
                    }.value
                    id = needID
                } else { return }
                guard presentation?.isActive != false,
                      selection.householdID == householdID, selection.listID == listID else { return }
                pendingSavedNeed = PendingSavedNeed(id: id, scope: scope, expectsUncarted: true,
                    originalCategoryID: nil, savedCategoryID: savedCategoryID, wasEditing: false)
                refreshProjection()
                completeSaveFeedback()
            } catch { self.error = error }
        }
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
        toastCenter?.show(
            "Item removed",
            duration: .undo,
            action: ShoppingToastAction(
                title: "Undo",
                accessibilityIdentifier: "shopping.grocery.undoRemove"
            ) {
                undo(operationID, scope: scope)
            }
        )
        refreshProjection()
    }

    private func undo(_ operationID: UUID, scope: GroceryAddScope) -> Bool {
        guard let service, let householdID = scope.householdID,
              let listID = scope.listID,
              selection.householdID == householdID, selection.listID == listID,
              canonicalList != nil else {
            toastCenter?.show(
                "Return to the household where you removed the item to undo it.",
                duration: .attention
            )
            return false
        }
        do {
            _ = try service.undoClear(operationID: operationID,
                expectedHouseholdID: householdID, expectedListID: listID)
            refreshProjection()
            return true
        } catch {
            self.error = error
            return false
        }
    }

    private func configureAndRefresh() {
        guard presentation?.isActive != false else { return }
        navigation.configure(
            householdID: selection.householdID,
            activeStoreIDs: Set(activeStores.map(\.id)),
            activeCategoryIDs: Set(activeCategories.map(\.id)),
            scopeNamespace: selection.homeScope?.preferenceNamespace
        )
        refreshProjection()
    }

    private func refreshProjection() {
        guard presentation?.isActive != false else { return }
        personalCart?.refresh()
        projectionTask?.cancel()
        projectionRevision += 1
        let revision = projectionRevision
        guard let householdID = selection.householdID, canonicalList != nil, let service else {
            visibleNeedObjectIDs = []
            return }
        let filter = currentNeedFilter
        projectionTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            do {
                let matchingIDs = try await Task.detached(priority: .userInitiated) {
                    Set(try service.filteredActiveNeedIDs(householdID: householdID, filter: filter))
                }.value
                guard !Task.isCancelled, projectionRevision == revision,
                      selection.householdID == householdID,
                      presentation?.isActive != false else { return }
                visibleNeedObjectIDs = Set(GroceryRowScope.validNeeds(
                    Array(needs), canonicalList: canonicalList
                ).filter { matchingIDs.contains($0.id) }.map(\.objectID))
            } catch {
                guard !Task.isCancelled, projectionRevision == revision else { return }
                self.error = error
                visibleNeedObjectIDs = []
            }
        }
    }

    private var currentNeedFilter: GroceryNeedFilter {
        GroceryNeedFilter(
            purchase: PurchaseFilter(
                selectedStoreID: navigation.selectedStoreID,
                includedStoreIDs: navigation.includedStoreIDs,
                excludedStoreIDs: navigation.excludedStoreIDs
            ),
            text: navigation.searchText,
            categoryID: navigation.categoryID,
            urgency: navigation.urgentOnly ? NeedUrgency.urgent.rawValue : nil
        )
    }

    private func resetView() {
        navigation.searchText = ""
        navigation.selectAll()
        navigation.resetFilters()
        refreshProjection()
    }

    private func shoppingRow(_ need: Need) -> some View {
        GroceryNeedRow(
            need: need,
            activeStores: activeStores,
            selectedStoreID: navigation.selectedStoreID,
            personalCarted: personalCart.map { $0.contains(need.id) },
            presenceNames: personalCart?.presence.filter { $0.needID == need.id }.map { $0.name ?? "Another shopper" } ?? [],
            cartActionAvailable: !(personalCart?.isCartTransitionPending(need.id) ?? false) &&
                !pendingCartActionNeedIDs.contains(need.id),
            quantityActionAvailable: !pendingNeedQuantityIDs.contains(need.id),
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

    private func setCarted(_ need: Need, _ carted: Bool) {
        guard let service, let canonicalList, let householdID = canonicalList.household?.id,
              GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList).contains(need) else { return }
        let needID = need.id
        let name = need.item?.name ?? need.title
        let listID = canonicalList.id
        let personalCart = self.personalCart
        if personalCart?.isCartTransitionPending(needID) == true || pendingCartActionNeedIDs.contains(needID) { return }
        pendingCartActionNeedIDs.insert(needID)
        Task {
            defer { pendingCartActionNeedIDs.remove(needID) }
            do {
                if let personalCart {
                    if carted { try await personalCart.cart(needID) }
                    else if let entry = personalCart.entries.first(where: { $0.needID == needID }) {
                        try await personalCart.uncart(entry)
                    }
                } else {
                    try await Task.detached(priority: .userInitiated) {
                        try service.setNeedCarted(needID: needID, householdID: householdID, listID: listID, carted: carted)
                    }.value
                }
                guard presentation?.isActive != false,
                      selection.householdID == householdID, selection.listID == listID else { return }
                hapticFeedback.play(.lightImpact)
                refreshProjection()
                if carted { showActionFeedback("\(name) moved to In cart.") }
            } catch { self.error = error }
        }
    }

    private func isInMyCart(_ need: Need) -> Bool {
        personalCart?.contains(need.id) ?? need.carted
    }

    private func isOutstanding(_ need: Need) -> Bool {
        personalCart.map { $0.outstandingNeedIDs.contains(need.id) } ?? !need.archived
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
        toastCenter?.show(message, duration: .success)
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
        guard pendingNeedQuantityIDs.insert(needID).inserted else { return }
        let listID = canonicalList.id
        Task {
            defer { pendingNeedQuantityIDs.remove(needID) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try service.setNeedQuantity(
                        needID: needID, householdID: householdID, listID: listID, quantity: quantity)
                }.value
            } catch { self.error = error }
        }
    }
}
