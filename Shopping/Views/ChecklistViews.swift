import CoreData
import SwiftUI
#if DEBUG
import Darwin
#endif

private struct CheckoutDraft: Identifiable {
    let preview: ClearCartedPreview
    let householdID: UUID
    let listID: UUID
    var id: UUID { preview.token.id }
}

private struct CheckoutResult {
    let operationID: UUID
    let householdID: UUID
    let listID: UUID
    let cleared: Int
    let skipped: Int
    var isIndividualRemoval = false
}

struct CartedGroceriesView: View {
    @Environment(\.needService) private var service
    @Environment(\.hapticFeedback) private var hapticFeedback
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(fetchRequest: NavigationFetchRequests.needs()) private var needs: FetchedResults<Need>
    @FetchRequest(fetchRequest: NavigationFetchRequests.lists()) private var lists:
        FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households:
        FetchedResults<Household>
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories:
        FetchedResults<Category>
    @State private var filter: GroceryNeedFilter
    @State private var matchingNeedIDs: Set<UUID> = []
    @State private var checkoutDraft: CheckoutDraft?
    @State private var checkoutResult: CheckoutResult?
    @State private var resultNotice: String?
    @State private var clearErrorMessage: String?
    @State private var error: Error?
    var onEdit: ((Need) -> Void)?
    var onNeedAgain: ((Need) -> Void)?
    var onUncarted: ((UUID, UUID, UUID) -> Void)?

    init(
        initialFilter: GroceryNeedFilter = GroceryNeedFilter(),
        onEdit: ((Need) -> Void)? = nil,
        onNeedAgain: ((Need) -> Void)? = nil,
        onUncarted: ((UUID, UUID, UUID) -> Void)? = nil
    ) {
        _filter = State(
            initialValue: GroceryNeedFilter(
                purchase: initialFilter.purchase,
                text: initialFilter.text,
                categoryID: initialFilter.categoryID,
                carted: true,
                urgency: initialFilter.urgency
            ))
        self.onEdit = onEdit
        self.onNeedAgain = onNeedAgain
        self.onUncarted = onUncarted
    }

