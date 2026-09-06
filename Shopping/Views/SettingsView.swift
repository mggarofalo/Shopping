import CoreData
import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Stores", destination: StoreManagementView())
                NavigationLink("Categories", destination: CategoryManagementView())
                Section("Household") {
                    LabeledContent("Sharing status", value: "Not connected")
                    Text("Groceries are available in this app’s current local household store.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct StoreManagementView: View {
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @State private var draftName = ""
    @State private var renameName = ""
    @State private var editingStore: Store?
    @State private var error: Error?

    private var householdStores: [Store] {
        stores.filter { $0.household?.id == selection.householdID && $0.id != PersistenceModel.unsetID }
    }

    var body: some View {
        List {
            Section("Add store") {
                TextField("Store name", text: $draftName).accessibilityIdentifier("shopping.stores.createName")
                Button("Save store") { create() }
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service == nil || selection.householdID == nil)
                if !draftName.isEmpty {
                    let matches = householdStores.filter { $0.name.localizedCaseInsensitiveCompare(draftName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
                    if !matches.isEmpty {
                        Text("Existing match") .font(.footnote).foregroundStyle(.secondary)
                        ForEach(matches, id: \.objectID) { store in
                            Button("Use \(store.name)") { beginRename(store) }
                        }
                    }
                }
            }
            Section("Stores") {
                ForEach(householdStores, id: \.objectID) { store in
                    HStack {
                        Text(store.name)
                        Spacer()
                        if store.isArchived { Text("Archived").foregroundStyle(.secondary) }
                        Button("Rename") { beginRename(store) }.buttonStyle(.borderless)
                        Button(store.isArchived ? "Restore" : "Archive") { archive(store) }
                            .buttonStyle(.borderless)
                    }
                }
                .onMove(perform: reorder)
            }
        }
        .navigationTitle("Stores")
        .toolbar { EditButton() }
        .sheet(isPresented: Binding(get: { editingStore != nil }, set: { if !$0 { editingStore = nil } })) {
            if let store = editingStore {
                NavigationStack {
                    Form { TextField("Store name", text: $renameName).accessibilityIdentifier("shopping.stores.renameName"); if let error { Text(error.localizedDescription).foregroundStyle(.red) } }
                        .navigationTitle("Rename store")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editingStore = nil } }
                            ToolbarItem(placement: .confirmationAction) { Button("Save") { rename(store) } }
                        }
                }
            }
        }
        .alert("Couldn’t update stores", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK", role: .cancel) {} } message: { Text(error?.localizedDescription ?? "Unknown error") }
    }

    private func create() {
        guard let service, let householdID = selection.householdID else { return }
        do { _ = try service.createStore(name: draftName, householdID: householdID); draftName = "" } catch { self.error = error }
    }
    private func archive(_ store: Store) {
        guard let service, let householdID = selection.householdID else { return }
        do { try service.setStoreArchived(!store.isArchived, storeID: store.id, householdID: householdID) } catch { self.error = error }
    }
    private func beginRename(_ store: Store) { renameName = store.name; error = nil; editingStore = store }
    private func rename(_ store: Store) {
        guard let service, let householdID = selection.householdID else { return }
        do { try service.renameStore(name: renameName, storeID: store.id, householdID: householdID); editingStore = nil } catch { self.error = error }
    }
    private func reorder(from offsets: IndexSet, to destination: Int) {
        guard let service, let householdID = selection.householdID else { return }
        var ids = householdStores.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        do { try service.reorderStores(ids, householdID: householdID) } catch { self.error = error }
    }
}

#Preview("Store settings · archived") { ShoppingPreviewHost(.archivedStore) { SettingsView() } }
#Preview("Store settings · empty") { ShoppingPreviewHost(.empty) { SettingsView() } }
#Preview("Store management · archived") { ShoppingPreviewHost(.archivedStore) { NavigationStack { StoreManagementView() } } }
