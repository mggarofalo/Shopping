import CoreData
import SwiftUI
#if DEBUG
import Darwin
#endif

struct CartedGroceriesView: View {
    @Environment(\.needService) private var service
    @Environment(\.hapticFeedback) private var hapticFeedback
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.shoppingToastCenter) private var toastCenter
    @FetchRequest(fetchRequest: NavigationFetchRequests.needs()) private var needs: FetchedResults<Need>
    @FetchRequest(fetchRequest: NavigationFetchRequests.lists()) private var lists:
        FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households:
        FetchedResults<Household>
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories:
        FetchedResults<Category>
    @State private var checkoutDraft: CheckoutDraft?
    @State private var clearErrorMessage: String?
    @State private var error: Error?
    var onEdit: ((Need) -> Void)?
    var onUncarted: ((UUID, UUID, UUID) -> Void)?
    var onRemoved: ((UUID, UUID, UUID) -> Void)?

    init(
        onEdit: ((Need) -> Void)? = nil,
        onUncarted: ((UUID, UUID, UUID) -> Void)? = nil,
        onRemoved: ((UUID, UUID, UUID) -> Void)? = nil
    ) {
        self.onEdit = onEdit
        self.onUncarted = onUncarted
        self.onRemoved = onRemoved
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
            if !allCarted.isEmpty {
                HStack {
                    Spacer()
                    Button { prepareCheckout() } label: {
                        Label(checkoutLabel(count: allCarted.count), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(checkoutLabel(count: allCarted.count))
                    .accessibilityIdentifier("shopping.checkout.start")
                    .padding(.trailing)
                    .padding(.bottom, 8)
                }
            }
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
                onRemoved: onRemoved
            )
            .shoppingListRowInsets()
        }
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
            .listStyle(.plain)
            .navigationTitle("Checkout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { checkoutDraft = nil } label: {
                        Label("Cancel", systemImage: "xmark").labelStyle(.iconOnly)
                    }
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
                    .disabled(!selectionMatches(draft))
                    .accessibilityLabel(checkoutLabel(count: draft.preview.rows.count))
                    .accessibilityIdentifier("shopping.checkout.confirm")
                }
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
        CartedNeedOrdering.ordered(
            GroceryRowScope.validNeeds(Array(needs), canonicalList: canonicalList)
                .filter { $0.carted && !$0.archived },
            categories: Array(categories),
            household: canonicalList?.household
        )
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
            let result = CheckoutResult(
                operationID: draft.preview.token.id,
                householdID: draft.householdID, listID: draft.listID,
                cleared: cleared, skipped: draft.preview.rows.count - cleared)
            let message = result.skipped == 0
                ? "Checked out \(result.cleared) items"
                : "Checked out \(result.cleared); skipped \(result.skipped) changed items"
            toastCenter?.show(
                message,
                duration: .undo,
                action: ShoppingToastAction(
                    title: "Undo",
                    accessibilityIdentifier: "shopping.checkout.undo"
                ) {
                    undo(result)
                }
            )
            clearErrorMessage = nil
            checkoutDraft = nil
            if cleared > 0 { hapticFeedback.play(.success) }
        } catch { clearErrorMessage = error.localizedDescription }
    }

    private func undo(_ result: CheckoutResult) -> Bool {
        guard let service, selection.householdID == result.householdID,
            selection.listID == result.listID
        else { return false }
        do {
            let restored = try service.undoClear(
                operationID: result.operationID,
                expectedHouseholdID: result.householdID, expectedListID: result.listID)
            showRestoreNotice(restored: restored, expected: result.cleared)
            return true
        } catch {
            self.error = error
            return false
        }
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
    ShoppingPreviewHost(.populated) { NavigationStack { CartedGroceriesView() } }
}
