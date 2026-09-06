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
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories: FetchedResults<Category>
    @FetchRequest(fetchRequest: PurchaseRulesStoreScope.listsRequest()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @State private var draftName = ""
    @State private var renameName = ""
    @State private var editingCategory: Category?
    @State private var removingCategory: Category?
    @State private var error: Error?

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
        List {
            Section("Add category") {
                TextField("Category name", text: $draftName)
                    .accessibilityIdentifier("shopping.categories.createName")
                Button(action: create) { Label("Save category", systemImage: "checkmark") }
                    .frame(minHeight: 44)
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        !selectionAvailable)
                if !selectionAvailable {
                    Text("This household is unavailable. Your draft is still here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(householdCategories, id: \.objectID) { category in
                    HStack {
                        Text(category.name)
                        Spacer()
                        Button { beginRename(category) } label: { Label("Rename", systemImage: "pencil") }
                            .buttonStyle(.borderless)
                            .frame(minHeight: 44)
                            .disabled(!selectionAvailable)
                        Button(role: .destructive) { removingCategory = category } label: { Label("Remove", systemImage: "trash") }
                            .buttonStyle(.borderless)
                            .frame(minHeight: 44)
                            .disabled(!selectionAvailable)
                    }
                }
                .onMove(perform: reorder)
            } header: {
                Text("Categories")
            } footer: {
                Text("Categories group groceries across every store. They do not define aisle order.")
            }
        }
        .navigationTitle("Categories")
        .toolbar { EditButton().disabled(!selectionAvailable) }
        .sheet(isPresented: Binding(get: { editingCategory != nil }, set: { if !$0 { editingCategory = nil } })) {
            if let category = editingCategory {
                NavigationStack {
                    Form {
                        TextField("Category name", text: $renameName)
                            .accessibilityIdentifier("shopping.categories.renameName")
                        if !selectionAvailable {
                            Text("This household is unavailable. Your draft is still here.")
                                .foregroundStyle(.secondary)
                        }
                        if let error { Text(error.localizedDescription).foregroundStyle(.red) }
                    }
                    .navigationTitle("Rename category")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editingCategory = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { rename(category) }
                                .disabled(renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                    !selectionAvailable)
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Remove category?",
            isPresented: Binding(get: { removingCategory != nil }, set: { if !$0 { removingCategory = nil } }),
            titleVisibility: .visible
        ) {
            if let category = removingCategory {
                Button("Remove \(category.name)", role: .destructive) { remove(category) }
            }
            Button("Cancel", role: .cancel) { removingCategory = nil }
        } message: {
            Text("Groceries and catalog items will remain and become Uncategorized.")
        }
        .alert("Couldn’t update categories", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error?.localizedDescription ?? "Unknown error") }
    }

    private func create() {
        guard selectionAvailable, let service, let householdID = selection.householdID,
              let listID = selection.listID else { return }
        do {
            let currentMaximum = householdCategories.map(\.displayOrder).max() ?? -1
            let nextOrder = currentMaximum == Int64.max ? Int64.max : currentMaximum + 1
            _ = try service.createCategory(
                name: draftName, householdID: householdID, listID: listID,
                displayOrder: nextOrder
            )
            draftName = ""
        } catch { self.error = error }
    }

    private func beginRename(_ category: Category) {
        guard selectionAvailable else { return }
        renameName = category.name
        error = nil
        editingCategory = category
    }

    private func rename(_ category: Category) {
        guard selectionAvailable, let service, let householdID = selection.householdID,
              let listID = selection.listID else { return }
        do {
            try service.renameCategory(
                name: renameName, categoryID: category.id, householdID: householdID,
                listID: listID
            )
            editingCategory = nil
        } catch { self.error = error }
    }

    private func remove(_ category: Category) {
        guard selectionAvailable, let service, let householdID = selection.householdID,
              let listID = selection.listID else { return }
        do {
            try service.removeCategory(
                categoryID: category.id, householdID: householdID, listID: listID
            )
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
}

#Preview("Categories · populated") {
    ShoppingPreviewHost(.populated) { NavigationStack { CategoryManagementView() } }
}

#Preview("Categories · empty") {
    ShoppingPreviewHost(.empty) { NavigationStack { CategoryManagementView() } }
}
