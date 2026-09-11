import SwiftUI

struct PersonManagementView: View {
    @Environment(\.needService) private var service
    @Environment(\.hapticFeedback) private var hapticFeedback
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.people()) private var people: FetchedResults<Person>
    @FetchRequest(fetchRequest: NavigationFetchRequests.lists()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @State private var editor: PersonEditorSession?
    @State private var editorName = ""
    @State private var removal: PersonRemovalSession?
    @State private var error: Error?

    private var canonicalList: GroceryList? {
        GroceryRowScope.canonicalList(Array(lists), households: Array(households), selection: selection)
    }
    private var householdPeople: [Person] {
        GroceryRowScope.validPeople(Array(people), canonicalList: canonicalList)
    }
    private var activePeople: [Person] { householdPeople.filter { !$0.isArchived } }
    private var archivedPeople: [Person] { householdPeople.filter(\.isArchived) }
    private var selectionAvailable: Bool { service != nil && canonicalList?.household != nil }

    var body: some View {
        List {
            Section {
                ForEach(activePeople, id: \.objectID) { person in row(person).shoppingListRowInsets() }
                    .onMove(perform: reorder)
            }
            if !archivedPeople.isEmpty {
                Section("Archived") {
                    ForEach(archivedPeople, id: \.objectID) { person in row(person).shoppingListRowInsets() }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("People")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                EditButton()
                    .disabled(!selectionAvailable || activePeople.isEmpty)
                    .accessibilityIdentifier("shopping.people.reorder")
                Button(action: beginCreate) { Label("Add person", systemImage: "plus").labelStyle(.iconOnly) }
                    .disabled(!selectionAvailable)
                    .accessibilityIdentifier("shopping.people.add")
            }
        }
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
                onSave: { save(session) }, onCancel: { editor = nil }
            )
        }
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
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
        .alert("Couldn’t update people", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(error?.localizedDescription ?? "Unknown error") }
        .onChange(of: selection) { _, _ in editor = nil; removal = nil }
    }

    private var removalTitle: String {
        guard let removal else { return "Remove person?" }
        return removal.action == .archive ? "Archive \(removal.person.name)?" : "Delete \(removal.person.name)?"
    }

    private func row(_ person: Person) -> some View {
        Button { beginRename(person) } label: {
            HStack {
                Text(person.name)
                Spacer()
                if person.isArchived { Text("Archived").font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { setArchived(person, !person.isArchived) } label: {
                Label(person.isArchived ? "Restore" : "Archive", systemImage: person.isArchived ? "arrow.uturn.backward" : "archivebox")
                    .labelStyle(.iconOnly)
            }
            .tint(person.isArchived ? .green : .orange)
            .accessibilityIdentifier("shopping.people.archive.\(person.id.uuidString)")
            Button(role: .destructive) { beginRemoval(person) } label: {
                Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
            }
            .accessibilityIdentifier("shopping.people.delete.\(person.id.uuidString)")
        }
        .accessibilityAction(named: Text("Edit \(person.name)")) { beginRename(person) }
        .accessibilityAction(named: Text("\(person.isArchived ? "Restore" : "Archive") \(person.name)")) {
            setArchived(person, !person.isArchived)
        }
        .accessibilityAction(named: Text("Delete \(person.name)")) { beginRemoval(person) }
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
        guard session.scope.matches(canonicalList: canonicalList), let service else { return }
        do {
            if let person = session.person {
                try service.renamePerson(
                    name: editorName, personID: person.id,
                    householdID: session.scope.householdID, listID: session.scope.listID
                )
            } else {
                _ = try service.createPerson(
                    name: editorName, householdID: session.scope.householdID, listID: session.scope.listID
                )
            }
            hapticFeedback.play(.success)
            editor = nil
        } catch { self.error = error }
    }

    private func reorder(from offsets: IndexSet, to destination: Int) {
        guard let service, let householdID = selection.householdID, let listID = selection.listID else { return }
        var ids = activePeople.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        do { try service.reorderPeople(ids, householdID: householdID, listID: listID) }
        catch { self.error = error }
    }

    private func setArchived(_ person: Person, _ archived: Bool) {
        guard let service, let householdID = selection.householdID, let listID = selection.listID else { return }
        do {
            try service.setPersonArchived(archived, personID: person.id, householdID: householdID, listID: listID)
            hapticFeedback.play(.success)
        } catch { self.error = error }
    }

    private func beginRemoval(_ person: Person) {
        guard let service, let householdID = selection.householdID, let listID = selection.listID else { return }
        do {
            let action = try service.personRemovalAction(
                personID: person.id, householdID: householdID, listID: listID
            )
            removal = PersonRemovalSession(person: person, action: action)
        } catch { self.error = error }
    }

    private func remove(_ session: PersonRemovalSession) {
        guard let service, let householdID = selection.householdID, let listID = selection.listID else { return }
        do {
            _ = try service.removePerson(
                personID: session.person.id, householdID: householdID,
                listID: listID, confirmedAction: session.action
            )
            hapticFeedback.play(.warning)
            removal = nil
        } catch { removal = nil; self.error = error }
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
