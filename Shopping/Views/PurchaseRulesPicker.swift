import CoreData
import SwiftUI

enum PurchaseRulesStoreScope {
    static func listsRequest() -> NSFetchRequest<GroceryList> {
        let request = GroceryList.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
        return request
    }

    static func validStores(
        _ stores: [Store],
        lists: [GroceryList],
        householdID: UUID?,
        listID: UUID?
    ) -> [Store] {
        guard let householdID, let listID,
              householdID != PersistenceModel.unsetID, listID != PersistenceModel.unsetID else { return [] }
        let matchingLists = lists.filter { $0.id == listID }
        guard matchingLists.count == 1, let household = matchingLists[0].household,
              household.id == householdID,
              let persistentStore = household.objectID.persistentStore,
              matchingLists[0].objectID.persistentStore == persistentStore else { return [] }
        let counts = Dictionary(grouping: stores, by: \.id).mapValues(\.count)
        return stores.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 &&
                $0.household == household && $0.objectID.persistentStore == persistentStore
        }
    }
}

struct PurchaseRulesPicker: View {
    @Environment(\.persistenceSelection) private var selection
    @Binding var storeIDs: Set<UUID>
    @Binding var anyStore: Bool
    let householdID: UUID?
    let listID: UUID?
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: PurchaseRulesStoreScope.listsRequest()) private var lists: FetchedResults<GroceryList>

    private var scopedListID: UUID? {
        listID ?? (selection.householdID == householdID ? selection.listID : nil)
    }

    private var validStores: [Store] {
        PurchaseRulesStoreScope.validStores(
            Array(stores), lists: Array(lists), householdID: householdID, listID: scopedListID
        )
    }

    var body: some View {
        Section("Where to buy") {
            Toggle("Any store", isOn: $anyStore)
            if anyStore {
                Text("Can buy at any store, even when tagged.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(validStores.filter { !$0.isArchived || storeIDs.contains($0.id) }, id: \.objectID) { store in
                Toggle(isOn: Binding(
                    get: { storeIDs.contains(store.id) },
                    set: { selected in
                        if selected { storeIDs.insert(store.id) } else { storeIDs.remove(store.id) }
                    }
                )) {
                    VStack(alignment: .leading) {
                        Text(store.name)
                        if store.isArchived { Text("Archived").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            let unavailable = storeIDs.subtracting(Set(validStores.map(\.id)))
            if !unavailable.isEmpty {
                Text("Remove unavailable tags, then choose where to buy.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Remove unavailable tags") { storeIDs.subtract(unavailable) }
            }
            if !anyStore && storeIDs.isEmpty {
                Text("Choose a store or turn on Any store.").font(.footnote).foregroundStyle(.secondary)
            }
            if !anyStore && !storeIDs.isEmpty &&
                !validStores.contains(where: { !$0.isArchived && storeIDs.contains($0.id) }) {
                Text("Choose an active store or turn on Any store.").font(.footnote).foregroundStyle(.secondary)
            }
            NavigationLink {
                StoreCreationView(householdID: householdID, listID: listID) { id in
                    storeIDs.insert(id)
                }
            } label: { Label("Add store", systemImage: "plus") }
                .accessibilityIdentifier("shopping.tags.addStore")
                .disabled(householdID == nil)
        }

    }
}

private struct StoreCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: PurchaseRulesStoreScope.listsRequest()) private var lists: FetchedResults<GroceryList>
    @State private var name = ""
    @State private var error: Error?
    let householdID: UUID?
    let listID: UUID?
    let onSelected: (UUID) -> Void

    private var scopeAvailable: Bool {
        householdID != nil && selection.householdID == householdID &&
            (listID == nil || selection.listID == listID) && service != nil
    }

    private var matches: [Store] {
        let query = CatalogProjection.normalizedName(name)
        guard !query.isEmpty else { return [] }
        return PurchaseRulesStoreScope.validStores(
            Array(stores), lists: Array(lists), householdID: householdID,
            listID: listID ?? (selection.householdID == householdID ? selection.listID : nil)
        ).filter { CatalogProjection.normalizedName($0.name).contains(query) }
    }

    var body: some View {
        Form {
                TextField("Store name", text: $name)
                    .accessibilityIdentifier("shopping.tags.storeName")
                if !matches.isEmpty {
                    Section("Existing stores") {
                        ForEach(matches, id: \.objectID) { store in
                            Button(store.isArchived ? "Restore and use \(store.name)" : "Use \(store.name)") {
                                select(store)
                            }
                            .disabled(!scopeAvailable)
                        }
                    }
                }
                Text("Save store adds it to your household. The grocery is saved separately when you tap Add.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !scopeAvailable { Text("This household is unavailable. Your store draft is still here.") }
                if let error { Text(error.localizedDescription).foregroundStyle(.red) }
            }
            .navigationTitle("Add store")
            .navigationBarBackButtonHidden()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save store", action: save)
                        .disabled(!scopeAvailable || CatalogProjection.normalizedName(name).isEmpty)
                }
            }
    }

    private func select(_ store: Store) {
        guard scopeAvailable, let service, let householdID else { return }
        do {
            if store.isArchived {
                try service.setStoreArchived(false, storeID: store.id, householdID: householdID)
            }
            onSelected(store.id)
            dismiss()
        } catch { self.error = error }
    }

    private func save() {
        guard scopeAvailable, let service, let householdID else { return }
        do {
            onSelected(try service.createStore(name: name, householdID: householdID))
            dismiss()
        } catch { self.error = error }
    }
}

private struct PurchaseRulesPreview: View {
    @Environment(\.persistenceSelection) private var selection
    @State private var ids: Set<UUID> = []
    @State private var anyStore = true
    var body: some View {
        NavigationStack { Form {
            PurchaseRulesPicker(storeIDs: $ids, anyStore: $anyStore,
                                householdID: selection.householdID, listID: selection.listID)
        } }
    }
}

#Preview("Purchase tags") { ShoppingPreviewHost(.populated) { PurchaseRulesPreview() } }
#Preview("Add store") {
    let fixture = try! ShoppingPreviewFixtures.make(.populated)
    NavigationStack { StoreCreationView(householdID: fixture.ids.householdID, listID: fixture.ids.listID, onSelected: { _ in })
        .environment(\.managedObjectContext, fixture.persistence.container.viewContext)
        .environment(\.needService, fixture.service)
        .environment(\.persistenceSelection, fixture.selection) }
}
