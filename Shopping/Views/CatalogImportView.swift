import SwiftUI

struct CatalogImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var actions: [String: CatalogImportAction]
    @State private var showingConfirmation = false
    let session: CatalogImportSession
    let onImport: ([String: CatalogImportAction]) -> Void

    init(session: CatalogImportSession, onImport: @escaping ([String: CatalogImportAction]) -> Void) {
        self.session = session
        self.onImport = onImport
        _actions = State(initialValue: Dictionary(uniqueKeysWithValues: session.preview.entries.map {
            ($0.id, $0.disposition == .create ? .create : .skip)
        }))
    }

    private var selectedCount: Int {
        actions.values.filter { $0 != .skip }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("File", value: session.filename)
                    Text("Review every row before importing. Existing linked items and name conflicts are skipped unless you explicitly choose an action.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(session.preview.entries) { entry in
                    Section("Line \(entry.row.line)") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.row.name.isEmpty ? "Invalid row" : entry.row.name).font(.headline)
                            Text(details(for: entry)).font(.subheadline).foregroundStyle(.secondary)
                            Text(status(for: entry)).font(.subheadline)
                                .foregroundStyle(isInvalid(entry) ? Color.red : Color.secondary)
                        }
                        Picker("Action for \(entry.row.name)", selection: actionBinding(for: entry)) {
                            ForEach(availableActions(for: entry)) { action in
                                Text(actionTitle(action, for: entry)).tag(action)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(isInvalid(entry))
                        .accessibilityIdentifier("shopping.catalog.import.action.\(entry.row.line)")
                    }
                }
            }
            .navigationTitle("Import preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { showingConfirmation = true }
                        .disabled(selectedCount == 0)
                        .accessibilityIdentifier("shopping.catalog.import.confirm")
                }
            }
            .confirmationDialog(
                "Import \(selectedCount) catalog \(selectedCount == 1 ? "item" : "items")?",
                isPresented: $showingConfirmation,
                titleVisibility: .visible
            ) {
                Button("Import \(selectedCount) \(selectedCount == 1 ? "item" : "items")") {
                    onImport(actions)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only the reviewed rows and actions shown here will be applied.")
            }
        }
    }

    private func actionBinding(for entry: CatalogImportEntry) -> Binding<CatalogImportAction> {
        Binding(
            get: { actions[entry.id] ?? .skip },
            set: { actions[entry.id] = $0 }
        )
    }

    private func availableActions(for entry: CatalogImportEntry) -> [CatalogImportAction] {
        switch entry.disposition {
        case .create: [.create, .skip]
        case .update: [.skip, .update]
        case .nameConflict: [.skip, .create]
        case .invalid: [.skip]
        }
    }

    private func actionTitle(_ action: CatalogImportAction, for entry: CatalogImportEntry) -> String {
        guard action == .create else { return action.title }
        if case .nameConflict = entry.disposition { return "Import separately" }
        return "Import new item"
    }

    private func isInvalid(_ entry: CatalogImportEntry) -> Bool {
        if case .invalid = entry.disposition { return true }
        return false
    }

    private func status(for entry: CatalogImportEntry) -> String {
        switch entry.disposition {
        case .create: "Ready to import as a new catalog item."
        case .update:
            if !entry.reviewedIncomingCollisionIDs.isEmpty || !entry.collisionRevisions.isEmpty {
                "This linked item will share its name with another reviewed item. Choose Update linked item to continue."
            } else {
                "This source row was imported before. Choose Update linked item to replace its saved details."
            }
        case .nameConflict: "A different catalog item has the same name. Skip it or explicitly import a separate item."
        case .invalid(let reason): reason
        }
    }

    private func details(for entry: CatalogImportEntry) -> String {
        let category = entry.row.categoryName ?? "Uncategorized"
        let stores = entry.row.storeNames.isEmpty ? "Any store" : entry.row.storeNames.joined(separator: ", ")
        return "\(category) · \(stores) · \(entry.row.sourceID)/\(entry.row.itemID)"
    }
}

#Preview {
    let row = CatalogImportRow(
        line: 2,
        sourceID: "family-export",
        itemID: "001",
        name: "Whole milk",
        notes: "2%",
        categoryName: "Dairy",
        storeNames: ["Publix", "Costco"]
    )
    let entry = CatalogImportEntry(
        row: row,
        catalogItemID: CatalogImportIdentity.uuid(
            householdID: UUID(), sourceID: row.sourceID, itemID: row.itemID
        ),
        existingRevision: nil,
        categoryID: UUID(),
        categoryRevision: 0,
        storeIDs: [UUID(), UUID()],
        storeRevisions: [:],
        reviewedIncomingCollisionIDs: [],
        allowedIncomingCollisionIDs: [],
        collisionRevisions: [:],
        disposition: .create
    )
    CatalogImportView(session: CatalogImportSession(
        filename: "catalog.csv",
        preview: CatalogImportPreview(householdID: UUID(), listID: UUID(), entries: [entry])
    )) { _ in }
}
