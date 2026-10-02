import SwiftUI

struct HomeSelectionView: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    @Environment(\.dismiss) private var dismiss
    @State private var isSelecting = false
    @State private var showingNewHome = false
    @State private var error: String?

    private var entry: HomeEntrySnapshot { bootstrap.homeEntry }
    private var localName: String? {
        entry.retainedLocalHomeName ?? (entry.root == .localHome ? entry.currentHomeName : nil)
    }
    private var localSelected: Bool { entry.root == .localHome || entry.isShowingRetainedLocalHome }
    private var visibleInvitations: [HomeEntrySnapshot.Invitation] {
        entry.invitations.filter {
            if case .dismissed = $0.state { return false }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Your homes") {
                    ForEach(entry.homes) { home in
                        Button { select(home) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "house")
                                    .foregroundStyle(Color.groceryAccent)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(home.name).foregroundStyle(.primary)
                                    if needsContext(for: home) {
                                        Text(accessDescription(home.access))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if home.isSelected { Image(systemName: "checkmark").foregroundStyle(Color.groceryAccent) }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .disabled(isSelecting || home.access == .unresolved)
                        .accessibilityLabel(home.name)
                        .accessibilityValue((needsContext(for: home) ? accessDescription(home.access) + ", " : "")
                            + (home.isSelected ? "Selected" : "Not selected"))
                        .accessibilityIdentifier("shopping.home.choice." + home.id.storeIdentifier + "." + home.id.rootURI)
                    }
                    if let localName {
                        Button { openRetainedLocalHome() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "iphone")
                                    .foregroundStyle(Color.groceryAccent)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(localName).foregroundStyle(.primary)
                                    Text("On This iPhone").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if localSelected {
                                    Image(systemName: "checkmark").foregroundStyle(Color.groceryAccent)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .disabled(isSelecting)
                        .accessibilityLabel(localName)
                        .accessibilityValue("On This iPhone" + (localSelected ? ", Selected" : ""))
                        .accessibilityIdentifier("shopping.home.retainedLocal")
                    }
                }
                if !visibleInvitations.isEmpty {
                    Section("Invitations") {
                        ForEach(visibleInvitations) { invitation in
                            Button(invitation.displayName ?? "Open Invitation", systemImage: "envelope") {
                                resume(invitation.id)
                            }
                            .disabled(isSelecting)
                            .accessibilityIdentifier("shopping.home.openInvitation.\(invitation.id.uuidString)")
                        }
                    }
                }
                Section {
                    if entry.root == .noHomes {
                        Button("Create Home", systemImage: "plus") { createFirstHome() }
                            .accessibilityIdentifier("shopping.home.create")
                    } else if !entry.isLocalStore {
                        Button { showingNewHome = true } label: {
                            Label("Create Home", systemImage: "plus")
                        }
                        .accessibilityIdentifier("shopping.home.create")
                    }
                    if case .activeHome(let scope) = entry.root {
                        NavigationLink {
                            HomeDetailsView(scope: scope, name: entry.currentHomeName ?? "Home",
                                actions: bootstrap.homeDetailsActions(scope: scope))
                        } label: {
                            Label("Home Settings", systemImage: "gearshape")
                        }
                        .accessibilityIdentifier("shopping.home.settings")
                    } else if localSelected {
                        NavigationLink {
                            LocalHomeSettingsView(bootstrap: bootstrap)
                        } label: {
                            Label("Home Settings", systemImage: "gearshape")
                        }
                        .accessibilityIdentifier("shopping.home.settings")
                    }
                }
                if entry.homeDiscoveryFailed || entry.root == .selectedHomeUnavailable {
                    Section {
                        Button("Check Again") { Task { await refresh() } }
                    } footer: {
                        Text("Home unavailable")
                    }
                }
                if bootstrap.homeLeaveStatuses.contains(where: \.requiresResolution) || bootstrap.homeLeaveStatusError != nil {
                    HomeLeaveStatusSection(bootstrap: bootstrap)
                }
                if bootstrap.homeDeletionStatuses.contains(where: \.requiresResolution) || bootstrap.homeDeletionStatusError != nil {
                    HomeDeletionStatusSection(bootstrap: bootstrap)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Homes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showingNewHome) {
                NewHomeView(bootstrap: bootstrap) { selected in
                    showingNewHome = false
                    if selected { dismiss() }
                    else { Task { await refresh() } }
                }
            }
            .task { await refresh() }
        }
    }

    private func needsContext(for home: HomeEntrySnapshot.Home) -> Bool {
        entry.homes.filter { $0.name == home.name }.count > 1 || localName == home.name
    }

    private func accessDescription(_ access: HomeCandidate.Access) -> String {
        switch access {
        case .owner: "Owner"
        case .contributor: "Member"
        case .restricted: "Read-only"
        case .unresolved: "Checking access"
        }
    }

    private func select(_ home: HomeEntrySnapshot.Home) {
        guard !isSelecting else { return }
        if home.isSelected { dismiss(); return }
        isSelecting = true
        Task {
            defer { isSelecting = false }
            do {
                try await bootstrap.homeEntryCommands.select(home.id)
                dismiss()
            } catch { self.error = "Couldn’t open home. Try again." }
        }
    }

    private func createFirstHome() {
        guard !isSelecting else { return }
        isSelecting = true
        Task {
            defer { isSelecting = false }
            do {
                try await bootstrap.homeEntryCommands.createFirstHome()
                dismiss()
            } catch { self.error = "Couldn’t create home. Try again." }
        }
    }

    private func openRetainedLocalHome() {
        guard !isSelecting else { return }
        if localSelected { dismiss(); return }
        isSelecting = true
        Task {
            defer { isSelecting = false }
            do {
                try await bootstrap.homeEntryCommands.openRetainedLocalHome()
                dismiss()
            } catch { self.error = "Couldn’t open home. Try again." }
        }
    }

    private func resume(_ id: UUID) {
        guard !isSelecting else { return }
        isSelecting = true
        Task {
            defer { isSelecting = false }
            do {
                try await bootstrap.homeEntryCommands.joinInvitation(id)
            } catch { self.error = "Couldn’t open invitation. Try again." }
        }
    }

    private func refresh() async {
        guard !entry.isLocalStore else { return }
        do { try await bootstrap.homeEntryCommands.refreshHomes() }
        catch { self.error = "Couldn’t check homes. Try again." }
    }
}

private struct NewHomeView: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    let onCreated: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name = ""
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .focused($nameFocused)
                    .accessibilityIdentifier("shopping.home.name")
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("New Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                }
            }
            .onAppear { nameFocused = true }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCreating else { return }
        isCreating = true
        Task {
            defer { isCreating = false }
            do {
                let commands = bootstrap.homeEntryCommands
                let pending = try await commands.pendingCreation()
                let created = try await commands.create(name: trimmed, resuming: pending)
                try await commands.acknowledgeCreation(created)
                onCreated(created.selected)
            } catch { self.error = "Couldn’t create home. Try again." }
        }
    }
}

#Preview {
    let bootstrap = PersistenceBootstrap(preloadedPreviewEnvironment: try! ShoppingPreviewFixtures.make(.populated))
    HomeSelectionView(bootstrap: bootstrap).environmentObject(bootstrap)
}