    var body: some View {
        let carted = scopedCarted
        let allCarted = allScopedCarted
        let activeStores = validActiveStores
        List {
            if !allCarted.isEmpty {
                Section {
                    Button { prepareCheckout() } label: {
                        Label(checkoutLabel(count: allCarted.count), systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Includes all items in cart, even when this view is filtered")
                    .accessibilityIdentifier("shopping.checkout.start")
                }
            }
            Section {
                Button("All in cart", action: showAllCarted)
                    .accessibilityIdentifier("shopping.carted.all")
                Text(scopeDescription).font(.footnote).foregroundStyle(.secondary)
            }
            if let storeID = filter.purchase.selectedStoreID {
                Section("Must buy here") {
                    rows(
                        carted.filter { availability($0, storeID: storeID) == .mustBuyHere },
                        activeStores: activeStores)
                }
                Section("Flexible here") {
                    rows(
                        carted.filter { availability($0, storeID: storeID) == .flexibleHere },
                        activeStores: activeStores)
                }
            } else {
                Section("In cart") { rows(carted, activeStores: activeStores) }
            }
        }
        .overlay {
            if allCarted.isEmpty {
                ContentUnavailableView("Nothing in cart", systemImage: "cart")
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("In cart")
        .sheet(item: $checkoutDraft, content: checkoutSheet)
        .safeAreaInset(edge: .bottom) { resultBar }
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
        .onAppear(perform: sanitizeFilterAndRefresh)
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange, object: viewContext
            )
        ) { _ in sanitizeFilterAndRefresh() }
    }

    @ViewBuilder
    private func rows(_ values: [Need], activeStores: [Store]) -> some View {
        ForEach(values, id: \.objectID) { need in
            VStack(alignment: .leading, spacing: 8) {
                GroceryNeedRow(
                    need: need, activeStores: activeStores, onEdit: onEdit,
                    onCartedChange: setCarted, onQuantityChange: setQuantity,
                    onRemoved: { operationID, householdID, listID in
                        checkoutResult = CheckoutResult(
                            operationID: operationID, householdID: householdID, listID: listID,
                            cleared: 1, skipped: 0, isIndividualRemoval: true
                        )
                        resultNotice = nil
                        refreshProjection()
                    }
                )
                if let onNeedAgain, let item = need.item {
                    Button("Need again \(item.name)") { onNeedAgain(need) }
                        .buttonStyle(.borderless).frame(minHeight: 44)
                        .accessibilityIdentifier("shopping.grocery.needAgain.\(item.id.uuidString)")
                }
            }
        }
    }

    private func checkoutSheet(_ draft: CheckoutDraft) -> some View {
        NavigationStack {
            List {
                Section {
                    Text("Checkout removes only these captured items from the active list. Items changed after this confirmation opened will be skipped.")
                }
                Section("Items (\(draft.preview.rows.count))") {
                    ForEach(draft.preview.rows, id: \.needID) { row in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(row.title)
                                if row.oneTime { Text("One-time").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if let quantity = row.quantity {
                                Text("Quantity \(quantity)").foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("shopping.checkout.row.\(row.needID.uuidString)")
                    }
                }
                if let clearErrorMessage {
                    Section("Couldn’t checkout") {
                        Text(clearErrorMessage).foregroundStyle(.red)
                        Button("Retry") { confirmCheckout(draft) }
                            .disabled(!selectionMatches(draft))
                            .accessibilityIdentifier("shopping.checkout.retry")
                    }
                } else if !selectionMatches(draft) {
                    Section {
                        Text("Return to the household and list where this preview was created to continue.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Checkout?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { checkoutDraft = nil }
                        .accessibilityIdentifier("shopping.checkout.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(checkoutLabel(count: draft.preview.rows.count)) {
                        confirmCheckout(draft)
                    }
                    .disabled(!selectionMatches(draft))
                    .accessibilityIdentifier("shopping.checkout.confirm")
                }
            }
        }
    }

    @ViewBuilder private var resultBar: some View {
        if let resultNotice {
            HStack {
                Text(resultNotice).font(.subheadline)
                Spacer()
            }
            .padding().background(.bar)
        } else if let checkoutResult {
            HStack {
                Text(
                    checkoutResult.isIndividualRemoval
                        ? "Item removed"
                        : checkoutResult.skipped == 0
                        ? "Checked out \(checkoutResult.cleared) items"
                        : "Checked out \(checkoutResult.cleared); skipped \(checkoutResult.skipped) changed items"
                )
                .font(.subheadline)
                Spacer()
                Button("Undo") { undo(checkoutResult) }
                    .frame(minHeight: 44)
                    .disabled(
                        selection.householdID != checkoutResult.householdID
                            || selection.listID != checkoutResult.listID
                    )
                    .accessibilityIdentifier("shopping.checkout.undo")
            }
            .padding().background(.bar)
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

    private var scopedCarted: [Need] {
        GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList)
            .filter { $0.carted && !$0.archived && matchingNeedIDs.contains($0.id) }
            .sorted {
                let leftUrgent = $0.urgency == NeedUrgency.urgent.rawValue
                let rightUrgent = $1.urgency == NeedUrgency.urgent.rawValue
                if leftUrgent != rightUrgent { return leftUrgent }
                let order = ($0.item?.name ?? $0.title).localizedCaseInsensitiveCompare($1.item?.name ?? $1.title)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
    }

    private var allScopedCarted: [Need] {
        GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList)
            .filter { $0.carted && !$0.archived }
    }

    private var scopeDescription: String {
        var parts: [String] = []
        let storeName: (UUID) -> String = { id in
            validActiveStores.first(where: { $0.id == id })?.name ?? "selected store"
        }
        if let id = filter.purchase.selectedStoreID { parts.append("Available at \(storeName(id))") }
        if !filter.purchase.includedStoreIDs.isEmpty {
            parts.append(
                "tagged " + filter.purchase.includedStoreIDs.map(storeName).sorted().joined(separator: ", ")
            )
        }
        if !filter.purchase.excludedStoreIDs.isEmpty {
            parts.append(
                "excluding tags "
                    + filter.purchase.excludedStoreIDs.map(storeName).sorted().joined(separator: ", "))
        }
        if !filter.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("matching “\(filter.text)”")
        }
        if let id = filter.categoryID {
            let name =
                GroceryRowScope.validCategories(Array(categories), canonicalList: canonicalList)
                .first(where: { $0.id == id })?.name ?? "selected category"
            parts.append("category \(name)")
        }
        if filter.urgency == NeedUrgency.urgent.rawValue { parts.append("Urgent") }
        return parts.isEmpty ? "All groceries in cart" : parts.joined(separator: " · ")
    }

    private func refreshProjection() {
        guard let service, let list = canonicalList, let householdID = list.household?.id else {
            matchingNeedIDs = []
            return
        }
        do {
            matchingNeedIDs = Set(
                try service.filteredActiveNeedIDs(householdID: householdID, filter: filter))
        } catch {
            self.error = error
            matchingNeedIDs = []
        }
    }

    private func sanitizeFilterAndRefresh() {
        filter = filter.sanitized(
            activeStoreIDs: Set(validActiveStores.map(\.id)),
            activeCategoryIDs: Set(
                GroceryRowScope.validCategories(Array(categories), canonicalList: canonicalList).map(\.id)
            )
        )
        refreshProjection()
    }

    private func showAllCarted() {
        filter = GroceryNeedFilter(carted: true)
        refreshProjection()
    }

    private func setCarted(_ need: Need, _ carted: Bool) {
        if mutate(need, command: { service, needID, householdID, listID in
            try service.setNeedCarted(
                needID: needID, householdID: householdID, listID: listID, carted: carted)
            if !carted { onUncarted?(needID, householdID, listID) }
        }) { hapticFeedback.play(.lightImpact) }
    }

    private func setQuantity(_ need: Need, _ quantity: Int64?) {
        mutate(need) {
            try $0.setNeedQuantity(needID: $1, householdID: $2, listID: $3, quantity: quantity)
        }
    }

    @discardableResult
    private func mutate(
        _ need: Need,
        command: (NeedService, UUID, UUID, UUID) throws -> Void
    ) -> Bool {
        guard let service, let list = canonicalList, let householdID = list.household?.id,
            GroceryRowScope.validNeeds(Array(needs), canonicalList: list).contains(need)
        else { return false }
        let needID = need.id
        do {
            try command(service, needID, householdID, list.id)
            refreshProjection()
            return true
        } catch {
            self.error = error
            return false
        }
    }

    private func prepareCheckout() {
        guard let service, let list = canonicalList, let householdID = list.household?.id else {
            return
        }
        do {
            clearErrorMessage = nil
            let preview = try service.prepareCheckout(householdID: householdID, listID: list.id)
            checkoutDraft = CheckoutDraft(
                preview: preview,
                householdID: householdID, listID: list.id)
        } catch { self.error = error }
    }

    private func selectionMatches(_ draft: CheckoutDraft) -> Bool {
        selection.householdID == draft.householdID && selection.listID == draft.listID
            && canonicalList != nil
    }

    private func confirmCheckout(_ draft: CheckoutDraft) {
        guard let service, selectionMatches(draft) else { return }
        do {
            let cleared = try service.clearCarted(using: draft.preview.token)
#if DEBUG
            // Exercise the committed-save / UI-acknowledgement boundary without graceful teardown.
            if ProcessInfo.processInfo.environment["SHOPPING_UI_TEST_STORE_PATH"] != nil,
                ProcessInfo.processInfo.environment["SHOPPING_UI_TEST_EXIT_AFTER_CLEAR"] == "1" {
                _exit(0)
            }
#endif
            checkoutResult = CheckoutResult(
                operationID: draft.preview.token.id,
                householdID: draft.householdID, listID: draft.listID,
                cleared: cleared, skipped: draft.preview.rows.count - cleared)
            resultNotice = nil
            clearErrorMessage = nil
            checkoutDraft = nil
            refreshProjection()
            if cleared > 0 { hapticFeedback.play(.success) }
        } catch { clearErrorMessage = error.localizedDescription }
    }

    private func undo(_ result: CheckoutResult) {
        guard let service, selection.householdID == result.householdID,
            selection.listID == result.listID
        else { return }
        do {
            let restored = try service.undoClear(
                operationID: result.operationID,
                expectedHouseholdID: result.householdID, expectedListID: result.listID)
            checkoutResult = nil
            resultNotice = restoreMessage(restored: restored, expected: result.cleared)
            refreshProjection()
        } catch { self.error = error }
    }

    private func checkoutLabel(count: Int) -> String {
        count == 1 ? "Checkout 1 item" : "Checkout \(count) items"
    }

    private func restoreMessage(restored: Int, expected: Int) -> String {
        let skipped = max(0, expected - restored)
        if restored == 0 {
            return "Nothing restored. These groceries were already restored or have newer changes."
        }
        if skipped > 0 {
            return "Restored \(restored); skipped \(skipped) with newer changes."
        }
        return restored == 1 ? "Restored 1 item" : "Restored \(restored) items"
    }

    private func availability(_ need: Need, storeID: UUID) -> PurchaseAvailability {
        let oneTime = need.kind == NeedKind.oneTime.rawValue
        let value = PurchaseRuleValue(
            explicitStoreIDs: need.item.map { Set($0.stores?.map(\.id) ?? []) }
                ?? (oneTime ? Set(need.oneTimeStores?.map(\.id) ?? []) : []),
            anyStore: need.item?.anyStore ?? (oneTime && need.oneTimeAnyStore)
        )
        return PurchaseFilter().availability(
            of: value, selectedStoreID: storeID,
            activeStoreIDs: Set(validActiveStores.map(\.id)))
    }
}

#Preview("Checklist") {
    ShoppingPreviewHost(.populated) { NavigationStack { CartedGroceriesView() } }
}
