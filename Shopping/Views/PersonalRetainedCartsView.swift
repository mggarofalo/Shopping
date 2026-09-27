import SwiftUI

struct PersonalRetainedCartsView: View {
    let service: PersonalCartService
    @State private var scopes: [PersonalCartScopeSnapshot] = []
    @State private var summaries: [PersonalCartScopeSnapshot: String] = [:]
    @State private var error: String?

    var body: some View {
        List {
            Text("Saved personal carts and purchases remain yours even when a household is unavailable.")
                .foregroundStyle(.secondary)
            ForEach(scopes.indices, id: \.self) { index in
                let scope = scopes[index]
                NavigationLink {
                    RetainedCartDetail(service: service, scope: scope)
                } label: {
                    VStack(alignment: .leading) {
                        Text("Saved personal cart")
                        Text(summaries[scope] ?? "Purchase history").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Saved carts")
        .task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { () throws ->
                    ([PersonalCartScopeSnapshot], [PersonalCartScopeSnapshot: String]) in
                    let scopes = try service.retainedScopes()
                    let summaries = Dictionary(uniqueKeysWithValues: try scopes.map { scope in
                        let entries = try service.entries(householdID: scope.householdID, listID: scope.listID)
                        let names = entries.prefix(3).map(\.title)
                        return (scope, names.isEmpty ? "Purchase history" : names.joined(separator: ", "))
                    })
                    return (scopes, summaries)
                }.value
                guard !Task.isCancelled else { return }
                scopes = loaded.0
                summaries = loaded.1
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct RetainedCartDetail: View {
    let service: PersonalCartService
    let scope: PersonalCartScopeSnapshot
    @State private var cart: PersonalCartPresentation?

    var body: some View {
        Group {
            if let cart {
                PersonalCartView(cart: cart, navigation: GroceryNavigationState())
                    .toolbar {
                        NavigationLink("My purchases") { PersonalPurchaseHistoryView(cart: cart) }
                    }
            } else { ProgressView("Opening saved cart…") }
        }
        .task {
            cart = PersonalCartPresentation(service: service, householdID: scope.householdID, listID: scope.listID)
        }
    }
}

#if DEBUG
#Preview { PersonalCartPreviewHost { cart in NavigationStack { PersonalRetainedCartsView(service: cart.service) } } }
#endif
