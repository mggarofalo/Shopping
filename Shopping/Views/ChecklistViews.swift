import CoreData
import SwiftUI

private struct ClearCartedDraft: Identifiable {
    let preview: ClearCartedPreview
    let scopeDescription: String
    let householdID: UUID
    let listID: UUID
    var id: UUID { preview.token.id }
}

private struct ClearCartedResult {
    let operationID: UUID
    let householdID: UUID
    let listID: UUID
    let cleared: Int
    let skipped: Int
}

struct CartedGroceriesView: View {
    @Environment(\.needService) private var service
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
    @State private var clearDraft: ClearCartedDraft?
    @State private var clearResult: ClearCartedResult?
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
        let activeStores = validActiveStores
        List {
            Section {
                Button("All carted", action: showAllCarted)
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
                Section("Carted") { rows(carted, activeStores: activeStores) }
            }
            if !carted.isEmpty {
                Section {
                    Button("Clear carted", role: .destructive) { prepareClear(carted) }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("shopping.carted.clear")
                }
            }
        }
        .overlay {
            if carted.isEmpty {
                ContentUnavailableView("Nothing carted in this scope", systemImage: "cart")
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("Carted")
        .sheet(item: $clearDraft, content: clearSheet)
        .safeAreaInset(edge: .bottom) { resultBar }
        .alert(
            "Couldn’t update carted groceries",
            isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error?.localizedDescription ?? "Unknown error")
        }
        .onAppear(perform: refreshProjection)
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange, object: viewContext
            )
        ) { _ in refreshProjection() }
    }

    @ViewBuilder
    private func rows(_ values: [Need], activeStores: [Store]) -> some View {
        ForEach(values, id: \.objectID) { need in
            VStack(alignment: .leading, spacing: 8) {
                GroceryNeedRow(
                    need: need, activeStores: activeStores, onEdit: onEdit,
                    onCartedChange: setCarted, onQuantityChange: setQuantity
                )
                if let onNeedAgain, let item = need.item {
                    Button("Need again \(item.name)") { onNeedAgain(need) }
                        .buttonStyle(.borderless).frame(minHeight: 44)
                        .accessibilityIdentifier("shopping.grocery.needAgain.\(item.id.uuidString)")
                }
            }
        }
    }

    private func clearSheet(_ draft: ClearCartedDraft) -> some View {
        NavigationStack {
            List {
                Section {
                    Text("Only these captured groceries will be cleared, even if filters change.")
                    Text(draft.scopeDescription).font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Groceries (\(draft.preview.rows.count))") {
                    ForEach(draft.preview.rows, id: \.needID) { row in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(row.title)
                                if row.oneTime { Text("One-time").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text("Quantity \(row.quantity)").foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("shopping.clear.row.\(row.needID.uuidString)")
                    }
                }
                if let clearErrorMessage {
                    Section("Couldn’t clear groceries") {
                        Text(clearErrorMessage).foregroundStyle(.red)
                        Button("Retry") { confirmClear(draft) }
                            .disabled(!selectionMatches(draft))
                            .accessibilityIdentifier("shopping.clear.retry")
                    }
                } else if !selectionMatches(draft) {
                    Section {
                        Text("Return to the household and list where this preview was created to continue.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Clear carted?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { clearDraft = nil }
                        .accessibilityIdentifier("shopping.clear.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clear \(draft.preview.rows.count) groceries", role: .destructive) {
                        confirmClear(draft)
                    }
                    .disabled(!selectionMatches(draft))
                    .accessibilityIdentifier("shopping.clear.confirm")
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
        } else if let clearResult {
            HStack {
                Text(
                    clearResult.skipped == 0
                        ? "Cleared \(clearResult.cleared) groceries"
                        : "Cleared \(clearResult.cleared); skipped \(clearResult.skipped) changed groceries"
                )
                .font(.subheadline)
                Spacer()
                Button("Undo") { undo(clearResult) }
                    .frame(minHeight: 44)
                    .disabled(
                        selection.householdID != clearResult.householdID
                            || selection.listID != clearResult.listID
                    )
                    .accessibilityIdentifier("shopping.clear.undo")
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
        return parts.isEmpty ? "All carted groceries" : parts.joined(separator: " · ")
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

    private func showAllCarted() {
        filter = GroceryNeedFilter(carted: true)
        refreshProjection()
    }

    private func setCarted(_ need: Need, _ carted: Bool) {
        mutate(need) { service, needID, householdID, listID in
            try service.setNeedCarted(
                needID: needID, householdID: householdID, listID: listID, carted: carted)
            if !carted { onUncarted?(needID, householdID, listID) }
        }
    }

    private func setQuantity(_ need: Need, _ quantity: Int64) {
        mutate(need) {
            try $0.setNeedQuantity(needID: $1, householdID: $2, listID: $3, quantity: quantity)
        }
    }

    private func mutate(_ need: Need, command: (NeedService, UUID, UUID, UUID) throws -> Void) {
        guard let service, let list = canonicalList, let householdID = list.household?.id,
            GroceryRowScope.validNeeds(Array(needs), canonicalList: list).contains(need)
        else { return }
        let needID = need.id
        do {
            try command(service, needID, householdID, list.id)
            refreshProjection()
        } catch { self.error = error }
    }

    private func prepareClear(_ rows: [Need]) {
        guard let service, let list = canonicalList, let householdID = list.household?.id else {
            return
        }
        let frozenScope = scopeDescription
        do {
            clearErrorMessage = nil
            let preview = try service.prepareClearCarted(
                householdID: householdID, listID: list.id, filter: filter,
                restrictedToNeedIDs: Set(rows.map(\.id))
            )
            clearDraft = ClearCartedDraft(
                preview: preview, scopeDescription: frozenScope,
                householdID: householdID, listID: list.id)
        } catch { self.error = error }
    }

    private func selectionMatches(_ draft: ClearCartedDraft) -> Bool {
        selection.householdID == draft.householdID && selection.listID == draft.listID
            && canonicalList != nil
    }

    private func confirmClear(_ draft: ClearCartedDraft) {
        guard let service, selectionMatches(draft) else { return }
        do {
            let cleared = try service.clearCarted(using: draft.preview.token)
            clearResult = ClearCartedResult(
                operationID: draft.preview.token.id,
                householdID: draft.householdID, listID: draft.listID,
                cleared: cleared, skipped: draft.preview.rows.count - cleared)
            resultNotice = nil
            clearErrorMessage = nil
            clearDraft = nil
            refreshProjection()
        } catch { clearErrorMessage = error.localizedDescription }
    }

    private func undo(_ result: ClearCartedResult) {
        guard let service, selection.householdID == result.householdID,
            selection.listID == result.listID
        else { return }
        do {
            let restored = try service.undoClear(
                operationID: result.operationID,
                expectedHouseholdID: result.householdID, expectedListID: result.listID)
            clearResult = nil
            resultNotice = restoreMessage(restored: restored, expected: result.cleared)
            refreshProjection()
        } catch { self.error = error }
    }

    private func restoreMessage(restored: Int, expected: Int) -> String {
        let skipped = max(0, expected - restored)
        if restored == 0 {
            return "Nothing restored. These groceries were already restored or have newer changes."
        }
        if skipped > 0 {
            return "Restored \(restored); skipped \(skipped) with newer changes."
        }
        return restored == 1 ? "Restored 1 grocery" : "Restored \(restored) groceries"
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
