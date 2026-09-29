import CoreData
import SwiftUI

struct StoreCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.homeEditorParentKey) private var parentDraftKey
    @Environment(\.homeEditorDraftStore) private var draftStore
    @Environment(\.persistencePresentation) private var presentation
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: PurchaseRulesStoreScope.listsRequest()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @State private var name = ""
    @State private var error: Error?
    @State private var isSaving = false
    @State private var capturedScope: StoreManagementCommandScope?
    @State private var didCaptureScope = false
    @FocusState private var nameIsFocused: Bool
    let householdID: UUID?
    let listID: UUID?
    let onSelected: (UUID) -> Void

    private var scopeAvailable: Bool {
        !isSaving && service != nil && StoreManagementScope.permits(capturedScope, canonicalList: canonicalList)
    }

    private var canonicalList: GroceryList? {
        guard householdID != nil, listID != nil,
            selection.householdID == householdID, selection.listID == listID else { return nil }
        return GroceryRowScope.canonicalList(Array(lists), households: Array(households), selection: selection)
    }

    private var matches: [Store] {
        let query = CatalogProjection.normalizedName(name)
        guard !query.isEmpty else { return [] }
        return GroceryRowScope.validStores(Array(stores), canonicalList: canonicalList)
            .filter { CatalogProjection.normalizedName($0.name).contains(query) }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Store name", text: $name)
                    .accessibilityIdentifier("shopping.tags.storeName")
                    .focused($nameIsFocused)
                    .submitLabel(.done)
                    .onSubmit(save)
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
                Text("Save store adds it to your household. The item is saved separately.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !scopeAvailable { Text("This household is unavailable. Your store draft is still here.") }
                if let error { Text(error.localizedDescription).foregroundStyle(.red) }
            }
            .navigationTitle("Add store")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !didCaptureScope else { return }
                capturedScope = StoreManagementCommandScope(canonicalList: canonicalList)
                didCaptureScope = true
                DispatchQueue.main.async { nameIsFocused = true }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                        .accessibilityIdentifier("shopping.tags.storeCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save store", systemImage: "checkmark", action: save)
                        .disabled(!scopeAvailable || CatalogProjection.normalizedName(name).isEmpty)
                        .accessibilityIdentifier("shopping.tags.storeSave")
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
        .retainedHomeNameDraft($name, editor: parentDraftKey.map { $0 + ".new-store" })
    }

    private func select(_ store: Store) {
        guard scopeAvailable, matches.contains(store), let service, let capturedScope else { return }
        let draftLease = parentDraftKey.flatMap { draftStore?.currentLease(scope: selection.homeScope, editor: $0 + ".new-store") }
        isSaving = true
        let storeID = store.id, archived = store.isArchived
        let householdID = capturedScope.householdID, listID = capturedScope.listID
        Task {
            defer { isSaving = false }
            do {
                if archived {
                    try await Task.detached(priority: .userInitiated) {
                        try service.setStoreArchived(false, storeID: storeID,
                            householdID: householdID, listID: listID)
                    }.value
                }
                if let draftLease { draftStore?.finish(draftLease) }
                guard presentation?.isActive != false, selection.householdID == householdID, selection.listID == listID else { return }
                onSelected(storeID)
                dismiss()
            } catch { self.error = error }
        }
    }

    private func save() {
        guard scopeAvailable, let service, let capturedScope else { return }
        let draftLease = parentDraftKey.flatMap { draftStore?.currentLease(scope: selection.homeScope, editor: $0 + ".new-store") }
        isSaving = true
        let name = self.name
        let householdID = capturedScope.householdID, listID = capturedScope.listID
        Task {
            defer { isSaving = false }
            do {
                let id = try await Task.detached(priority: .userInitiated) {
                    try service.createStore(name: name, householdID: householdID, listID: listID)
                }.value
                if let draftLease { draftStore?.finish(draftLease) }
                guard presentation?.isActive != false, selection.householdID == householdID, selection.listID == listID else { return }
                onSelected(id)
                dismiss()
            } catch { self.error = error }
        }
    }
}
