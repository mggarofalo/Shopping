import SwiftUI

struct LocalHomeSettingsView: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    @Environment(\.dismiss) private var dismiss
    @State private var isConnecting = false
    @State private var presentedLocalStoreIdentifier: String?
    @State private var presentedLocalPresentationID: UUID?
    @State private var showingNameEditor = false
    @State private var name = ""
    @State private var isRenaming = false
    @State private var renameError: String?
    @State private var connectionError: String?
    @State private var deletionActions: HomeDetailsDeletionActions?
    @State private var deletionConfirmation: HomeDeletionCommand?
    @State private var deletionStatus: HomeDeletionStatus?
    @State private var deletionCommandToCheck: HomeDeletionCommand?
    @State private var deletionError: String?
    @State private var isDeleting = false

    private var isRetained: Bool { bootstrap.homeEntry.isShowingRetainedLocalHome }
    private var retainedCopyState: HomeEntrySnapshot.RetainedLocalCopyState {
        bootstrap.homeEntry.retainedLocalCopyState
    }
    private var opensICloudHomes: Bool {
        guard isRetained else { return false }
        switch retainedCopyState {
        case .copied, .unavailable: return true
        case .available, .copying: return false
        }
    }
    private var isCopyingRetainedHome: Bool {
        if case .copying = retainedCopyState { true } else { false }
    }
    private var openedAccountPresentationID: UUID? {
        guard let presentedLocalStoreIdentifier,
              case .ready(let ready) = bootstrap.state,
              ready.persistence.personalCartsEnabled,
              ready.persistence.primaryStore?.identifier != presentedLocalStoreIdentifier else { return nil }
        return ready.presentation.id
    }
    private var canRename: Bool {
        guard let presentedLocalPresentationID,
              case .ready(let ready) = bootstrap.state else { return false }
        return ready.presentation.id == presentedLocalPresentationID
            && ready.presentation.isActive && bootstrap.homeEntry.isLocalStore
    }

    var body: some View {
        List {
            Section("Home") {
                Button {
                    name = bootstrap.homeEntry.currentHomeName ?? ""
                    renameError = nil
                    showingNameEditor = true
                } label: {
                    LabeledContent("Name", value: bootstrap.homeEntry.currentHomeName ?? "Home")
                }
                .disabled(!canRename || isRenaming)
                .accessibilityIdentifier("shopping.home.rename")
                LabeledContent("Storage", value: "On This iPhone")
            }
            Section {
                Button(opensICloudHomes ? "Open iCloud Homes" : "Use iCloud",
                       systemImage: "icloud.and.arrow.up") {
                    if isRetained {
                        if opensICloudHomes { openICloudHomes() }
                        else { useICloudForRetainedHome() }
                    }
                    else { useICloudForLocalHome() }
                }
                .disabled(isConnecting || isCopyingRetainedHome)
                .accessibilityIdentifier(opensICloudHomes
                    ? "shopping.home.openICloud" : "shopping.home.useICloud")
                if isConnecting || isCopyingRetainedHome {
                    ProgressView("Copying home…")
                        .accessibilityIdentifier("shopping.home.copyingToICloud")
                }
            } footer: {
                Text(opensICloudHomes ? "Your home stays on this iPhone."
                    : "Copies this home to iCloud. Your local home stays saved.")
            }
            if let connectionError {
                Section { Text(connectionError).foregroundStyle(.red) }
            }
            if let error = bootstrap.homeSetupError {
                Section { Text(error.localizedDescription).foregroundStyle(.red) }
            }
            if deletionActions != nil {
                Section {
                    Button("Delete Home", role: .destructive) { Task { await prepareDeletion() } }
                        .disabled(isDeleting || deletionStatus != nil || deletionCommandToCheck != nil)
                        .accessibilityIdentifier("shopping.home.delete")
                }
            }
            if let deletionStatus, !deletionStatus.completed {
                Section {
                    Text(deletionStatus.submitted ? "Deleting home…" : "Deletion needs attention.")
                        .accessibilityIdentifier("shopping.home.deletionStatus")
                    Button("Check Deletion") { Task { await checkDeletion(deletionStatus.command) } }
                        .disabled(isDeleting)
                        .accessibilityIdentifier("shopping.home.checkDeletion")
                }
            } else if let deletionCommandToCheck {
                Section {
                    Button("Check Deletion") { Task { await checkDeletion(deletionCommandToCheck) } }
                        .disabled(isDeleting)
                        .accessibilityIdentifier("shopping.home.checkDeletion")
                }
            }
            if let deletionError {
                Section {
                    Text(deletionError).foregroundStyle(.red)
                        .accessibilityIdentifier("shopping.home.deletionError")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Home Settings")
        .task {
            if presentedLocalStoreIdentifier == nil, case .ready(let ready) = bootstrap.state,
               bootstrap.homeEntry.isLocalStore {
                presentedLocalStoreIdentifier = ready.persistence.primaryStore?.identifier
                presentedLocalPresentationID = ready.presentation.id
            }
            if deletionActions == nil { deletionActions = bootstrap.localHomeDeletionActions() }
        }
        .onChange(of: openedAccountPresentationID) { _, id in
            if id != nil { dismiss() }
        }
        .sheet(isPresented: $showingNameEditor) {
            VStack(spacing: 0) {
                ManagementNameEditor(title: "Rename home", name: $name, fieldTitle: "Home name",
                    fieldIdentifier: "shopping.home.nameEditor", saveLabel: "Save home name",
                    initiallyFocused: true,
                    unavailableMessage: "This home is not currently writable. Your draft is retained.",
                    available: canRename, busy: isRenaming,
                    onSave: { Task { await renameLocalHome() } },
                    onCancel: { showingNameEditor = false })
                if let renameError { Text(renameError).foregroundStyle(.red).padding() }
            }
        }
        .alert("Delete “\(deletionConfirmation?.homeName ?? bootstrap.homeEntry.currentHomeName ?? "Home")”?",
               isPresented: Binding(
                get: { deletionConfirmation != nil },
                // Confirmation owns a captured command until the button consumes it.
                set: { _ in }
               )) {
            if let command = deletionConfirmation {
                Button("Delete Home", role: .destructive) { Task { await confirmDeletion(command) } }
                    .accessibilityIdentifier("shopping.home.confirmDelete")
            }
            Button("Cancel", role: .cancel) { deletionConfirmation = nil }
                .accessibilityIdentifier("shopping.home.cancelDelete")
        } message: {
            Text("Deletes its list, catalog, and settings. This can’t be undone.")
        }
    }

    private func openICloudHomes() {
        guard !isConnecting else { return }
        isConnecting = true
        connectionError = nil
        Task {
            defer { isConnecting = false }
            do { try await bootstrap.homeEntryCommands.connectBackToAccount() }
            catch { connectionError = "Couldn’t open iCloud homes. Try again." }
        }
    }

    private func useICloudForRetainedHome() {
        guard !isConnecting, !isCopyingRetainedHome else { return }
        isConnecting = true
        connectionError = nil
        Task {
            defer { isConnecting = false }
            do { try await bootstrap.homeEntryCommands.useICloudForRetainedLocalHome() }
            catch { connectionError = "Couldn’t copy this home. Try again." }
        }
    }

    private func useICloudForLocalHome() {
        guard !isConnecting else { return }
        isConnecting = true
        connectionError = nil
        Task {
            defer { isConnecting = false }
            do { try await bootstrap.homeEntryCommands.useICloudForLocalHome() }
            catch { connectionError = "Couldn’t copy this home. Try again." }
        }
    }

    private func renameLocalHome() async {
        guard !isRenaming, canRename, let presentedLocalPresentationID else { return }
        isRenaming = true
        renameError = nil
        defer { isRenaming = false }
        do {
            try await bootstrap.renameLocalHome(name: name, presentedBy: presentedLocalPresentationID)
            showingNameEditor = false
        } catch { renameError = "Couldn’t rename home. Try again." }
    }

    private func prepareDeletion() async {
        guard !isDeleting, deletionStatus == nil, deletionCommandToCheck == nil,
              let deletionActions else { return }
        isDeleting = true
        deletionError = nil
        defer { isDeleting = false }
        do { deletionConfirmation = try await deletionActions.prepare() }
        catch { deletionError = "Couldn’t prepare deletion. Try again." }
    }

    private func confirmDeletion(_ command: HomeDeletionCommand) async {
        guard !isDeleting, deletionConfirmation == command, let deletionActions else { return }
        deletionConfirmation = nil
        deletionCommandToCheck = command
        isDeleting = true
        deletionError = nil
        defer { isDeleting = false }
        do {
            deletionStatus = try await deletionActions.confirm(command)
            deletionCommandToCheck = nil
        } catch {
            deletionError = "Couldn’t confirm deletion. Check status."
        }
    }

    private func checkDeletion(_ command: HomeDeletionCommand) async {
        guard !isDeleting, let deletionActions else { return }
        isDeleting = true
        deletionError = nil
        defer { isDeleting = false }
        do {
            deletionStatus = try await deletionActions.reconcile(command)
            deletionCommandToCheck = nil
        } catch {
            deletionError = "Couldn’t check deletion. Try again."
        }
    }
}

#Preview {
    let bootstrap = PersistenceBootstrap(preloadedPreviewEnvironment: try! ShoppingPreviewFixtures.make(.populated))
    NavigationStack { LocalHomeSettingsView(bootstrap: bootstrap) }
        .environmentObject(bootstrap)
}
