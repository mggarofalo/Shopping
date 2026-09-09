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
    @FetchRequest(fetchRequest: NavigationFetchRequests.needs()) private var needs: FetchedResults<Need>
    @FetchRequest(fetchRequest: NavigationFetchRequests.lists()) private var lists:
        FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households:
        FetchedResults<Household>
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @State private var checkoutDraft: CheckoutDraft?
    @State private var checkoutResult: CheckoutResult?
    @State private var resultNotice: String?
    @State private var clearErrorMessage: String?
    @State private var error: Error?
    var onEdit: ((Need) -> Void)?
    var onUncarted: ((UUID, UUID, UUID) -> Void)?

    init(
        onEdit: ((Need) -> Void)? = nil,
        onUncarted: ((UUID, UUID, UUID) -> Void)? = nil
    ) {
        self.onEdit = onEdit
        self.onUncarted = onUncarted
    }

    var body: some View {
        let allCarted = allScopedCarted
        let activeStores = validActiveStores
        List {
            Section { rows(allCarted, activeStores: activeStores) }
        }
        .listStyle(.plain)
        .overlay {
            if allCarted.isEmpty {
                ContentUnavailableView("Nothing in cart", systemImage: "cart")
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("In cart")
        .sheet(item: $checkoutDraft, content: checkoutSheet)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                resultBar
                if !allCarted.isEmpty {
                    Button { prepareCheckout() } label: {
                        Label(checkoutLabel(count: allCarted.count), systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("shopping.checkout.start")
                }
            }
            .background(.bar)
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

    @ViewBuilder
    private func rows(_ values: [Need], activeStores: [Store]) -> some View {
        ForEach(values, id: \.objectID) { need in
            GroceryNeedRow(
                need: need, activeStores: activeStores, onEdit: onEdit,
                onCartedChange: setCarted, onQuantityChange: setQuantity,
                onRemoved: { operationID, householdID, listID in
                    checkoutResult = CheckoutResult(
                        operationID: operationID, householdID: householdID, listID: listID,
                        cleared: 1, skipped: 0, isIndividualRemoval: true
                    )
                    resultNotice = nil
                }
            )
            .shoppingListRowInsets()
        }
    }

    private func checkoutSheet(_ draft: CheckoutDraft) -> some View {
        NavigationStack {
            List {
                Section {
                    Text("Checkout removes only these captured items from the active list. Items changed after this confirmation opened will be skipped.")
                        .shoppingMultilineText()
                        .accessibilityIdentifier("shopping.checkout.explanation")
                        .shoppingListRowInsets()
                }
                Section("Items (\(draft.preview.rows.count))") {
                    ForEach(draft.preview.rows, id: \.needID) { row in
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.title)
                                    if row.oneTime {
                                        Text("One-time").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                if let quantity = row.quantity {
                                    Text("Quantity \(quantity)").foregroundStyle(.secondary)
                                }
                            }
                            VStack(alignment: .leading) {
                                Text(row.title)
                                if row.oneTime {
                                    Text("One-time").font(.caption).foregroundStyle(.secondary)
                                }
                                if let quantity = row.quantity {
                                    Text("Quantity \(quantity)").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("shopping.checkout.row.\(row.needID.uuidString)")
                        .shoppingListRowInsets()
                    }
                }
                if let clearErrorMessage {
                    Section("Couldn’t checkout") {
                        Text(clearErrorMessage).foregroundStyle(.red)
                            .shoppingMultilineText()
                            .shoppingListRowInsets()
                        Button("Retry") { confirmCheckout(draft) }
                            .disabled(!selectionMatches(draft))
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
            ShoppingFeedbackBar(message: resultNotice)
        } else if let checkoutResult {
            ShoppingFeedbackBar(
                message: checkoutResult.isIndividualRemoval
                    ? "Item removed"
                    : checkoutResult.skipped == 0
                    ? "Checked out \(checkoutResult.cleared) items"
                    : "Checked out \(checkoutResult.cleared); skipped \(checkoutResult.skipped) changed items"
            ) {
                Button("Undo") { undo(checkoutResult) }
                    .frame(minHeight: 44)
                    .disabled(
                        selection.householdID != checkoutResult.householdID
                            || selection.listID != checkoutResult.listID
                    )
                    .accessibilityIdentifier("shopping.checkout.undo")
            }
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

    private var allScopedCarted: [Need] {
        GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList)
            .filter { $0.carted && !$0.archived }
            .sorted {
                let leftUrgent = $0.urgency == NeedUrgency.urgent.rawValue
                let rightUrgent = $1.urgency == NeedUrgency.urgent.rawValue
                if leftUrgent != rightUrgent { return leftUrgent }
                let order = ($0.item?.name ?? $0.title).localizedCaseInsensitiveCompare($1.item?.name ?? $1.title)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
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

}

#Preview("Checklist") {
    ShoppingPreviewHost(.populated) { NavigationStack { CartedGroceriesView() } }
}
