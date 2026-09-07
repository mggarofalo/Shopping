import CoreData
import SwiftUI

enum ShoppingListMetrics {
    static let rowInsets = EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 8)
}

extension View {
    func shoppingListRowInsets() -> some View {
        listRowInsets(ShoppingListMetrics.rowInsets)
    }
}

struct SettingsView: View {
    @AppStorage("shopping.appearance") private var appearance = AppearancePreference.system.rawValue
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            List {
                NavigationLink { StoreManagementView() } label: { Label("Stores", systemImage: "storefront") }
                    .shoppingListRowInsets()
                NavigationLink { CategoryManagementView() } label: { Label("Categories", systemImage: "square.grid.2x2") }
                    .shoppingListRowInsets()
                Section("Appearance") {
                    if dynamicTypeSize.isAccessibilitySize {
                        appearancePicker.pickerStyle(.menu).shoppingListRowInsets()
                    } else {
                        appearancePicker.pickerStyle(.segmented).shoppingListRowInsets()
                    }
                }
                Section("Household") {
                    LabeledContent("Sharing status", value: "Not connected")
                        .shoppingListRowInsets()
                    Text("Groceries are available in this app’s current local household store.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .shoppingListRowInsets()
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
                        .shoppingListRowInsets()
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
            ManagementNameEditor(
                title: session.store == nil ? "Add store" : "Rename store",
                name: $editorName,
                fieldTitle: "Store name",
                fieldIdentifier: "shopping.stores.name",
                saveLabel: "Save store",
                unavailableMessage: session.store == nil
                    ? "This household is unavailable. Your draft is still here."
                    : "This store is no longer available. Your draft is still here.",
                available: StoreManagementScope.permits(session.scope, canonicalList: canonicalList)
                    && (session.store.map(householdStores.contains) ?? true),
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
        Text(store.name)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { beginRename(store) } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.blue)
                .disabled(!selectionAvailable)
                .accessibilityIdentifier("shopping.stores.edit.\(store.id.uuidString)")
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button(role: .destructive) { beginRemoval(store) } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!selectionAvailable)
                .accessibilityIdentifier("shopping.stores.delete.\(store.id.uuidString)")
            }
            .accessibilityAction(named: Text("Edit \(store.name)")) { beginRename(store) }
            .accessibilityAction(named: Text("Delete \(store.name)")) { beginRemoval(store) }
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
        guard let store = removingStore, let scope = removalScope, let removalAction,
              StoreManagementScope.permits(scope, canonicalList: canonicalList), let service else { return }
        do {
            _ = try service.removeStore(
                storeID: store.id, householdID: scope.householdID, listID: scope.listID,
                confirmedAction: removalAction
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

struct ManagementNameEditor: View {
    let title: String
    @Binding var name: String
    let fieldTitle: String
    let fieldIdentifier: String
    let saveLabel: String
    let unavailableMessage: String
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
                TextField(fieldTitle, text: $name)
                    .accessibilityIdentifier(fieldIdentifier)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { if canSave { onSave() } }
                if !available {
                    Text(unavailableMessage)
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear { nameFocused = true }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onSave) { Image(systemName: "checkmark") }
                        .accessibilityLabel(saveLabel)
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
