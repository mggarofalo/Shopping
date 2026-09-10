import SwiftUI

enum CategoryManagementScope {
    static func household(
        lists: [GroceryList],
        households: [Household],
        householdID: UUID?,
        listID: UUID?
    ) -> Household? {
        GroceryRowScope.canonicalList(
            lists, households: households,
            selection: PersistenceSelection(householdID: householdID, listID: listID)
        )?.household
    }

    static func validCategories(
        _ categories: [Category],
        lists: [GroceryList],
        households: [Household],
        householdID: UUID?,
        listID: UUID?
    ) -> [Category] {
        guard let household = Self.household(
            lists: lists, households: households,
            householdID: householdID, listID: listID
        ),
              let persistentStore = household.objectID.persistentStore else { return [] }
        let counts = Dictionary(grouping: categories, by: \.id).mapValues(\.count)
        return categories.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 &&
                $0.household == household && $0.objectID.persistentStore == persistentStore
        }
    }
}

struct CategoryManagementView: View {
    @Environment(\.needService) private var service
    @Environment(\.hapticFeedback) private var hapticFeedback
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories: FetchedResults<Category>
    @FetchRequest(fetchRequest: PurchaseRulesStoreScope.listsRequest()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @State private var editor: CategoryEditorSession?
    @State private var editorName = ""
    @State private var removingCategory: Category?
    @State private var error: Error?
    @State private var selectedIDs: Set<UUID> = []
    @State private var editMode: EditMode = .inactive
    @State private var batchPreview: ManagementBatchPreview?
    @State private var batchNotice: String?

    private var canonicalList: GroceryList? {
        GroceryRowScope.canonicalList(
            Array(lists), households: Array(households), selection: selection
        )
    }

    private var householdCategories: [Category] {
        CategoryManagementScope.validCategories(
            Array(categories), lists: Array(lists), households: Array(households),
            householdID: selection.householdID, listID: selection.listID
        )
    }
    private var activeCategories: [Category] { householdCategories.filter { !$0.isArchived } }
    private var archivedCategories: [Category] { householdCategories.filter(\.isArchived) }

    private var selectionAvailable: Bool {
        service != nil && CategoryManagementScope.household(
            lists: Array(lists), households: Array(households),
            householdID: selection.householdID, listID: selection.listID
        ) != nil
    }

    var body: some View {
        Group {
            if editMode.isEditing {
                selectableList
            } else {
                standardList
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .navigationTitle(editMode.isEditing ? "\(selectedIDs.count) Selected" : "Categories")
        .toolbar {
            if editMode.isEditing {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: clearSelection) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selectedIDs == Set(householdCategories.map(\.id)) ? "Deselect All" : "Select All") {
                        let visible = Set(householdCategories.map(\.id))
                        selectedIDs = selectedIDs == visible ? [] : visible
                    }
                    .accessibilityIdentifier("shopping.categories.selectAll")
                }
            } else {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { editMode = .active } label: {
                        Label("Select", systemImage: "checkmark.circle").labelStyle(.iconOnly)
                    }
                        .disabled(!selectionAvailable || householdCategories.isEmpty)
                        .accessibilityIdentifier("shopping.categories.select")
                    Button { beginCreate() } label: {
                        Label("Add category", systemImage: "plus").labelStyle(.iconOnly)
                    }
                        .disabled(!selectionAvailable)
                        .accessibilityIdentifier("shopping.categories.add")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editMode.isEditing {
                Divider()
                HStack(spacing: 4) {
                    Button("Delete", systemImage: "trash", role: .destructive) { prepareBatch(.delete) }
                        .tint(.red)
                        .disabled(selectedIDs.isEmpty)
                        .accessibilityIdentifier("shopping.categories.batchDelete")
                        .frame(maxWidth: .infinity, minHeight: 44)
                    Button("Archive", systemImage: "archivebox") { prepareBatch(.archive) }
                        .disabled(!selectedCategories.contains(where: { !$0.isArchived }))
                        .accessibilityIdentifier("shopping.categories.batchArchive")
                        .frame(maxWidth: .infinity, minHeight: 44)
                    Button("Restore", systemImage: "arrow.uturn.backward") { prepareBatch(.restore) }
                        .disabled(!selectedCategories.contains(where: \.isArchived))
                        .accessibilityIdentifier("shopping.categories.batchRestore")
                        .frame(maxWidth: .infinity, minHeight: 44)
                    Button("Edit", systemImage: "pencil", action: editSelectedCategory)
                        .disabled(selectedCategories.count != 1)
                        .accessibilityIdentifier("shopping.categories.batchEdit")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .labelStyle(.iconOnly)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.bar)
            }
        }
        .sheet(item: $editor) { session in
            ManagementNameEditor(
                title: session.category == nil ? "Add category" : "Rename category",
                name: $editorName,
                fieldTitle: "Category name",
                fieldIdentifier: "shopping.categories.name",
                saveLabel: "Save category",
                initiallyFocused: session.category == nil,
                unavailableMessage: session.category == nil
                    ? "This household is unavailable. Your draft is still here."
                    : "This category is no longer available. Your draft is still here.",
                available: session.scope.matches(canonicalList: canonicalList)
                    && (session.category.map(householdCategories.contains) ?? true),
                onSave: { save(session) },
                onCancel: { editor = nil }
            )
        }
        .confirmationDialog(
            "Delete \(removingCategory?.name ?? "category")?",
            isPresented: Binding(get: { removingCategory != nil }, set: { if !$0 { removingCategory = nil } }),
            titleVisibility: .visible
        ) {
            if let category = removingCategory {
                Button("Delete category", role: .destructive) { remove(category) }
            }
            Button("Cancel", role: .cancel) { removingCategory = nil }
        } message: {
            Text("Groceries and catalog items will remain and become Uncategorized.")
        }
        .alert("Couldn’t update categories", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error?.localizedDescription ?? "Unknown error") }
        .confirmationDialog(
            batchPreview.map(ManagementBatchCopy.title) ?? "Delete selected categories?",
            isPresented: Binding(get: { batchPreview != nil }, set: { if !$0 { batchPreview = nil } }),
            titleVisibility: .visible
        ) {
            if let preview = batchPreview {
                Button(batchActionLabel(preview.token.action), role: preview.token.action == .delete ? .destructive : nil) {
                    applyBatch(preview.token)
                }
            }
            Button("Cancel", role: .cancel) { batchPreview = nil }
        } message: {
            if let preview = batchPreview {
                Text(ManagementBatchCopy.message(preview) + (preview.token.action == .delete ? " Groceries and catalog items remain Uncategorized." : ""))
            }
        }
        .alert("Batch update complete", isPresented: Binding(
            get: { batchNotice != nil }, set: { if !$0 { batchNotice = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(batchNotice ?? "") }
        .onChange(of: selection) { _, _ in clearSelection() }
        .onChange(of: householdCategories.map(\.id)) { _, ids in
            selectedIDs.formIntersection(Set(ids))
        }
        .onDisappear(perform: clearSelection)
    }

    private var standardList: some View {
        List {
            Section {
                ForEach(activeCategories, id: \.objectID) { category in
                    categoryRow(category).shoppingListRowInsets()
                }
                .onMove(perform: reorder)
            }
            if !archivedCategories.isEmpty {
                Section("Archived") {
                    ForEach(archivedCategories, id: \.objectID) { category in
                        categoryRow(category).shoppingListRowInsets()
                    }
                }
            }
        }
    }

    private var selectableList: some View {
        List(selection: $selectedIDs) {
            Section {
                ForEach(activeCategories, id: \.objectID) { category in
                    categoryRow(category).shoppingListRowInsets().tag(category.id)
                }
                .onMove(perform: reorder)
            }
            if !archivedCategories.isEmpty {
                Section("Archived") {
                    ForEach(archivedCategories, id: \.objectID) { category in
                        categoryRow(category).shoppingListRowInsets().tag(category.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func categoryRow(_ category: Category) -> some View {
        if editMode.isEditing {
            categoryRowActions(categoryRowLabel(category), category: category)
        } else {
            categoryRowActions(
                Button { beginRename(category) } label: {
                    categoryRowLabel(category)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain),
                category: category
            )
        }
    }

    private func categoryRowActions<Content: View>(_ content: Content, category: Category) -> some View {
        content
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { setArchived(category, !category.isArchived) } label: {
                Label(category.isArchived ? "Restore" : "Archive", systemImage: category.isArchived ? "arrow.uturn.backward" : "archivebox").labelStyle(.iconOnly)
            }
            .tint(category.isArchived ? .green : .orange)
            .disabled(!selectionAvailable)
            .accessibilityIdentifier("shopping.categories.archive.\(category.id.uuidString)")
            Button(role: .destructive) { removingCategory = category } label: {
                Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
            }
            .tint(.red)
            .disabled(!selectionAvailable)
            .accessibilityIdentifier("shopping.categories.delete.\(category.id.uuidString)")
        }
        .contextMenu {
            if !editMode.isEditing {
                Button("Select", systemImage: "checkmark.circle") { beginSelection(with: category.id) }
                    .accessibilityIdentifier("shopping.categories.contextSelect.\(category.id.uuidString)")
                Button(category.isArchived ? "Restore" : "Archive", systemImage: category.isArchived ? "arrow.uturn.backward" : "archivebox") {
                    setArchived(category, !category.isArchived)
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    removingCategory = category
                }
            }
        }
        .accessibilityAction(named: Text("Edit \(category.name)")) { beginRename(category) }
        .accessibilityAction(named: Text("\(category.isArchived ? "Restore" : "Archive") \(category.name)")) {
            setArchived(category, !category.isArchived)
        }
        .accessibilityAction(named: Text("Delete \(category.name)")) {
            removingCategory = category
        }
    }

    private func categoryRowLabel(_ category: Category) -> some View {
        HStack {
            Text(category.name)
            Spacer()
            if category.isArchived { Text("Archived").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func beginCreate() {
        guard let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        editorName = ""
        editor = CategoryEditorSession(category: nil, scope: scope)
    }

    private var selectedCategories: [Category] {
        householdCategories.filter { selectedIDs.contains($0.id) }
    }

    private func beginSelection(with categoryID: UUID) {
        guard !editMode.isEditing, selectionAvailable,
              householdCategories.contains(where: { $0.id == categoryID }) else { return }
        selectedIDs = [categoryID]
        editMode = .active
    }

    private func editSelectedCategory() {
        guard selectedCategories.count == 1, let category = selectedCategories.first else { return }
        clearSelection()
        beginRename(category)
    }

    private func beginRename(_ category: Category) {
        guard selectionAvailable, householdCategories.contains(category),
              let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        editorName = category.name
        error = nil
        editor = CategoryEditorSession(category: category, scope: scope)
    }

    private func save(_ session: CategoryEditorSession) {
        guard session.scope.matches(canonicalList: canonicalList), let service else { return }
        do {
            if let category = session.category {
                try service.renameCategory(
                    name: editorName, categoryID: category.id,
                    householdID: session.scope.householdID, listID: session.scope.listID
                )
            } else {
                _ = try service.createCategory(
                    name: editorName, householdID: session.scope.householdID,
                    listID: session.scope.listID
                )
            }
            hapticFeedback.play(.success)
            editor = nil
        } catch { self.error = error }
    }

    private func remove(_ category: Category) {
        guard selectionAvailable, let service, let householdID = selection.householdID,
              let listID = selection.listID else { return }
        do {
            try service.removeCategory(
                categoryID: category.id, householdID: householdID, listID: listID
            )
            hapticFeedback.play(.warning)
            removingCategory = nil
        } catch { self.error = error }
    }

    private func reorder(from offsets: IndexSet, to destination: Int) {
        guard selectionAvailable, let service, let householdID = selection.householdID,
              let listID = selection.listID else { return }
        var ids = activeCategories.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        do {
            try service.reorderCategories(ids, householdID: householdID, listID: listID)
        } catch { self.error = error }
    }

    private func prepareBatch(_ action: ManagementBatchAction) {
        guard let service, let householdID = selection.householdID, let listID = selection.listID else { return }
        do {
            let preview = try service.captureManagementBatch(
                entity: .category, action: action, ids: selectedIDs,
                householdID: householdID, listID: listID
            )
            if action == .delete { batchPreview = preview } else { applyBatch(preview.token) }
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

    private func setArchived(_ category: Category, _ archived: Bool) {
        guard let service, let householdID = selection.householdID, let listID = selection.listID else { return }
        do {
            try service.setCategoryArchived(archived, categoryID: category.id, householdID: householdID, listID: listID)
            hapticFeedback.play(.success)
        } catch { self.error = error }
    }

    private func batchActionLabel(_ action: ManagementBatchAction) -> String {
        switch action { case .archive: "Archive"; case .restore: "Restore"; case .delete: "Delete" }
    }
}

private struct CategoryEditorSession: Identifiable {
    let id = UUID()
    let category: Category?
    let scope: StoreManagementCommandScope
}

#Preview("Categories · populated") {
    ShoppingPreviewHost(.populated) { NavigationStack { CategoryManagementView() } }
}

#Preview("Categories · empty") {
    ShoppingPreviewHost(.empty) { NavigationStack { CategoryManagementView() } }
}
