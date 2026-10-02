import SwiftUI

private struct SavedCartRow: Identifiable, Sendable {
    let home: SavedCartHomeDisplay
    let summary: String
    var id: PersonalCartScopeSnapshot { home.scope }
}

struct PersonalRetainedCartsView: View {
    let service: PersonalCartService
    var includedScopes: [PersonalCartScopeSnapshot]? = nil
    @State private var rows: [SavedCartRow] = []
    @State private var error: String?

    var body: some View {
        List {
            ForEach(rows) { row in
                NavigationLink {
                    RetainedCartDetail(service: service, home: row.home)
                } label: {
                    VStack(alignment: .leading) {
                        Label(row.home.displayName, systemImage: "cart")
                        Text(row.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Saved personal cart, \(row.home.displayName), \(row.summary)")
            }
            if let error { Text(error).foregroundStyle(.secondary) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Saved carts")
        .task {
            do {
                let includedScopes = includedScopes
                let loaded = try await Task.detached(priority: .userInitiated) { () async throws -> [SavedCartRow] in
                    let scopes = try service.retainedScopes().filter { includedScopes?.contains($0) ?? true }
                    let homes = try await service.savedCartHomeDisplays(for: scopes)
                    let byScope = Dictionary(uniqueKeysWithValues: homes.map { ($0.scope, $0) })
                    return try scopes.map { scope in
                        let entries = try service.entries(householdID: scope.householdID, listID: scope.listID)
                        let names = entries.prefix(3).map(\.title)
                        return SavedCartRow(home: byScope[scope] ?? .unknown(scope),
                            summary: names.isEmpty ? "Purchase history" : names.joined(separator: ", "))
                    }
                }.value
                guard !Task.isCancelled else { return }
                rows = loaded
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct RetainedCartDetail: View {
    let service: PersonalCartService
    let home: SavedCartHomeDisplay
    @State private var cart: PersonalCartPresentation?

    var body: some View {
        Group {
            if let cart {
                PersonalCartView(cart: cart, navigation: GroceryNavigationState(), savedHome: home)
                    .toolbar {
                        NavigationLink("My purchases") { PersonalPurchaseHistoryView(cart: cart) }
                    }
            } else { ProgressView("Opening saved cart…") }
        }
        .task {
            cart = PersonalCartPresentation(service: service, householdID: home.scope.householdID,
                listID: home.scope.listID)
        }
    }
}

#if DEBUG
#Preview { PersonalCartPreviewHost { cart in NavigationStack { PersonalRetainedCartsView(service: cart.service) } } }
#endif
