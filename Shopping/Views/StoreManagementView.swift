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
    @Environment(\.homeEditorDraftStore) private var draftStore
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores:
        FetchedResults<Store>
    @FetchRequest(fetchRequest: PurchaseRulesStoreScope.listsRequest()) private var lists:
        FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households:
        FetchedResults<Household>
    @State private var editor: StoreEditorSession?
    @State private var editorName = ""
    @State private var isSaving = false
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
        Group {
            if editMode.isEditing {
                selectableList
            } else {
                standardList
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, $editMode)
        .navigationTitle(editMode.isEditing ? "\(selectedIDs.count) Selected" : "Stores")
        .toolbar {
            ShoppingCollectionToolbar(
                isSelecting: editMode.isEditing, allSelected: selectedIDs == Set(householdStores.map(\.id)),
                selectAvailable: selectionAvailable && !householdStores.isEmpty, addAvailable: selectionAvailable,
                addTitle: "Add store", identifierPrefix: "shopping.stores",
                select: { editMode = .active }, add: beginCreate, done: clearSelection,
                toggleAll: {
                    let visible = Set(householdStores.map(\.id))
                    selectedIDs = selectedIDs == visible ? [] : visible
                }
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editMode.isEditing {
                Divider()
                HStack(spacing: 4) {
                    Button("Delete", systemImage: "trash", role: .destructive) { prepareBatch(.delete) }
                        .tint(.red)
                        .disabled(selectedIDs.isEmpty)
                        .accessibilityIdentifier("shopping.stores.batchDelete")
                        .frame(maxWidth: .infinity, minHeight: ShoppingListMetrics.minimumRowHeight)
                        .confirmationDialog(
                            batchPreview.map(ManagementBatchCopy.title) ?? "Delete selected stores?",
                            isPresented: Binding(get: { batchPreview != nil }, set: { if !$0 { batchPreview = nil } }),
                            titleVisibility: .visible
                        ) {
                            if let preview = batchPreview {
                                Button("Delete", role: .destructive) { applyBatch(preview.token) }
                            }
                            Button("Cancel", role: .cancel) { batchPreview = nil }
                        } message: {
                            if let preview = batchPreview { Text(ManagementBatchCopy.message(preview)) }
                        }
                    Button("Archive", systemImage: "archivebox") { prepareBatch(.archive) }
                        .disabled(!selectedStores.contains(where: { !$0.isArchived }))
                        .accessibilityIdentifier("shopping.stores.batchArchive")
                        .frame(maxWidth: .infinity, minHeight: ShoppingListMetrics.minimumRowHeight)
                    Button("Restore", systemImage: "arrow.uturn.backward") { prepareBatch(.restore) }
                        .disabled(!selectedStores.contains(where: \.isArchived))
                        .accessibilityIdentifier("shopping.stores.batchRestore")
                        .frame(maxWidth: .infinity, minHeight: ShoppingListMetrics.minimumRowHeight)
                    Button("Edit", systemImage: "pencil", action: editSelectedStore)
                        .disabled(selectedStores.count != 1)
                        .accessibilityIdentifier("shopping.stores.batchEdit")
                        .frame(maxWidth: .infinity, minHeight: ShoppingListMetrics.minimumRowHeight)
                }
                .labelStyle(.iconOnly)
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
                busy: isSaving,
                onSave: { save(session) },
                onCancel: { editor = nil },
                draftIdentity: "store." + (session.store?.id.uuidString ?? "new")
            )
        }
        .alert("Store archived", isPresented: Binding(
            get: { removalNotice != nil }, set: { if !$0 { removalNotice = nil } }
        )) {
            Button("OK", role: .cancel) { removalNotice = nil }
        } message: {
            Text(removalNotice ?? "")
        }
        .alert(
            removalTitle,
            isPresented: Binding(
                get: { removingStore != nil },
                set: { if !$0 { clearRemoval() } }
            )
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
        .alert(
            "Couldn’t update stores",
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error?.localizedDescription ?? "Unknown error")
        }
        .alert("Batch update complete", isPresented: Binding(
            get: { batchNotice != nil }, set: { if !$0 { batchNotice = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(batchNotice ?? "") }
        .onChange(of: selection) { _, _ in clearSelection() }
        .onChange(of: householdStores.map(\.id)) { _, ids in
            selectedIDs.formIntersection(Set(ids))
        }
        .onDisappear(perform: clearSelection)
    }

    private var standardList: some View {
        List {
            storeSection(nil, stores: activeStores, canReorder: true)
            if !archivedStores.isEmpty { storeSection("Archived", stores: archivedStores) }
        }
    }

    private var selectableList: some View {
        List(selection: $selectedIDs) {
            storeSection(nil, stores: activeStores, canReorder: true)
            if !archivedStores.isEmpty { storeSection("Archived", stores: archivedStores) }
        }
    }

    private var selectedStores: [Store] { householdStores.filter { selectedIDs.contains($0.id) } }

    @ViewBuilder
    private func storeSection(
        _ title: String?,
        stores: [Store],
        canReorder: Bool = false
    ) -> some View {
        Section {
            if canReorder {
                ForEach(stores, id: \.objectID) { store in
                    storeListRow(store)
                }
                .onMove(perform: reorder)
            } else {
                ForEach(stores, id: \.objectID) { store in
                    storeListRow(store)
                }
            }
        } header: { if let title { Text(title) } }
    }

    @ViewBuilder
    private func storeListRow(_ store: Store) -> some View {
        if editMode.isEditing {
            storeRow(store)
                .shoppingListRowInsets()
                .tag(store.id)
        } else {
            storeRow(store)
                .shoppingListRowInsets()
        }
    }

    @ViewBuilder
    private func storeRow(_ store: Store) -> some View {
        if editMode.isEditing {
            storeRowActions(storeRowLabel(store), store: store)
        } else {
            storeRowActions(
                Button { beginRename(store) } label: {
                    storeRowLabel(store)
                        .frame(maxWidth: .infinity, minHeight: ShoppingListMetrics.minimumRowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain),
                store: store
            )
        }
    }

    private func storeRowActions<Content: View>(_ content: Content, store: Store) -> some View {
        content
        .frame(maxWidth: .infinity, alignment: .leading)
        .shoppingItemRow()
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { store.isArchived ? restore(store) : archive(store) } label: {
                Label(store.isArchived ? "Restore" : "Archive", systemImage: store.isArchived ? "arrow.uturn.backward" : "archivebox")
                    .labelStyle(.iconOnly)
            }
            .tint(store.isArchived ? .groceryAccent : .orange)
            .disabled(!selectionAvailable)
            .accessibilityIdentifier("shopping.stores.archive.\(store.id.uuidString)")
            Button(role: .destructive) { beginDeletion(store) } label: {
                Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
            }
            .tint(.red)
            .disabled(!selectionAvailable)
            .accessibilityIdentifier("shopping.stores.delete.\(store.id.uuidString)")
        }
        .contextMenu {
            if !editMode.isEditing {
                Button("Select", systemImage: "checkmark.circle") { beginSelection(with: store.id) }
                    .accessibilityIdentifier("shopping.stores.contextSelect.\(store.id.uuidString)")
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

    private func storeRowLabel(_ store: Store) -> some View {
        ShoppingManagementRowLabel(name: store.name, isArchived: store.isArchived)
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
        guard !isSaving, StoreManagementScope.permits(session.scope, canonicalList: canonicalList),
              let service else { return }
        let draftLease = draftStore?.currentLease(scope: selection.homeScope,
            editor: "store." + (session.store?.id.uuidString ?? "new"))
        isSaving = true
        let name = editorName, storeID = session.store?.id
        let householdID = session.scope.householdID, listID = session.scope.listID
        Task {
            defer { isSaving = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    if let storeID {
                        try service.renameStore(name: name, storeID: storeID,
                            householdID: householdID, listID: listID)
                    } else {
                        _ = try service.createStore(name: name,
                            householdID: householdID, listID: listID)
                    }
                }.value
                if let draftLease { draftStore?.finish(draftLease) }
                guard selection.householdID == householdID, selection.listID == listID else { return }
                hapticFeedback.play(.success)
                editor = nil
            } catch { self.error = error }
        }
    }

    private func reorder(from offsets: IndexSet, to destination: Int) {
        guard let service,
              let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        var ids = activeStores.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        let householdID = scope.householdID, listID = scope.listID
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try service.reorderStores(ids, householdID: householdID, listID: listID)
                }.value
            } catch { self.error = error }
        }
    }

    private var removalTitle: String {
        let name = removingStore?.name ?? "store"
        if requestedDeletion && removalAction == .archive { return "Can’t delete \(name)" }
        return removalAction == .archive ? "Archive \(name)?" : "Delete \(name)?"
    }

    private func archive(_ store: Store) {
        guard selectionAvailable, householdStores.contains(store), let service,
              let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        setArchived(true, storeID: store.id, scope: scope, service: service)
    }

    private func restore(_ store: Store) {
        guard let service, let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        setArchived(false, storeID: store.id, scope: scope, service: service)
    }

    private func setArchived(_ archived: Bool, storeID: UUID, scope: StoreManagementCommandScope,
                             service: NeedService) {
        let householdID = scope.householdID, listID = scope.listID
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try service.setStoreArchived(archived, storeID: storeID,
                        householdID: householdID, listID: listID)
                }.value
                hapticFeedback.play(.success)
            } catch { self.error = error }
        }
    }

    private func beginDeletion(_ store: Store) {
        guard selectionAvailable, householdStores.contains(store), let service,
              let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        let storeID = store.id, householdID = scope.householdID, listID = scope.listID
        requestedDeletion = true
        Task {
            do {
                let action = try await Task.detached(priority: .userInitiated) {
                    try service.storeRemovalAction(storeID: storeID,
                        householdID: householdID, listID: listID)
                }.value
                guard selection.householdID == householdID, selection.listID == listID else { return }
                removalAction = action
                removalScope = scope
                removingStore = store
            } catch { self.error = error }
        }
    }

    private func remove() {
        guard let store = removingStore, let scope = removalScope, let removalAction,
              StoreManagementScope.permits(scope, canonicalList: canonicalList), let service else { return }
        let storeID = store.id, storeName = store.name
        let householdID = scope.householdID, listID = scope.listID
        Task {
            do {
                let appliedAction = try await Task.detached(priority: .userInitiated) {
                    try service.removeStore(storeID: storeID, householdID: householdID,
                        listID: listID, confirmedAction: removalAction)
                }.value
                guard selection.householdID == householdID, selection.listID == listID else { return }
                hapticFeedback.play(.warning)
                clearRemoval()
                if removalAction == .delete, appliedAction == .archive {
                    removalNotice = "A saved item or grocery began using \(storeName), so it was archived instead of permanently deleted."
                }
            } catch { self.error = error }
        }
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
        let ids = selectedIDs, householdID = scope.householdID, listID = scope.listID
        Task {
            do {
                let preview = try await Task.detached(priority: .userInitiated) {
                    try service.captureManagementBatch(entity: .store, action: action,
                        ids: ids, householdID: householdID, listID: listID)
                }.value
                guard selection.householdID == householdID, selection.listID == listID else { return }
                if action == .delete { batchPreview = preview }
                else { applyBatch(preview.token) }
            } catch { self.error = error }
        }
    }

    private func applyBatch(_ token: ManagementBatchToken) {
        guard let service, selection.householdID == token.householdID, selection.listID == token.listID else {
            batchPreview = nil; clearSelection(); return
        }
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try service.applyManagementBatch(token)
                }.value
                guard selection.householdID == token.householdID, selection.listID == token.listID else { return }
                batchPreview = nil
                clearSelection()
                batchNotice = ManagementBatchCopy.result(result)
                hapticFeedback.play(token.action == .delete ? .warning : .success)
            } catch { batchPreview = nil; self.error = error }
        }
    }

    private func clearSelection() { selectedIDs = []; editMode = .inactive }

}
