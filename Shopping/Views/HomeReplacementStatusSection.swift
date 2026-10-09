import SwiftUI

struct HomeReplacementStatusSection: View {
    @ObservedObject var bootstrap: PersistenceBootstrap
    let record: HomeReplacementRecord
    @State private var isWorking = false
    @State private var error: String?
    @State private var reviewing = false

    private var status: String {
        switch record.stage {
        case .completed: "\(record.proposal.source.name) was replaced."
        case .sourceKept: "\(record.proposal.source.name) was kept."
        default: "Starter Home replacement needs attention."
        }
    }

    var body: some View {
        Section("Starter Home replacement") {
            Text(status).accessibilityIdentifier("shopping.replacement.status")
            if !record.isTerminal {
                Text("Your joined Home remains available. Review the original Home before continuing removal.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Review Again") { reviewing = true }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("shopping.replacement.review")
                Button("Keep \(record.proposal.source.name)") {
                    perform { try await bootstrap.homeEntryCommands.keepStarter(record.id) }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("shopping.replacement.keepStarter")
            }
            if isWorking { ProgressView() }
            if let error { Text(error).foregroundStyle(.secondary) }
        }
        .disabled(isWorking || bootstrap.replacementInProgress != nil)
        .alert("Remove empty “\(record.proposal.source.name)”?", isPresented: $reviewing) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Starter Home", role: .destructive) {
                perform { try await bootstrap.homeEntryCommands.reviewReplacement(record.id) }
            }
        } message: {
            Text("Rechecks this starter and the joined Home before continuing removal. Completed removal cannot be undone.")
        }
        .onChange(of: bootstrap.replacementStatus?.id) { _, id in
            if id != record.id { reviewing = false }
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do { try await action(); error = nil }
            catch { self.error = "Couldn’t finish. Keep your Homes and check again." }
        }
    }
}

#Preview {
    List {
        HomeReplacementStatusSection(bootstrap: PersistenceBootstrap(),
            record: HomeReplacementRecord(proposal: HomeReplacementPreview.proposal, stage: .sourceKept))
    }
}
