import CoreData
import SwiftUI
import UIKit

struct OneTimeGrocerySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var currentSelection
    @State private var name = ""
    @State private var selectedStoreIDs: Set<UUID>
    @State private var anyStore: Bool
    @State private var error: Error?
    @State private var showingStoreCreation = false
    @FocusState private var nameIsFocused: Bool
    let scope: GroceryAddScope
    let onSaved: () -> Void

    init(scope: GroceryAddScope, onSaved: @escaping () -> Void) {
        self.scope = scope
        self.onSaved = onSaved
        _selectedStoreIDs = State(initialValue: scope.selectedStoreID.map { [$0] } ?? [])
        _anyStore = State(initialValue: scope.selectedStoreID == nil)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            service != nil && scope.listID != nil && scope.householdID != nil &&
            currentSelection == PersistenceSelection(householdID: scope.householdID, listID: scope.listID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("One-time item") {
                    TextField("Item name", text: $name)
                        .accessibilityIdentifier("shopping.oneTime.name")
                        .focused($nameIsFocused)
                        .submitLabel(.done)
                        .onSubmit { nameIsFocused = false }
                    Text("This item won’t be remembered in Catalog.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                PurchaseRulesPicker(
                    storeIDs: $selectedStoreIDs, anyStore: $anyStore,
                    householdID: scope.householdID, listID: scope.listID,
                    onAddStore: { showingStoreCreation = true }
                )
                if service == nil || scope.listID == nil || scope.householdID == nil {
                    Text("This household is still loading. Your draft will remain here.")
                        .foregroundStyle(.secondary)
                } else if currentSelection != PersistenceSelection(householdID: scope.householdID, listID: scope.listID) {
                    Text(GroceryAddError.selectionChanged.localizedDescription)
                        .foregroundStyle(.secondary)
                }
                if let error { Text(error.localizedDescription).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Add one-time item")
            .onAppear { DispatchQueue.main.async { nameIsFocused = true } }
            .sheet(isPresented: $showingStoreCreation) {
                StoreCreationView(householdID: scope.householdID, listID: scope.listID) { id in
                    if selectedStoreIDs.isEmpty { anyStore = false }
                    selectedStoreIDs.insert(id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        do {
            _ = try scope.addOneTime(
                title: name,
                selectedStoreIDs: selectedStoreIDs,
                anyStore: anyStore,
                currentSelection: currentSelection,
                service: service
            )
            onSaved()
            dismiss()
        } catch { self.error = error }
    }

}
