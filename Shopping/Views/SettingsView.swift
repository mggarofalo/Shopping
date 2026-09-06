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

    static func activeStores(_ stores: [Store], canonicalList: GroceryList?) -> [Store] {
        validStores(stores, canonicalList: canonicalList).filter { !$0.isArchived }
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
    @Environment(\.hapticFeedback) private var hapticFeedback
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores:
        FetchedResults<Store>
    @FetchRequest(fetchRequest: PurchaseRulesStoreScope.listsRequest()) private var lists:
        FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households:
        FetchedResults<Household>
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var editor: StoreEditorSession?
    @State private var editorName = ""
    @State private var removingStore: Store?
    @State private var removalScope: StoreManagementCommandScope?
    @State private var removalAction: StoreRemovalAction?
    @State private var error: Error?

    private var canonicalList: GroceryList? {
        StoreManagementScope.canonicalList(
            lists: Array(lists), households: Array(households), selection: selection
        )
    }

    private var householdStores: [Store] {
        StoreManagementScope.activeStores(Array(stores), canonicalList: canonicalList)
    }

    private var selectionAvailable: Bool {
        service != nil && canonicalList != nil
    }

    var body: some View {
        List {
            Section("Stores") {
                ForEach(householdStores, id: \.objectID) { store in
                    storeRow(store)
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 8))
                }
                .onMove(perform: reorder)
            }
        }
        .navigationTitle("Stores")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { beginCreate() } label: { Label("Add store", systemImage: "plus") }
                    .disabled(!selectionAvailable)
                    .accessibilityIdentifier("shopping.stores.add")
            }
            ToolbarItem(placement: .secondaryAction) {
                EditButton().disabled(!selectionAvailable)
            }
        }
        .sheet(item: $editor) { session in
            StoreEditorView(
                title: session.store == nil ? "Add store" : "Rename store",
                name: $editorName,
                available: StoreManagementScope.permits(session.scope, canonicalList: canonicalList),
                onSave: { save(session) },
                onCancel: { editor = nil }
            )
        }
        .confirmationDialog(
            removalAction == .archive ? "Archive \(removingStore?.name ?? "store")?" :
                "Delete \(removingStore?.name ?? "store")?",
            isPresented: Binding(get: { removingStore != nil }, set: { if !$0 { clearRemoval() } }),
            titleVisibility: .visible
        ) {
            if removalAction == .archive {
                Button("Archive store", role: .destructive, action: remove)
            } else {
                Button("Delete store", role: .destructive, action: remove)
            }
            Button("Cancel", role: .cancel, action: clearRemoval)
        } message: {
            if removalAction == .archive {
                Text("Catalog items or one-time groceries still use this store. Archiving keeps their purchase tags recoverable and hides the store from active choices.")
            } else {
                Text("This store has no catalog or one-time grocery references and will be removed.")
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

    @ViewBuilder
    private func storeRow(_ store: Store) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            Text(store.name)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            HStack(spacing: 0) {
                Button { beginRename(store) } label: {
                    Image(systemName: "pencil").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Rename \(store.name)")
                .buttonStyle(.borderless)
                .disabled(!selectionAvailable)
                Button { beginRemoval(store) } label: {
                    Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Delete \(store.name)")
                .buttonStyle(.borderless)
                .disabled(!selectionAvailable)
            }
        }
        .frame(minHeight: 44)
    }

    private func beginCreate() {
        guard let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        editorName = ""
        editor = StoreEditorSession(store: nil, scope: scope)
    }

    private func beginRename(_ store: Store) {
        guard selectionAvailable, householdStores.contains(store),
              let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        editorName = store.name
        error = nil
        editor = StoreEditorSession(store: store, scope: scope)
    }

    private func save(_ session: StoreEditorSession) {
        guard StoreManagementScope.permits(session.scope, canonicalList: canonicalList), let service else { return }
        do {
            if let store = session.store {
                try service.renameStore(
                    name: editorName, storeID: store.id, householdID: session.scope.householdID,
                    listID: session.scope.listID)
            } else {
                _ = try service.createStore(
                    name: editorName, householdID: session.scope.householdID, listID: session.scope.listID)
            }
            hapticFeedback.play(.success)
            editor = nil
        } catch { self.error = error }
    }

    private func beginRemoval(_ store: Store) {
        guard selectionAvailable, householdStores.contains(store), let service,
              let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        do {
            removalAction = try service.storeRemovalAction(
                storeID: store.id, householdID: scope.householdID, listID: scope.listID
            )
            removalScope = scope
            removingStore = store
        } catch { self.error = error }
    }

    private func remove() {
        guard let store = removingStore, let scope = removalScope,
              StoreManagementScope.permits(scope, canonicalList: canonicalList), let service else { return }
        do {
            _ = try service.removeStore(
                storeID: store.id, householdID: scope.householdID, listID: scope.listID
            )
            hapticFeedback.play(.warning)
            clearRemoval()
        } catch { self.error = error }
    }

    private func clearRemoval() {
        removingStore = nil
        removalScope = nil
        removalAction = nil
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

private struct StoreEditorSession: Identifiable {
    let id = UUID()
    let store: Store?
    let scope: StoreManagementCommandScope
}

private struct StoreEditorView: View {
    let title: String
    @Binding var name: String
    @FocusState private var nameFocused: Bool
    let available: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    private var canSave: Bool {
        available && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Store name", text: $name)
                    .accessibilityIdentifier("shopping.stores.name")
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { if canSave { onSave() } }
                if !available {
                    Text("This household is unavailable. Your draft is still here.")
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear { nameFocused = true }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onSave) { Image(systemName: "checkmark") }
                        .accessibilityLabel("Save store")
                        .disabled(!canSave)
                }
            }
        }
    }
}

#Preview("Store settings · archived") { ShoppingPreviewHost(.archivedStore) { SettingsView() } }
#Preview("Store settings · empty") { ShoppingPreviewHost(.empty) { SettingsView() } }
#Preview("Store management · archived") {
    ShoppingPreviewHost(.archivedStore) { NavigationStack { StoreManagementView() } }
}
