import CoreData
import SwiftUI

struct PurchaseRulesPicker: View {
    @Environment(\.persistenceSelection) private var selection
    @Binding var storeIDs: Set<UUID>
    @Binding var anyStore: Bool
    let householdID: UUID?
    let listID: UUID?
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: PurchaseRulesStoreScope.listsRequest()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    let onAddStore: () -> Void

    init(
        storeIDs: Binding<Set<UUID>>,
        anyStore: Binding<Bool>,
        householdID: UUID?,
        listID: UUID?,
        onAddStore: @escaping () -> Void
    ) {
        _storeIDs = storeIDs
        _anyStore = anyStore
        self.householdID = householdID
        self.listID = listID
        self.onAddStore = onAddStore
    }

    private var scopedListID: UUID? {
        listID ?? (selection.householdID == householdID ? selection.listID : nil)
    }

    private var validStores: [Store] {
        GroceryRowScope.validStores(Array(stores), canonicalList: canonicalList)
    }

    private var canonicalList: GroceryList? {
        guard selection.householdID == householdID, selection.listID == scopedListID else { return nil }
        return GroceryRowScope.canonicalList(Array(lists), households: Array(households), selection: selection)
    }

    var body: some View {
        Group {
            Section("Where to buy") {
                Button(action: onAddStore) { Label("Add store", systemImage: "plus") }
                    .accessibilityIdentifier("shopping.tags.addStore")
                    .disabled(canonicalList == nil)
                PillFlowLayout {
                    SelectionPill(
                        title: "Any store",
                        isSelected: anyStore || storeIDs.isEmpty,
                        identifier: "shopping.purchase.anyStore"
                    ) { anyStore = storeIDs.isEmpty ? false : !anyStore }
                    ForEach(validStores.filter { !$0.isArchived || storeIDs.contains($0.id) }, id: \.objectID) { store in
                        SelectionPill(
                            title: store.isArchived ? "\(store.name) · Archived" : store.name,
                            isSelected: storeIDs.contains(store.id),
                            identifier: "shopping.purchase.store.\(store.id.uuidString)"
                        ) {
                            if storeIDs.contains(store.id) {
                                storeIDs.remove(store.id)
                                if storeIDs.isEmpty { anyStore = false }
                            } else {
                                if storeIDs.isEmpty { anyStore = false }
                                storeIDs.insert(store.id)
                            }
                        }
                    }
                }
                if anyStore && !storeIDs.isEmpty {
                    Text("Can buy at any store; the saved stores remain available if you turn this off.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                let unavailable = storeIDs.subtracting(Set(validStores.map(\.id)))
                if !unavailable.isEmpty {
                    Text("Remove unavailable stores, then choose where to buy.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Remove unavailable stores", systemImage: "xmark.circle") {
                        storeIDs.subtract(unavailable)
                    }
                }
                if !anyStore && !storeIDs.isEmpty &&
                    !validStores.contains(where: { !$0.isArchived && storeIDs.contains($0.id) }) {
                    Text("Choose an active store or turn on Any store.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct PurchaseRulesPreview: View {
    @Environment(\.persistenceSelection) private var selection
    @State private var ids: Set<UUID> = []
    @State private var anyStore = true
    var body: some View {
        NavigationStack { Form {
            PurchaseRulesPicker(storeIDs: $ids, anyStore: $anyStore,
                                householdID: selection.householdID, listID: selection.listID,
                                onAddStore: {})
        } }
    }
}

#Preview("Purchase rules") { ShoppingPreviewHost(.populated) { PurchaseRulesPreview() } }
#Preview("Add store") {
    let fixture = try! ShoppingPreviewFixtures.make(.populated)
    NavigationStack { StoreCreationView(householdID: fixture.ids.householdID, listID: fixture.ids.listID, onSelected: { _ in })
        .environment(\.managedObjectContext, fixture.persistence.container.viewContext)
        .environment(\.needService, fixture.service)
        .environment(\.persistenceSelection, fixture.selection) }
}
