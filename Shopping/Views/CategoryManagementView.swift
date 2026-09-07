import CoreData
import SwiftUI

struct CategoryNeedGroup: Identifiable {
    let categoryID: UUID?
    let title: String
    let needs: [Need]

    var id: String { categoryID?.uuidString ?? "uncategorized" }
}

struct PriorityCategoryNeedGroup: Identifiable {
    let urgency: NeedUrgency
    let categories: [CategoryNeedGroup]

    var id: String { urgency.rawValue }
    var title: String { urgency == .urgent ? "Urgent" : "Normal" }
}

enum CategoryGrouping {
    static func ordered(_ categories: [Category], household: Household?) -> [Category] {
        guard let household, let persistentStore = household.objectID.persistentStore else { return [] }
        let scoped = categories.filter {
            $0.household == household && $0.objectID.persistentStore == persistentStore &&
                $0.id != PersistenceModel.unsetID
        }
        let counts = Dictionary(grouping: scoped, by: \.id).mapValues(\.count)
        return scoped.filter { counts[$0.id] == 1 }.sorted {
            if $0.displayOrder != $1.displayOrder { return $0.displayOrder < $1.displayOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func groups(
        needs: [Need],
        categories: [Category],
        household: Household?
    ) -> [PriorityCategoryNeedGroup] {
        let orderedCategories = ordered(categories, household: household)
        let validObjects = Set(orderedCategories.map(\.objectID))
        return [NeedUrgency.urgent, .normal].compactMap { urgency in
            let matchingUrgency = needs.filter {
                (NeedUrgency(rawValue: $0.urgency) ?? .normal) == urgency
            }
            guard !matchingUrgency.isEmpty else { return nil }
            let categories = categoryGroups(
                needs: matchingUrgency,
                orderedCategories: orderedCategories,
                validObjects: validObjects
            )
            return PriorityCategoryNeedGroup(urgency: urgency, categories: categories)
        }
    }

    private static func categoryGroups(
        needs: [Need],
        orderedCategories: [Category],
        validObjects: Set<NSManagedObjectID>
    ) -> [CategoryNeedGroup] {
        var remaining = needs
        var groups: [CategoryNeedGroup] = []
        for category in orderedCategories {
            let matching = remaining.filter { categoryObject(for: $0)?.objectID == category.objectID }
            guard !matching.isEmpty else { continue }
            groups.append(CategoryNeedGroup(categoryID: category.id, title: category.name, needs: sortedNames(matching)))
            remaining.removeAll { categoryObject(for: $0)?.objectID == category.objectID }
        }
        let uncategorized = remaining.filter {
            guard let category = categoryObject(for: $0) else { return true }
            return !validObjects.contains(category.objectID)
        }
        if !uncategorized.isEmpty {
            groups.append(CategoryNeedGroup(categoryID: nil, title: "Uncategorized", needs: sortedNames(uncategorized)))
        }
        return groups
    }

    private static func categoryObject(for need: Need) -> Category? {
        if let item = need.item { return item.category }
        return need.kind == NeedKind.oneTime.rawValue ? need.oneTimeCategory : nil
    }

    private static func sortedNames(_ needs: [Need]) -> [Need] {
        needs.sorted {
            let left = $0.item?.name ?? $0.title
            let right = $1.item?.name ?? $1.title
            let comparison = left.localizedCaseInsensitiveCompare(right)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }
}

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

    private var selectionAvailable: Bool {
        service != nil && CategoryManagementScope.household(
            lists: Array(lists), households: Array(households),
            householdID: selection.householdID, listID: selection.listID
        ) != nil
    }

    var body: some View {
        List(selection: $selectedIDs) {
            Section {
                ForEach(householdCategories, id: \.objectID) { category in
                    categoryRow(category)
                        .shoppingListRowInsets()
                        .tag(category.id)
                }
                .onMove(perform: reorder)
            } header: {
                Text("Categories")
            } footer: {
                Text("Categories group groceries across every store. They do not define aisle order.")
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Categories")
        .toolbar {
            if editMode.isEditing {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: clearSelection) }
                ToolbarItem(placement: .primaryAction) {
                    Menu("Actions", systemImage: "ellipsis.circle") {
                        Button(selectedIDs == Set(householdCategories.map(\.id)) ? "Deselect All" : "Select All") {
                            let visible = Set(householdCategories.map(\.id))
                            selectedIDs = selectedIDs == visible ? [] : visible
                        }
                        Divider()
                        if !selectedIDs.isEmpty {
                            Button("Delete", systemImage: "trash", role: .destructive) { prepareBatchDelete() }
                        }
                    }
                    .accessibilityIdentifier("shopping.categories.batchActions")
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button { beginCreate() } label: { Label("Add category", systemImage: "plus") }
                        .disabled(!selectionAvailable)
                        .accessibilityIdentifier("shopping.categories.add")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Select") { editMode = .active }
                        .disabled(!selectionAvailable)
                        .accessibilityIdentifier("shopping.categories.select")
                }
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
                Button("Delete", role: .destructive) { applyBatch(preview.token) }
            }
            Button("Cancel", role: .cancel) { batchPreview = nil }
        } message: {
            if let preview = batchPreview {
                Text(ManagementBatchCopy.message(preview) + " Groceries and catalog items remain Uncategorized.")
            }
        }
        .alert("Batch update complete", isPresented: Binding(
            get: { batchNotice != nil }, set: { if !$0 { batchNotice = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(batchNotice ?? "") }
        .onChange(of: selection) { _, _ in clearSelection() }
        .onChange(of: householdCategories.map(\.id)) { _, ids in
            selectedIDs.formIntersection(Set(ids))
        }
    }

    @ViewBuilder
    private func categoryRow(_ category: Category) -> some View {
        Text(category.name)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { beginRename(category) } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.blue)
                .disabled(!selectionAvailable)
                .accessibilityIdentifier("shopping.categories.edit.\(category.id.uuidString)")
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button(role: .destructive) { removingCategory = category } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
                .disabled(!selectionAvailable)
                .accessibilityIdentifier("shopping.categories.delete.\(category.id.uuidString)")
            }
            .accessibilityAction(named: Text("Edit \(category.name)")) { beginRename(category) }
            .accessibilityAction(named: Text("Delete \(category.name)")) {
                removingCategory = category
            }
    }

    private func beginCreate() {
        guard let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        editorName = ""
        editor = CategoryEditorSession(category: nil, scope: scope)
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
        var ids = householdCategories.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        do {
            try service.reorderCategories(ids, householdID: householdID, listID: listID)
        } catch { self.error = error }
    }

    private func prepareBatchDelete() {
        guard let service, let householdID = selection.householdID, let listID = selection.listID else { return }
        do {
            batchPreview = try service.captureManagementBatch(
                entity: .category, action: .delete, ids: selectedIDs,
                householdID: householdID, listID: listID
            )
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
            hapticFeedback.play(.warning)
        } catch { batchPreview = nil; self.error = error }
    }

    private func clearSelection() { selectedIDs = []; editMode = .inactive }
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
