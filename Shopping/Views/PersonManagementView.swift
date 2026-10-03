import CoreData
import SwiftUI

struct PersonManagementView: View {
    @Environment(\.needService) private var service
    @Environment(\.hapticFeedback) private var hapticFeedback
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.homeEditorDraftStore) private var draftStore
    @FetchRequest(fetchRequest: NavigationFetchRequests.people()) private var people: FetchedResults<Person>
    @FetchRequest(fetchRequest: NavigationFetchRequests.lists()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @State private var editor: PersonEditorSession?
    @State private var editorName = ""
    @State private var isSaving = false
    @State private var removal: PersonRemovalSession?
    @State private var error: Error?
    @State private var editMode: EditMode = .inactive
    @State private var selectedIDs: Set<UUID> = []
    @State private var batchPreview: ManagementBatchPreview?
    @State private var batchNotice: String?
    @State private var batchPending = false

    private var canonicalList: GroceryList? {
        GroceryRowScope.canonicalList(Array(lists), households: Array(households), selection: selection)
    }
    private var householdPeople: [Person] {
        GroceryRowScope.validPeople(
            Array(people), households: Array(households), selection: selection
        )
    }
    private var activePeople: [Person] { householdPeople.filter { !$0.isArchived } }
    private var archivedPeople: [Person] { householdPeople.filter(\.isArchived) }
    private var selectionAvailable: Bool { service != nil && canonicalList?.household != nil }

    var body: some View {
        Group {
            if editMode.isEditing { peopleList(selected: $selectedIDs) }
            else { peopleList(selected: nil) }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, $editMode)
        .navigationTitle(editMode.isEditing ? "\(selectedIDs.count) Selected" : "People")
        .toolbar {
            ShoppingCollectionToolbar(
                isSelecting: editMode.isEditing, allSelected: selectedIDs == Set(householdPeople.map(\.id)),
                selectAvailable: selectionAvailable && !householdPeople.isEmpty, addAvailable: selectionAvailable,
                addTitle: "Add person", identifierPrefix: "shopping.people",
                select: { editMode = .active }, add: beginCreate, done: clearSelection,
                toggleAll: {
                    let visible = Set(householdPeople.map(\.id))
                    selectedIDs = selectedIDs == visible ? [] : visible
                }
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editMode.isEditing {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 4) {
                        Button("Delete", systemImage: "trash", role: .destructive) { prepareBatch(.delete) }
                            .tint(.red)
                            .disabled(selectedIDs.isEmpty)
                            .accessibilityIdentifier("shopping.people.batchDelete")
                            .frame(maxWidth: .infinity, minHeight: ShoppingListMetrics.minimumRowHeight)
                        Button("Archive", systemImage: "archivebox") { prepareBatch(.archive) }
                            .disabled(!selectedPeople.contains(where: { !$0.isArchived }))
                            .accessibilityIdentifier("shopping.people.batchArchive")
                            .frame(maxWidth: .infinity, minHeight: ShoppingListMetrics.minimumRowHeight)
                        Button("Restore", systemImage: "arrow.uturn.backward") { prepareBatch(.restore) }
                            .disabled(!selectedPeople.contains(where: \.isArchived))
                            .accessibilityIdentifier("shopping.people.batchRestore")
                            .frame(maxWidth: .infinity, minHeight: ShoppingListMetrics.minimumRowHeight)
                        Button("Edit", systemImage: "pencil") {
                            guard let person = selectedPeople.first else { return }
                            clearSelection()
                            beginRename(person)
                        }
                        .disabled(selectedPeople.count != 1)
                        .accessibilityIdentifier("shopping.people.batchEdit")
                        .frame(maxWidth: .infinity, minHeight: ShoppingListMetrics.minimumRowHeight)
                    }
                    .labelStyle(.iconOnly)
                    .frame(minHeight: ShoppingListMetrics.minimumRowHeight)
                    .disabled(batchPending || !selectionAvailable)
                    .padding(.horizontal)
                }
                .background(.bar)
            }
        }
        .confirmationDialog(
            batchPreview.map(ManagementBatchCopy.title) ?? "Delete selected people?",
            isPresented: Binding(get: { batchPreview != nil }, set: { if !$0 { batchPreview = nil } }),
            titleVisibility: .visible
        ) {
            if let preview = batchPreview {
                Button("Confirm", role: .destructive) { applyBatch(preview.token) }
            }
            Button("Cancel", role: .cancel) { batchPreview = nil }
        } message: {
            if let preview = batchPreview { Text(ManagementBatchCopy.message(preview)) }
        }
        .alert("People updated", isPresented: Binding(
            get: { batchNotice != nil }, set: { if !$0 { batchNotice = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(batchNotice ?? "") }
        .sheet(item: $editor) { session in
            ManagementNameEditor(
                title: session.person == nil ? "Add person" : "Rename person",
                name: $editorName, fieldTitle: "Person name",
                fieldIdentifier: "shopping.people.name", saveLabel: "Save person",
                initiallyFocused: session.person == nil,
                unavailableMessage: session.person == nil
                    ? "This household is unavailable. Your draft is still here."
                    : "This person is no longer available. Your draft is still here.",
                available: session.scope.matches(canonicalList: canonicalList)
                    && (session.person.map(householdPeople.contains) ?? true),
                busy: isSaving,
                onSave: { save(session) }, onCancel: { editor = nil },
                draftIdentity: "person." + (session.person?.id.uuidString ?? "new")
            )
        }
        .alert("Couldn’t update people", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(error?.localizedDescription ?? "Unknown error") }
        .onChange(of: selection) { _, _ in editor = nil; removal = nil; batchPreview = nil; clearSelection() }
        .onChange(of: householdPeople.map(\.id)) { _, ids in selectedIDs.formIntersection(ids) }
        .onDisappear(perform: clearSelection)
    }

    private func peopleList(selected: Binding<Set<UUID>>?) -> some View {
        List(selection: selected) {
            Section {
                ForEach(activePeople, id: \.objectID) { person in row(person).shoppingListRowInsets().tag(person.id) }
                    .onMove(perform: reorder)
            }
            if !archivedPeople.isEmpty {
                Section("Archived") {
                    ForEach(archivedPeople, id: \.objectID) { person in row(person).shoppingListRowInsets().tag(person.id) }
                }
            }
        }
    }

    private var removalTitle: String {
        guard let removal else { return "Remove person?" }
        return removal.action == .archive ? "Archive \(removal.person.name)?" : "Delete \(removal.person.name)?"
    }

    private var selectedPeople: [Person] { householdPeople.filter { selectedIDs.contains($0.id) } }

    private func row(_ person: Person) -> some View {
        Group {
            if editMode.isEditing {
                personLabel(person)
            } else {
                Button { beginRename(person) } label: { personLabel(person) }
                    .buttonStyle(.plain)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { setArchived(person, !person.isArchived) } label: {
                Label(person.isArchived ? "Restore" : "Archive", systemImage: person.isArchived ? "arrow.uturn.backward" : "archivebox")
                    .labelStyle(.iconOnly)
            }
            .tint(person.isArchived ? .groceryAccent : .orange)
            .accessibilityIdentifier("shopping.people.archive.\(person.id.uuidString)")
            Button(role: .destructive) { beginRemoval(person) } label: {
                Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
            }
            .accessibilityIdentifier("shopping.people.delete.\(person.id.uuidString)")
        }
        .contextMenu {
            if !editMode.isEditing {
                Button("Select", systemImage: "checkmark.circle") {
                    guard selectionAvailable, householdPeople.contains(person) else { return }
                    selectedIDs = [person.id]
                    editMode = .active
                }
                .accessibilityIdentifier("shopping.people.contextSelect.\(person.id.uuidString)")
                Button(person.isArchived ? "Restore" : "Archive",
                       systemImage: person.isArchived ? "arrow.uturn.backward" : "archivebox") {
                    setArchived(person, !person.isArchived)
                }
                Button("Delete", systemImage: "trash", role: .destructive) { beginRemoval(person) }
            }
        }
        .accessibilityAction(named: Text("Edit \(person.name)")) { beginRename(person) }
        .accessibilityAction(named: Text("\(person.isArchived ? "Restore" : "Archive") \(person.name)")) {
            setArchived(person, !person.isArchived)
        }
        .accessibilityAction(named: Text("Delete \(person.name)")) { beginRemoval(person) }
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(
                get: { removal?.person.objectID == person.objectID },
                set: { if !$0 { removal = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let removal {
                Button(removal.action == .archive ? "Archive person" : "Delete person", role: .destructive) {
                    remove(removal)
                }
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text(removal?.action == .archive
                ? "This person is assigned to groceries, so archiving keeps those assignments visible and recoverable."
                : "This person is not assigned to any groceries and can be deleted.")
        }
    }

    private func personLabel(_ person: Person) -> some View {
        HStack {
            Text(person.name)
            Spacer()
            if person.isArchived { Text("Archived").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, minHeight: ShoppingListMetrics.minimumRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func clearSelection() { selectedIDs = []; editMode = .inactive }

    private func prepareBatch(_ action: ManagementBatchAction) {
        guard !batchPending, let service,
              let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        let ids = selectedIDs, householdID = scope.householdID, listID = scope.listID
        batchPending = true
        Task {
            defer { batchPending = false }
            do {
                let preview = try await Task.detached(priority: .userInitiated) {
                    try service.captureManagementBatch(entity: .person, action: action,
                        ids: ids, householdID: householdID, listID: listID)
                }.value
                guard selection.householdID == householdID, selection.listID == listID,
                      editMode.isEditing, selectedIDs == ids else { return }
                if action == .delete { batchPreview = preview }
                else { await performBatch(preview.token, service: service) }
            } catch {
                guard selection.householdID == householdID, selection.listID == listID else { return }
                self.error = error
            }
        }
    }

    private func applyBatch(_ token: ManagementBatchToken) {
        guard !batchPending, let service else { return }
        batchPending = true
        Task {
            defer { batchPending = false }
            await performBatch(token, service: service)
        }
    }

    private func performBatch(_ token: ManagementBatchToken, service: NeedService) async {
        guard selection.householdID == token.householdID, selection.listID == token.listID else {
            batchPreview = nil; clearSelection(); return
        }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try service.applyManagementBatch(token)
            }.value
            guard selection.householdID == token.householdID, selection.listID == token.listID else { return }
            batchPreview = nil
            clearSelection()
            batchNotice = ManagementBatchCopy.result(result)
            hapticFeedback.play(token.action == .delete ? .warning : .success)
        } catch {
            guard selection.householdID == token.householdID, selection.listID == token.listID else { return }
            batchPreview = nil
            self.error = error
        }
    }

    private func beginCreate() {
        guard let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        editorName = ""
        editor = PersonEditorSession(person: nil, scope: scope)
    }

    private func beginRename(_ person: Person) {
        guard householdPeople.contains(person),
              let scope = StoreManagementCommandScope(canonicalList: canonicalList) else { return }
        editorName = person.name
        editor = PersonEditorSession(person: person, scope: scope)
    }

    private func save(_ session: PersonEditorSession) {
        guard !isSaving, session.scope.matches(canonicalList: canonicalList), let service else { return }
        let draftLease = draftStore?.currentLease(scope: selection.homeScope,
            editor: "person." + (session.person?.id.uuidString ?? "new"))
        isSaving = true
        let name = editorName, personID = session.person?.id
        let householdID = session.scope.householdID, listID = session.scope.listID
        Task {
            defer { isSaving = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    if let personID {
                        try service.renamePerson(name: name, personID: personID,
                            householdID: householdID, listID: listID)
                    } else {
                        _ = try service.createPerson(name: name, householdID: householdID, listID: listID)
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
        guard let service, let householdID = selection.householdID, let listID = selection.listID else { return }
        var ids = activePeople.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try service.reorderPeople(ids, householdID: householdID, listID: listID)
                }.value
            } catch { self.error = error }
        }
    }

    private func setArchived(_ person: Person, _ archived: Bool) {
        guard let service, let householdID = selection.householdID, let listID = selection.listID else { return }
        let personID = person.id
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try service.setPersonArchived(archived, personID: personID,
                        householdID: householdID, listID: listID)
                }.value
                hapticFeedback.play(.success)
            } catch { self.error = error }
        }
    }

    private func beginRemoval(_ person: Person) {
        guard let service, let householdID = selection.householdID, let listID = selection.listID else { return }
        let personID = person.id
        Task {
            do {
                let action = try await Task.detached(priority: .userInitiated) {
                    try service.personRemovalAction(personID: personID,
                        householdID: householdID, listID: listID)
                }.value
                guard selection.householdID == householdID, selection.listID == listID else { return }
                removal = PersonRemovalSession(person: person, action: action)
            } catch { self.error = error }
        }
    }

    private func remove(_ session: PersonRemovalSession) {
        guard let service, let householdID = selection.householdID, let listID = selection.listID else { return }
        let personID = session.person.id, action = session.action
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try service.removePerson(personID: personID, householdID: householdID,
                        listID: listID, confirmedAction: action)
                }.value
                hapticFeedback.play(.warning)
                removal = nil
            } catch { removal = nil; self.error = error }
        }
    }
}

private struct PersonEditorSession: Identifiable {
    let id = UUID()
    let person: Person?
    let scope: StoreManagementCommandScope
}

private struct PersonRemovalSession {
    let person: Person
    let action: StoreRemovalAction
}

#Preview("People") {
    ShoppingPreviewHost(.populated) { NavigationStack { PersonManagementView() } }
}
