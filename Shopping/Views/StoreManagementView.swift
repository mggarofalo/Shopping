import CoreData
import SwiftUI

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

struct StoreManagementView: View {
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
    @State private var requestedDeletion = false
    @State private var removalNotice: String?
    @State private var error: Error?
    @State private var selectedIDs: Set<UUID> = []
    @State private var editMode: EditMode = .inactive
    @State private var batchPreview: ManagementBatchPreview?
    @State private var batchNotice: String?

    private var canonicalList: GroceryList? {
        StoreManagementScope.canonicalList(
            lists: Array(lists), households: Array(households), selection: selection
        )
    }

    private var householdStores: [Store] { StoreManagementScope.validStores(Array(stores), canonicalList: canonicalList) }
    private var activeStores: [Store] { householdStores.filter { !$0.isArchived } }
    private var archivedStores: [Store] { householdStores.filter(\.isArchived) }

    private var selectionAvailable: Bool {
        service != nil && canonicalList != nil
    }

    var body: some View {
        List(selection: $selectedIDs) {
            storeSection("Stores", stores: activeStores)
            if !archivedStores.isEmpty { storeSection("Archived", stores: archivedStores) }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .navigationTitle(editMode.isEditing ? "\(selectedIDs.count) Selected" : "Stores")
        .toolbar {
            if editMode.isEditing {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: clearSelection) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selectedIDs == Set(householdStores.map(\.id)) ? "Deselect All" : "Select All") {
                        toggleAll()
                    }
                    .accessibilityIdentifier("shopping.stores.selectAll")
                }
            } else {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Select") { editMode = .active }
                        .disabled(!selectionAvailable || householdStores.isEmpty)
                        .accessibilityIdentifier("shopping.stores.select")
                    Button { beginCreate() } label: { Label("Add store", systemImage: "plus") }
                        .disabled(!selectionAvailable)
                        .accessibilityIdentifier("shopping.stores.add")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editMode.isEditing {
                Divider()
                HStack(spacing: 4) {
                    Button("Edit", systemImage: "pencil", action: editSelectedStore)
                        .disabled(selectedStores.count != 1)
                        .accessibilityIdentifier("shopping.stores.batchEdit")
                        .frame(maxWidth: .infinity, minHeight: 44)
                    Button("Archive", systemImage: "archivebox") { prepareBatch(.archive) }
                        .disabled(!selectedStores.contains(where: { !$0.isArchived }))
                        .accessibilityIdentifier("shopping.stores.batchArchive")
                        .frame(maxWidth: .infinity, minHeight: 44)
                    Button("Restore", systemImage: "arrow.uturn.backward") { prepareBatch(.restore) }
                        .disabled(!selectedStores.contains(where: \.isArchived))
                        .accessibilityIdentifier("shopping.stores.batchRestore")
                        .frame(maxWidth: .infinity, minHeight: 44)
                    Button("Delete", systemImage: "trash", role: .destructive) { prepareBatch(.delete) }
                        .tint(.red)
                        .disabled(selectedIDs.isEmpty)
                        .accessibilityIdentifier("shopping.stores.batchDelete")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.bar)
            }
        }
        .sheet(item: $editor) { session in
            ManagementNameEditor(
                title: session.store == nil ? "Add store" : "Rename store",
                name: $editorName,
                fieldTitle: "Store name",
                fieldIdentifier: "shopping.stores.name",
                saveLabel: "Save store",
                initiallyFocused: session.store == nil,
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
            removalTitle,
            isPresented: Binding(get: { removingStore != nil }, set: { if !$0 { clearRemoval() } }),
            titleVisibility: .visible
        ) {
            if removalAction == .archive {
                Button("Archive store", action: remove)
            } else {
                Button("Delete store", role: .destructive, action: remove)
            }
            Button("Cancel", role: .cancel, action: clearRemoval)
        } message: {
            if requestedDeletion && removalAction == .archive {
                Text("This store is still used by saved items or groceries, so it cannot be permanently deleted. You can archive it instead and keep those purchase rules recoverable.")
            } else if removalAction == .archive {
                Text("Archiving hides this store from active choices and preserves saved purchase rules for recovery.")
            } else {
                Text("This store has no catalog or one-time grocery references and will be removed.")
            }
        }
        .alert("Store archived", isPresented: Binding(
            get: { removalNotice != nil }, set: { if !$0 { removalNotice = nil } }
        )) {
            Button("OK", role: .cancel) { removalNotice = nil }
        } message: {
            Text(removalNotice ?? "")
        }
        .alert(
            "Couldn’t update stores",
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error?.localizedDescription ?? "Unknown error")
        }
        .confirmationDialog(
            batchPreview.map(ManagementBatchCopy.title) ?? "Update selected stores?",
            isPresented: Binding(get: { batchPreview != nil }, set: { if !$0 { batchPreview = nil } }),
            titleVisibility: .visible
        ) {
            if let preview = batchPreview {
                Button(batchActionLabel(preview.token.action), role: preview.token.action == .delete ? .destructive : nil) {
                    applyBatch(preview.token)
                }
            }
            Button("Cancel", role: .cancel) { batchPreview = nil }
        } message: { if let preview = batchPreview { Text(ManagementBatchCopy.message(preview)) } }
        .alert("Batch update complete", isPresented: Binding(
            get: { batchNotice != nil }, set: { if !$0 { batchNotice = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(batchNotice ?? "") }
        .onChange(of: selection) { _, _ in clearSelection() }
        .onChange(of: householdStores.map(\.id)) { _, ids in
            selectedIDs.formIntersection(Set(ids))
        }
        .onDisappear(perform: clearSelection)
    }

    private var selectedStores: [Store] { householdStores.filter { selectedIDs.contains($0.id) } }

    @ViewBuilder
    private func storeSection(_ title: String, stores: [Store]) -> some View {
        Section(title) {
            ForEach(stores, id: \.objectID) { store in
                storeRow(store)
                    .shoppingListRowInsets()
                    .tag(store.id)
            }
        }
    }

    @ViewBuilder
    private func storeRow(_ store: Store) -> some View {
        HStack {
            Text(store.name)
            Spacer()
            if store.isArchived { Text("Archived").font(.caption).foregroundStyle(.secondary) }
        }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { beginRename(store) } label: {
                    Label("Edit", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                }
                .tint(.blue)
                .disabled(!selectionAvailable)
                .accessibilityIdentifier("shopping.stores.edit.\(store.id.uuidString)")
                Button { store.isArchived ? restore(store) : archive(store) } label: {
                    Label(store.isArchived ? "Restore" : "Archive", systemImage: store.isArchived ? "arrow.uturn.backward" : "archivebox")
                        .labelStyle(.iconOnly)
                }
                .tint(store.isArchived ? .green : .orange)
                .disabled(!selectionAvailable)
                .accessibilityIdentifier("shopping.stores.archive.\(store.id.uuidString)")
                Button(role: .destructive) { beginDeletion(store) } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .tint(.red)
                .disabled(!selectionAvailable)
                .accessibilityIdentifier("shopping.stores.delete.\(store.id.uuidString)")
            }
            .contextMenu {
                if !editMode.isEditing {
                    Button("Select", systemImage: "checkmark.circle") { beginSelection(with: store.id) }
                        .accessibilityIdentifier("shopping.stores.contextSelect.\(store.id.uuidString)")
                    Button("Edit", systemImage: "pencil") { beginRename(store) }
                    Button(store.isArchived ? "Restore" : "Archive",
                           systemImage: store.isArchived ? "arrow.uturn.backward" : "archivebox") {
                        if store.isArchived { restore(store) } else { archive(store) }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { beginDeletion(store) }
                }
            }
            .accessibilityAction(named: Text("Edit \(store.name)")) { beginRename(store) }
            .accessibilityAction(named: Text("\(store.isArchived ? "Restore" : "Archive") \(store.name)")) {
                if store.isArchived { restore(store) } else { archive(store) }
            }
            .accessibilityAction(named: Text("Delete \(store.name)")) { beginDeletion(store) }
    }

    private func beginCreate() {
        guard let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        editorName = ""
        editor = StoreEditorSession(store: nil, scope: scope)
    }

    private func beginSelection(with storeID: UUID) {
        guard !editMode.isEditing, selectionAvailable,
              householdStores.contains(where: { $0.id == storeID }) else { return }
        selectedIDs = [storeID]
        editMode = .active
    }

    private func editSelectedStore() {
        guard selectedStores.count == 1, let store = selectedStores.first else { return }
        clearSelection()
        beginRename(store)
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

    private var removalTitle: String {
        let name = removingStore?.name ?? "store"
        if requestedDeletion && removalAction == .archive { return "Can’t delete \(name)" }
        return removalAction == .archive ? "Archive \(name)?" : "Delete \(name)?"
    }

    private func archive(_ store: Store) {
        guard selectionAvailable, householdStores.contains(store), let service,
              let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        do {
            try service.setStoreArchived(
                true, storeID: store.id, householdID: scope.householdID, listID: scope.listID
            )
            hapticFeedback.play(.success)
        } catch { self.error = error }
    }

    private func restore(_ store: Store) {
        guard let service, let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        do {
            try service.setStoreArchived(false, storeID: store.id, householdID: scope.householdID, listID: scope.listID)
            hapticFeedback.play(.success)
        } catch { self.error = error }
    }

    private func beginDeletion(_ store: Store) {
        guard selectionAvailable, householdStores.contains(store), let service,
              let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        do {
            requestedDeletion = true
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
            let appliedAction = try service.removeStore(
                storeID: store.id, householdID: scope.householdID, listID: scope.listID,
                confirmedAction: removalAction
            )
            hapticFeedback.play(.warning)
            clearRemoval()
            if removalAction == .delete, appliedAction == .archive {
                removalNotice = "A saved item or grocery began using \(store.name), so it was archived instead of permanently deleted."
            }
        } catch { self.error = error }
    }

    private func clearRemoval() {
        removingStore = nil
        removalScope = nil
        removalAction = nil
        requestedDeletion = false
    }
    private func toggleAll() {
        let visible = Set(householdStores.map(\.id))
        selectedIDs = selectedIDs == visible ? [] : visible
    }

    private func prepareBatch(_ action: ManagementBatchAction) {
        guard let service, let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        do {
            let preview = try service.captureManagementBatch(
                entity: .store, action: action, ids: selectedIDs,
                householdID: scope.householdID, listID: scope.listID
            )
            if action == .delete {
                batchPreview = preview
            } else {
                applyBatch(preview.token)
            }
        } catch { self.error = error }
    }

    private func applyBatch(_ token: ManagementBatchToken) {
        guard let service, selection.householdID == token.householdID, selection.listID == token.listID else {
            batchPreview = nil; clearSelection(); return
        }
        do {
            let result = try service.applyManagementBatch(token)
            batchPreview = nil
            clearSelection()
            batchNotice = ManagementBatchCopy.result(result)
            hapticFeedback.play(token.action == .delete ? .warning : .success)
        } catch { batchPreview = nil; self.error = error }
    }

    private func clearSelection() { selectedIDs = []; editMode = .inactive }

    private func batchActionLabel(_ action: ManagementBatchAction) -> String {
        switch action { case .archive: "Archive"; case .restore: "Restore"; case .delete: "Delete" }
    }
}
