import CoreData
import SwiftUI
#if DEBUG
import Darwin
#endif

struct CartedGroceriesView: View {
    @Environment(\.persistencePresentation) private var presentation
    @Environment(\.needService) private var service
    @Environment(\.hapticFeedback) private var hapticFeedback
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.shoppingToastCenter) private var toastCenter
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(fetchRequest: NavigationFetchRequests.needs()) private var needs: FetchedResults<Need>
    @FetchRequest(fetchRequest: NavigationFetchRequests.lists()) private var lists:
        FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households:
        FetchedResults<Household>
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories:
        FetchedResults<Category>
    @ObservedObject var navigation: GroceryNavigationState
    @State private var visibleNeedObjectIDs: Set<NSManagedObjectID> = []
    @State private var projectionTask: Task<Void, Never>?
    @State private var projectionRevision = 0
    @State private var pendingCartNeedIDs: Set<UUID> = []
    @State private var pendingQuantityNeedIDs: Set<UUID> = []
    @State private var isPreparingCheckout = false
    @State private var isConfirmingCheckout = false
    @State private var showingFilters = false
    @State private var checkoutDraft: CheckoutDraft?
    @State private var clearErrorMessage: String?
    @State private var error: Error?
    var onEdit: ((Need) -> Void)?
    var onUncarted: ((UUID, UUID, UUID) -> Void)?
    var onRemoved: ((UUID, UUID, UUID) -> Void)?

    init(
        navigation: GroceryNavigationState,
        onEdit: ((Need) -> Void)? = nil,
        onUncarted: ((UUID, UUID, UUID) -> Void)? = nil,
        onRemoved: ((UUID, UUID, UUID) -> Void)? = nil
    ) {
        self.navigation = navigation
        self.onEdit = onEdit
        self.onUncarted = onUncarted
        self.onRemoved = onRemoved
    }

    var body: some View {
        if presentation?.isActive != false { activeBody }
    }

    @ViewBuilder
    private var activeBody: some View {
        let visibleCarted = visibleCartedNeeds
        let activeStores = validActiveStores
        List {
            Section {
                GroceryScopeControls(
                    navigation: navigation,
                    stores: activeStores,
                    categories: activeCategories,
                    showFilters: { showingFilters = true }
                )
                .buttonStyle(.borderless)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            if visibleCarted.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(hasViewNarrowing ? "No matching cart items" : "Nothing in cart", systemImage: "cart")
                    } description: {
                        if hasViewNarrowing {
                            Text("Your filters may hide items already in the cart.")
                        }
                    } actions: {
                        if hasViewNarrowing {
                            Button("Reset filters", action: resetView)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                CompactGrocerySections(
                    sections: grocerySections,
                    itemID: \.objectID
                ) { _, need in
                    row(need, activeStores: activeStores)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.custom(8))
        .navigationTitle("In cart")
        .searchable(text: $navigation.searchText, prompt: "Search groceries")
        .sheet(isPresented: $showingFilters) {
            GroceryFiltersView(
                navigation: navigation,
                stores: activeStores,
                categories: activeCategories,
                onReset: resetView
            )
        }
        .sheet(item: $checkoutDraft, content: checkoutSheet)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !visibleCarted.isEmpty {
                HStack {
                    Spacer()
                    Button { prepareCheckout() } label: {
                        Label(checkoutLabel(count: visibleCarted.count), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPreparingCheckout || isConfirmingCheckout)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(checkoutLabel(count: visibleCarted.count))
                    .accessibilityIdentifier("shopping.checkout.start")
                    .padding(.trailing)
                    .padding(.bottom, 8)
                }
            }
        }
        .onAppear(perform: configureAndRefresh)
        .onChange(of: navigation.searchText) { _, _ in refreshProjection() }
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
            guard presentation?.isActive != false else { return }
            configureAndRefresh()
        }
        .alert(
            "Couldn’t update groceries in cart",
            isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error?.localizedDescription ?? "Unknown error")
        }
    }

    private func row(_ need: Need, activeStores: [Store]) -> some View {
        GroceryNeedRow(
            need: need, activeStores: activeStores,
            selectedStoreID: navigation.selectedStoreID,
            cartActionAvailable: !pendingCartNeedIDs.contains(need.id),
            quantityActionAvailable: !pendingQuantityNeedIDs.contains(need.id),
            onEdit: onEdit,
            onCartedChange: setCarted, onQuantityChange: setQuantity,
            onRemoved: onRemoved
        )
        .shoppingListRowInsets()
    }

    private func checkoutSheet(_ draft: CheckoutDraft) -> some View {
        NavigationStack {
            List {
                Section("Items (\(draft.preview.rows.count))") {
                    ForEach(draft.preview.rows, id: \.needID) { row in
                        CheckoutPreviewRow(row: row)
                        .shoppingListRowInsets()
                    }
                }
                if let clearErrorMessage {
                    Section("Couldn’t checkout") {
                        Text(clearErrorMessage).foregroundStyle(.red)
                            .shoppingMultilineText()
                            .shoppingListRowInsets()
                        Button("Retry") { confirmCheckout(draft) }
                            .disabled(isConfirmingCheckout || !selectionMatches(draft))
                            .accessibilityIdentifier("shopping.checkout.retry")
                            .shoppingListRowInsets()
                    }
                } else if !selectionMatches(draft) {
                    Section {
                        Text("Return to the household and list where this preview was created to continue.")
                            .foregroundStyle(.secondary)
                            .shoppingMultilineText()
                            .shoppingListRowInsets()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Checkout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { checkoutDraft = nil } label: {
                        Label("Cancel", systemImage: "xmark").labelStyle(.iconOnly)
                    }
                        .disabled(isConfirmingCheckout)
                        .accessibilityLabel("Cancel")
                        .accessibilityIdentifier("shopping.checkout.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        confirmCheckout(draft)
                    } label: {
                        Label(checkoutLabel(count: draft.preview.rows.count), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(isConfirmingCheckout || !selectionMatches(draft))
                    .accessibilityLabel(checkoutLabel(count: draft.preview.rows.count))
                    .accessibilityIdentifier("shopping.checkout.confirm")
                }
            }
            .interactiveDismissDisabled(isConfirmingCheckout)
        }
    }

    private var canonicalList: GroceryList? {
        GroceryRowScope.canonicalList(Array(lists), households: Array(households), selection: selection)
    }

    private var validActiveStores: [Store] {
        GroceryRowScope.validStores(Array(stores), canonicalList: canonicalList).filter {
            !$0.isArchived
        }
    }

    private var activeCategories: [Category] {
        GroceryRowScope.validCategories(Array(categories), canonicalList: canonicalList).filter {
            !$0.isArchived
        }
    }

    private var allScopedCartedNeeds: [Need] {
        GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList).filter {
            $0.carted && !$0.archived
        }
    }

    private var visibleCartedNeeds: [Need] {
        allScopedCartedNeeds.filter { visibleNeedObjectIDs.contains($0.objectID) }
    }

    private var grocerySections: [ItemCollectionSection<GroceryCollectionSectionID, Need>] {
        GroceryCollectionProjection.sections(
            needs: visibleCartedNeeds,
            selectedStoreID: navigation.selectedStoreID,
            activeStores: validActiveStores,
            categories: Array(categories),
            household: canonicalList?.household
        )
    }

    private var hasViewNarrowing: Bool {
        navigation.selectedStoreID != nil || navigation.activeFilterCount > 0 || !navigation.searchText.isEmpty
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
            carted: true,
            urgency: navigation.urgentOnly ? NeedUrgency.urgent.rawValue : nil
        )
    }

    private func configureAndRefresh() {
        guard presentation?.isActive != false else { return }
        navigation.configure(
            householdID: selection.householdID,
            activeStoreIDs: Set(validActiveStores.map(\.id)),
            activeCategoryIDs: Set(activeCategories.map(\.id))
        )
        refreshProjection()
    }

    private func refreshProjection() {
        guard presentation?.isActive != false else { return }
        projectionTask?.cancel()
        projectionRevision += 1
        let revision = projectionRevision
        guard let service, let householdID = selection.householdID, canonicalList != nil else {
            visibleNeedObjectIDs = []
            return
        }
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
                visibleNeedObjectIDs = Set(allScopedCartedNeeds.filter {
                    matchingIDs.contains($0.id)
                }.map(\.objectID))
            } catch {
                guard !Task.isCancelled, projectionRevision == revision else { return }
                self.error = error
                visibleNeedObjectIDs = []
            }
        }
    }

    private func resetView() {
        navigation.searchText = ""
        navigation.selectAll()
        navigation.resetFilters()
        refreshProjection()
    }

    private func setCarted(_ need: Need, _ carted: Bool) {
        guard let service, let list = canonicalList, let householdID = list.household?.id,
              GroceryRowScope.validNeeds(Array(needs), canonicalList: list).contains(need),
              !pendingCartNeedIDs.contains(need.id) else { return }
        let needID = need.id, listID = list.id
        pendingCartNeedIDs.insert(needID)
        Task {
            defer { pendingCartNeedIDs.remove(needID) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try service.setNeedCarted(needID: needID, householdID: householdID,
                        listID: listID, carted: carted)
                }.value
                guard selection.householdID == householdID, selection.listID == listID else { return }
                if !carted { onUncarted?(needID, householdID, listID) }
                hapticFeedback.play(.lightImpact)
                refreshProjection()
            } catch { self.error = error }
        }
    }

    private func setQuantity(_ need: Need, _ quantity: Int64?) {
        guard let service, let list = canonicalList, let householdID = list.household?.id,
              GroceryRowScope.validNeeds(Array(needs), canonicalList: list).contains(need),
              !pendingQuantityNeedIDs.contains(need.id) else { return }
        let needID = need.id, listID = list.id
        pendingQuantityNeedIDs.insert(needID)
        Task {
            defer { pendingQuantityNeedIDs.remove(needID) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try service.setNeedQuantity(needID: needID, householdID: householdID,
                        listID: listID, quantity: quantity)
                }.value
            } catch { self.error = error }
        }
    }

    private func prepareCheckout() {
        guard !isPreparingCheckout, let service, let list = canonicalList,
              let householdID = list.household?.id else { return }
        isPreparingCheckout = true
        clearErrorMessage = nil
        let listID = list.id, filter = currentNeedFilter
        let needIDs = Set(visibleCartedNeeds.map(\.id))
        Task {
            defer { isPreparingCheckout = false }
            do {
                let preview = try await Task.detached(priority: .userInitiated) {
                    try service.prepareClearCarted(householdID: householdID, listID: listID,
                        filter: filter, restrictedToNeedIDs: needIDs)
                }.value
                guard selection.householdID == householdID, selection.listID == listID else { return }
                checkoutDraft = CheckoutDraft(preview: preview,
                    householdID: householdID, listID: listID)
            } catch { self.error = error }
        }
    }

    private func selectionMatches(_ draft: CheckoutDraft) -> Bool {
        selection.householdID == draft.householdID && selection.listID == draft.listID
            && canonicalList != nil
    }

    private func confirmCheckout(_ draft: CheckoutDraft) {
        guard !isConfirmingCheckout, let service, selectionMatches(draft) else { return }
        isConfirmingCheckout = true
        let token = draft.preview.token
        let rowCount = draft.preview.rows.count
        clearErrorMessage = nil
        Task {
            defer { isConfirmingCheckout = false }
            do {
                let cleared = try await Task.detached(priority: .userInitiated) {
                    try service.clearCarted(using: token)
                }.value
#if DEBUG
                // Exercise the committed-save / UI-acknowledgement boundary without graceful teardown.
                if ProcessInfo.processInfo.environment["SHOPPING_UI_TEST_STORE_PATH"] != nil,
                    ProcessInfo.processInfo.environment["SHOPPING_UI_TEST_EXIT_AFTER_CLEAR"] == "1" {
                    _exit(0)
                }
#endif
                guard selectionMatches(draft) else { return }
                let result = CheckoutResult(operationID: token.id,
                    householdID: draft.householdID, listID: draft.listID,
                    cleared: cleared, skipped: rowCount - cleared)
                let message = result.skipped == 0
                    ? "Checked out \(result.cleared) items"
                    : "Checked out \(result.cleared); skipped \(result.skipped) changed items"
                toastCenter?.show(message, duration: .undo,
                    action: ShoppingToastAction(title: "Undo",
                        accessibilityIdentifier: "shopping.checkout.undo") { undo(result) })
                clearErrorMessage = nil
                checkoutDraft = nil
                if cleared > 0 { hapticFeedback.play(.success) }
            } catch { clearErrorMessage = error.localizedDescription }
        }
    }

    private func undo(_ result: CheckoutResult) -> Bool {
        guard let service, selection.householdID == result.householdID,
            selection.listID == result.listID
        else { return false }
        let operationID = result.operationID, householdID = result.householdID, listID = result.listID
        Task {
            do {
                let restored = try await Task.detached(priority: .userInitiated) {
                    try service.undoClear(operationID: operationID,
                        expectedHouseholdID: householdID, expectedListID: listID)
                }.value
                guard selection.householdID == householdID, selection.listID == listID else { return }
                showRestoreNotice(restored: restored, expected: result.cleared)
            } catch { self.error = error }
        }
        return true
    }

    private func checkoutLabel(count: Int) -> String {
        count == 1 ? "Checkout 1 item" : "Checkout \(count) items"
    }

    private func showRestoreNotice(restored: Int, expected: Int) {
        let skipped = max(0, expected - restored)
        if restored == 0 {
            toastCenter?.show(
                "Nothing restored. These groceries were already restored or have newer changes.",
                duration: .attention
            )
        } else if skipped > 0 {
            toastCenter?.show(
                "Restored \(restored); skipped \(skipped) with newer changes.",
                duration: .attention
            )
        } else {
            toastCenter?.show(
                restored == 1 ? "Restored 1 item" : "Restored \(restored) items",
                duration: .success
            )
        }
    }

}

#Preview("Checklist") {
    ShoppingPreviewHost(.populated) {
        NavigationStack { CartedGroceriesView(navigation: GroceryNavigationState()) }
    }
}
