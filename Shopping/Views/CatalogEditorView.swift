import CoreData
import SwiftUI

struct CatalogSaveResult {
    let itemID: UUID
    let itemName: String
    let wasCreated: Bool
}

struct CatalogEditorView: View {
    private enum Field: Hashable { case name, notes }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.needService) private var service
    @Environment(\.hapticFeedback) private var hapticFeedback
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.items()) private var items: FetchedResults<Item>
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories: FetchedResults<Category>
    @FetchRequest(fetchRequest: PurchaseRulesStoreScope.listsRequest()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @State private var itemID: UUID?
    @State private var values: CatalogItemValues
    @State private var allowingNameCollision = false
    @State private var errorMessage: String?
    @State private var showingArchiveConfirmation = false
    @State private var showingCategoryCreation = false
    @State private var showingStoreCreation = false
    @State private var requestedArchived = true
    @FocusState private var focusedField: Field?
    let session: CatalogEditSession
    let onSaved: (CatalogSaveResult) -> Void
    let onAddToList: (CatalogSaveResult) -> String?

    init(
        session: CatalogEditSession,
        onSaved: @escaping (CatalogSaveResult) -> Void,
        onAddToList: @escaping (CatalogSaveResult) -> String? = { _ in nil }
    ) {
        self.session = session
        self.onSaved = onSaved
        self.onAddToList = onAddToList
        _itemID = State(initialValue: session.itemID)
        _values = State(initialValue: session.values)
    }

    private var household: Household? {
        CatalogScope.canonicalList(
            lists: Array(lists), households: Array(households), selection: session.selection
        )?.household
    }
    private var scopedItems: [Item] { CatalogScope.items(Array(items), household: household) }
    private var scopedCategories: [Category] { CatalogScope.categories(Array(categories), household: household) }
    private var currentItem: Item? { scopedItems.first { $0.id == itemID } }
    private var scopeAvailable: Bool { selection == session.selection && household != nil && service != nil }
    private var matches: [Item] {
        guard !CatalogProjection.normalizedName(values.name).isEmpty else { return [] }
        if let currentItem, CatalogProjection.normalizedName(currentItem.name) == CatalogProjection.normalizedName(values.name) { return [] }
        return scopedItems.filter { $0.id != itemID && CatalogProjection.textMatches($0.name, query: values.name) }
    }
    private var hasExactMatch: Bool {
        matches.contains { CatalogProjection.normalizedName($0.name) == CatalogProjection.normalizedName(values.name) }
    }
    private var canSave: Bool {
        scopeAvailable && !CatalogProjection.normalizedName(values.name).isEmpty &&
            (itemID == nil || currentItem != nil) && (!hasExactMatch || allowingNameCollision)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Remembered item") {
                    TextField("Item name", text: $values.name)
                        .accessibilityIdentifier("shopping.catalog.name")
                        .focused($focusedField, equals: .name)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Item notes")
                            .font(.subheadline).fontWeight(.semibold)
                            .shoppingMultilineText()
                            .accessibilityIdentifier("shopping.catalog.notesHeading")
                        TextField(
                            "Saved for future needs",
                            text: $values.notes,
                            axis: .vertical
                        )
                        .lineLimit(2...4)
                        .focused($focusedField, equals: .notes)
                        .accessibilityIdentifier("shopping.catalog.notes")
                    }
                }
                if !matches.isEmpty {
                    Section("Existing items") {
                        ForEach(matches, id: \.objectID) { item in
                            Button(
                                "Edit \(item.name)\(item.isArchived ? " (archived)" : "")",
                                systemImage: "pencil"
                            ) {
                                focusedField = nil
                                itemID = item.id
                                values = item.catalogValues
                                allowingNameCollision = false
                                errorMessage = nil
                            }
                        }
                        if hasExactMatch {
                            Toggle("Create a distinct item", isOn: $allowingNameCollision)
                            Text("Use this for an intentional brand or size variant. Existing items stay separate.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .shoppingMultilineText()
                        }
                    }
                }
                CategoryPills(
                    selection: $values.categoryID,
                    categories: scopedCategories,
                    includeUnavailable: true,
                    onAddCategory: { showingCategoryCreation = true }
                )
                PurchaseRulesPicker(
                    storeIDs: $values.storeIDs,
                    anyStore: $values.anyStore,
                    householdID: session.selection.householdID,
                    listID: session.selection.listID,
                    onAddStore: { showingStoreCreation = true }
                )
                if let item = currentItem {
                    Section {
                        Button(
                            item.isArchived ? "Restore item" : "Archive item",
                            systemImage: item.isArchived ? "arrow.uturn.backward" : "archivebox"
                        ) {
                            if item.isArchived && values == item.catalogValues { archive(false) }
                            else { requestedArchived = !item.isArchived; showingArchiveConfirmation = true }
                        }
                        .accessibilityIdentifier("shopping.catalog.archive")
                        .disabled(!scopeAvailable)
                        Text("Archiving hides this catalog item. Groceries already on your list stay there.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !scopeAvailable {
                    Text("This household is unavailable. Your draft is still here.")
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(itemID == nil ? "New catalog item" : "Edit catalog item")
            .onAppear {
                guard session.itemID == nil else { return }
                DispatchQueue.main.async { focusedField = .name }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    HStack {
                        Button("Save and Add to List", systemImage: "note.text.badge.plus") {
                            save(addToList: true)
                        }
                        .labelStyle(.iconOnly)
                        .disabled(!canSave || currentItem?.isArchived == true)
                        .accessibilityLabel("Save and Add to List")
                        .accessibilityIdentifier("shopping.catalog.saveAndAddToList")
                        Button("Save", systemImage: "checkmark") { save() }
                            .disabled(!canSave)
                            .accessibilityIdentifier("shopping.catalog.save")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                        .accessibilityIdentifier("shopping.catalog.keyboardDone")
                }
            }
            .onChange(of: values.name) { _, _ in allowingNameCollision = false }
            .alert(requestedArchived ? "Archive this catalog item?" : "Restore this catalog item?", isPresented: $showingArchiveConfirmation) {
                Button(requestedArchived ? "Archive item" : "Restore item") { archive(requestedArchived) }
                    .accessibilityIdentifier("shopping.catalog.confirmArchiveState")
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Current groceries and saved purchase rules are preserved. Unsaved edits in this form will be discarded.")
            }
            .sheet(isPresented: $showingCategoryCreation) {
                CategoryCreationView(
                    householdID: session.selection.householdID,
                    listID: session.selection.listID
                ) { values.categoryID = $0 }
            }
            .sheet(isPresented: $showingStoreCreation) {
                StoreCreationView(
                    householdID: session.selection.householdID,
                    listID: session.selection.listID
                ) { id in
                    if values.storeIDs.isEmpty { values.anyStore = false }
                    values.storeIDs.insert(id)
                }
            }
        }
    }

    private func save(addToList: Bool = false) {
        guard scopeAvailable, let service, let householdID = session.selection.householdID,
              let listID = session.selection.listID else { return }
        do {
            let wasCreated = itemID == nil
            let savedItemID: UUID
            if let itemID {
                try service.saveCatalogItem(
                    itemID: itemID, householdID: householdID, listID: listID,
                    values: values, allowingNameCollision: allowingNameCollision
                )
                savedItemID = itemID
            } else {
                savedItemID = try service.createCatalogItem(
                    values: values, householdID: householdID, listID: listID,
                    allowingNameCollision: allowingNameCollision
                )
            }
            let result = CatalogSaveResult(
                itemID: savedItemID,
                itemName: values.name.trimmingCharacters(in: .whitespacesAndNewlines),
                wasCreated: wasCreated
            )
            onSaved(result)
            if addToList, let addError = onAddToList(result) {
                itemID = savedItemID
                errorMessage = "Saved to Catalog, but couldn’t add to the list. \(addError)"
                hapticFeedback.play(.warning)
                return
            }
            hapticFeedback.play(.success)
            dismiss()
        } catch { errorMessage = CatalogErrorCopy.message(error) }
    }

    private func archive(_ archived: Bool) {
        guard scopeAvailable, let service, let householdID = session.selection.householdID,
              let listID = session.selection.listID, let itemID else { return }
        do {
            try service.setCatalogItemArchived(
                itemID: itemID, householdID: householdID, listID: listID,
                archived: archived
            )
            onSaved(CatalogSaveResult(itemID: itemID, itemName: values.name, wasCreated: false))
            dismiss()
        } catch { errorMessage = CatalogErrorCopy.message(error) }
    }
}

extension Item {
    var catalogValues: CatalogItemValues {
        CatalogItemValues(name: name, notes: notes, categoryID: category?.id,
            anyStore: anyStore, storeIDs: Set(stores?.map(\.id) ?? []))
    }

}

enum CatalogErrorCopy {
    static func message(_ error: Error) -> String {
        switch error as? NeedServiceError {
        case .invalidName: return "Enter an item name."
        case .storeNotFound: return "Choose an active store or turn on Any store. Check for unavailable stores."
        case .categoryNotFound: return "Choose an available category or Uncategorized."
        case .catalogNameCollision: return "An item with this name already exists. Choose it or confirm a distinct item."
        case .scopeChanged, .householdNotFound, .listNotFound: return "The household or selected details changed. Review your draft and try again."
        case .itemNotFound: return "This catalog item is no longer available. Your draft has been kept."
        case .invalidCatalogIdentity, .invalidStoreIdentity: return "Some shared items have conflicting identities. Your draft has been kept."
        default: return error.localizedDescription
        }
    }
}
