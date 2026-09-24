import SwiftUI

struct PersonalRetainedCartsView: View {
    let service: PersonalCartService
    @State private var scopes: [PersonalCartScopeSnapshot] = []
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
                        Text(summary(scope)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
        }
        .navigationTitle("Saved carts")
        .onAppear {
            do { scopes = try service.retainedScopes() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func summary(_ scope: PersonalCartScopeSnapshot) -> String {
        let entries = try? service.entries(householdID: scope.householdID, listID: scope.listID)
        let names = entries?.prefix(3).map(\.title) ?? []
        return names.isEmpty ? "Purchase history" : names.joined(separator: ", ")
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
