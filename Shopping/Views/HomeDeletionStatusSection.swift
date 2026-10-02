import SwiftUI

/// Durable deletion evidence remains available after the home itself disappears.
struct HomeDeletionStatusSection: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    @State private var checkingID: UUID?
    @State private var isRefreshing = false
    @State private var actionError: String?

    var body: some View {
        Section("Home deletion") {
            ForEach(bootstrap.homeDeletionStatuses.filter(\.requiresResolution), id: \.command.id) { status in
                VStack(alignment: .leading, spacing: 6) {
                    Text(status.command.homeName).font(.headline)
                    Text(status.submitted ? "Deleting…" : "Deletion needs attention")
                        .accessibilityIdentifier("shopping.home.deletionStatus." + status.command.id.uuidString)
                    Button("Check Again") { check(status.command) }
                        .disabled(checkingID != nil || isRefreshing)
                        .frame(minHeight: 44, alignment: .leading)
                        .accessibilityIdentifier("shopping.home.checkDeletion." + status.command.id.uuidString)
                }
            }
            if bootstrap.homeDeletionStatuses.allSatisfy({ !$0.requiresResolution }),
               bootstrap.homeDeletionStatusError != nil {
                Button("Check Again") { refresh() }
                    .disabled(isRefreshing || checkingID != nil)
                    .accessibilityIdentifier("shopping.home.checkDeletionStatus")
            }
            if checkingID != nil || isRefreshing {
                ProgressView("Checking deletion…")
                    .accessibilityIdentifier("shopping.home.checkingDeletion")
            }
            if let error = actionError ?? bootstrap.homeDeletionStatusError {
                Text(error).foregroundStyle(.red)
                    .accessibilityIdentifier("shopping.home.deletionError")
            }
        }
    }

    private func check(_ command: HomeDeletionCommand) {
        guard checkingID == nil, !isRefreshing else { return }
        checkingID = command.id
        actionError = nil
        Task {
            defer { checkingID = nil }
            do { try await bootstrap.retryHomeDeletion(command) }
            catch { actionError = "Couldn’t check deletion. Try again." }
        }
    }

    private func refresh() {
        guard checkingID == nil, !isRefreshing else { return }
        isRefreshing = true
        actionError = nil
        Task {
            defer { isRefreshing = false }
            await bootstrap.refreshHomeDeletionStatuses()
        }
    }
}

#Preview {
    NavigationStack {
        List {
            HomeDeletionStatusSection(bootstrap: PersistenceBootstrap(
                preloadedPreviewEnvironment: try! ShoppingPreviewFixtures.make(.populated)))
        }
    }
}
