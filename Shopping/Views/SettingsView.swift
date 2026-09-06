import CoreData
import SwiftUI

struct SettingsView: View {
    @AppStorage("shopping.appearance") private var appearance = AppearancePreference.system.rawValue
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            List {
                NavigationLink { StoreManagementView() } label: { Label("Stores", systemImage: "storefront") }
                NavigationLink { CategoryManagementView() } label: { Label("Categories", systemImage: "square.grid.2x2") }
                Section("Appearance") {
                    if dynamicTypeSize.isAccessibilitySize {
                        appearancePicker.pickerStyle(.menu)
                    } else {
                        appearancePicker.pickerStyle(.segmented)
                    }
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
    private var appearancePicker: some View {
        Picker("Color scheme", selection: $appearance) {
            ForEach(AppearancePreference.allCases) { preference in
                Text(preference.title).tag(preference.rawValue)
            }
        }
        .accessibilityIdentifier("shopping.appearance")
    }

}

struct StoreManagementCommandScope: Equatable {
    let householdID: UUID
    let listID: UUID
    let householdObjectID: NSManagedObjectID
    let listObjectID: NSManagedObjectID

    init?(canonicalList: GroceryList?) {
        guard let canonicalList, let household = canonicalList.household else { return nil }
        householdID = household.id
        listID = canonicalList.id
        householdObjectID = household.objectID
        listObjectID = canonicalList.objectID
    }

    func matches(canonicalList: GroceryList?) -> Bool {
        guard let canonicalList, let household = canonicalList.household else { return false }
        return canonicalList.id == listID && household.id == householdID
            && canonicalList.objectID == listObjectID && household.objectID == householdObjectID
            && canonicalList.objectID.persistentStore == household.objectID.persistentStore
    }
}

enum StoreManagementScope {
    static func canonicalList(
        lists: [GroceryList],
        households: [Household],
        selection: PersistenceSelection
    ) -> GroceryList? {
        GroceryRowScope.canonicalList(lists, households: households, selection: selection)
    }

    static func validStores(_ stores: [Store], canonicalList: GroceryList?) -> [Store] {
        GroceryRowScope.validStores(stores, canonicalList: canonicalList)
    }

    static func permits(
        _ commandScope: StoreManagementCommandScope?,
        canonicalList: GroceryList?
    ) -> Bool {
        commandScope?.matches(canonicalList: canonicalList) == true
    }
}

private struct StoreManagementView: View {
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores:
        FetchedResults<Store>
    @FetchRequest(fetchRequest: PurchaseRulesStoreScope.listsRequest()) private var lists:
        FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households:
        FetchedResults<Household>
    @State private var draftName = ""
    @State private var createScope: StoreManagementCommandScope?
    @State private var renameName = ""
    @State private var editingStore: Store?
    @State private var renameScope: StoreManagementCommandScope?
    @State private var error: Error?

    private var canonicalList: GroceryList? {
        StoreManagementScope.canonicalList(
            lists: Array(lists), households: Array(households), selection: selection
        )
    }

    private var householdStores: [Store] {
        StoreManagementScope.validStores(Array(stores), canonicalList: canonicalList)
    }

    private var selectionAvailable: Bool {
        service != nil && canonicalList != nil
    }

    private var createAvailable: Bool {
        selectionAvailable
            && StoreManagementScope.permits(createScope, canonicalList: canonicalList)
    }

    private var renameAvailable: Bool {
        selectionAvailable
            && StoreManagementScope.permits(renameScope, canonicalList: canonicalList)
            && editingStore.map { householdStores.contains($0) } == true
    }

    var body: some View {
        List {
            Section("Add store") {
                TextField("Store name", text: $draftName).accessibilityIdentifier(
                    "shopping.stores.createName")
                Button { create() } label: { Label("Save store", systemImage: "checkmark") }
                    .disabled(
                        draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !createAvailable)
                if !selectionAvailable || (!draftName.isEmpty && !createAvailable) {
                    Text("This household is unavailable. Your draft is still here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !draftName.isEmpty {
                    let matches = householdStores.filter {
                        $0.name.localizedCaseInsensitiveCompare(
                            draftName.trimmingCharacters(in: .whitespacesAndNewlines))
                            == .orderedSame
                    }
                    if !matches.isEmpty {
                        Text("Existing match").font(.footnote).foregroundStyle(.secondary)
                        ForEach(matches, id: \.objectID) { store in
                            Button("Use \(store.name)") { beginRename(store) }
                        }
                    }
                }
            }
            Section("Stores") {
                ForEach(householdStores, id: \.objectID) { store in
                    HStack {
                        Text(store.name)
                        Spacer()
                        if store.isArchived { Text("Archived").foregroundStyle(.secondary) }
                        Button { beginRename(store) } label: { Image(systemName: "pencil").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("Rename \(store.name)").buttonStyle(.borderless)
                            .disabled(!selectionAvailable)
                        Button { archive(store) } label: { Image(systemName: store.isArchived ? "arrow.uturn.backward" : "archivebox").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("\(store.isArchived ? "Restore" : "Archive") \(store.name)")
                            .buttonStyle(.borderless)
                            .disabled(!selectionAvailable)
                    }
                }
                .onMove(perform: reorder)
            }
        }
        .navigationTitle("Stores")
        .toolbar { EditButton().disabled(!selectionAvailable) }
        .onChange(of: draftName) { oldValue, newValue in
            if newValue.isEmpty {
                createScope = nil
            } else if oldValue.isEmpty {
                createScope = StoreManagementCommandScope(canonicalList: canonicalList)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { editingStore != nil },
                set: {
                    if !$0 {
                        editingStore = nil
                        renameScope = nil
                    }
                })
        ) {
            if let store = editingStore {
                NavigationStack {
                    Form {
                        TextField("Store name", text: $renameName)
                            .accessibilityIdentifier("shopping.stores.renameName")
                        if !renameAvailable {
                            Text("This household is unavailable. Your draft is still here.")
                                .foregroundStyle(.secondary)
                        }
                        if let error { Text(error.localizedDescription).foregroundStyle(.red) }
                    }
                    .navigationTitle("Rename store")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                editingStore = nil
                                renameScope = nil
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button { rename(store) } label: { Label("Save", systemImage: "checkmark") }
                                .disabled(
                                    renameName.trimmingCharacters(in: .whitespacesAndNewlines)
                                        .isEmpty || !renameAvailable)
                        }
                    }
                }
            }
        }
        .alert(
            "Couldn’t update stores",
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error?.localizedDescription ?? "Unknown error")
        }
    }

    private func create() {
        guard createAvailable, let service, let createScope else { return }
        do {
            _ = try service.createStore(
                name: draftName, householdID: createScope.householdID, listID: createScope.listID)
            draftName = ""
            self.createScope = nil
        } catch { self.error = error }
    }
    private func archive(_ store: Store) {
        guard selectionAvailable, householdStores.contains(store), let service, let canonicalList,
            let householdID = canonicalList.household?.id
        else { return }
        do {
            try service.setStoreArchived(
                !store.isArchived, storeID: store.id, householdID: householdID,
                listID: canonicalList.id)
        } catch { self.error = error }
    }
    private func beginRename(_ store: Store) {
        guard selectionAvailable, householdStores.contains(store) else { return }
        renameName = store.name
        renameScope = StoreManagementCommandScope(canonicalList: canonicalList)
        error = nil
        editingStore = store
    }
    private func rename(_ store: Store) {
        guard renameAvailable, let service, let renameScope else { return }
        do {
            try service.renameStore(
                name: renameName, storeID: store.id, householdID: renameScope.householdID,
                listID: renameScope.listID)
            editingStore = nil
            self.renameScope = nil
        } catch { self.error = error }
    }
    private func reorder(from offsets: IndexSet, to destination: Int) {
        guard selectionAvailable, let service, let canonicalList,
            let householdID = canonicalList.household?.id
        else {
            return
        }
        var ids = householdStores.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        do {
            try service.reorderStores(ids, householdID: householdID, listID: canonicalList.id)
        } catch { self.error = error }
    }
}

#Preview("Store settings · archived") { ShoppingPreviewHost(.archivedStore) { SettingsView() } }
#Preview("Store settings · empty") { ShoppingPreviewHost(.empty) { SettingsView() } }
#Preview("Store management · archived") {
    ShoppingPreviewHost(.archivedStore) { NavigationStack { StoreManagementView() } }
}
