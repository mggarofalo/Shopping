import CoreData
import SwiftUI

struct PersonalCartView: View {
    let cart: PersonalCartPresentation
    @ObservedObject var navigation: GroceryNavigationState
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories: FetchedResults<Category>
    @State private var selected: PersonalCartEntrySnapshot?
    @State private var checkout: PersonalCheckoutSheet?
    @State private var error: String?

    private var visibleEntries: [PersonalCartEntrySnapshot] {
        let activeIDs = Set(stores.filter { !$0.isArchived && $0.household?.id == cart.householdID }.map(\.id))
        let filter = PurchaseFilter(selectedStoreID: navigation.selectedStoreID,
            includedStoreIDs: navigation.includedStoreIDs, excludedStoreIDs: navigation.excludedStoreIDs)
        return cart.visibleEntries(filter: GroceryNeedFilter(purchase: filter, text: navigation.searchText,
            categoryID: navigation.categoryID, urgency: navigation.urgentOnly ? NeedUrgency.urgent.rawValue : nil),
            activeStoreIDs: activeIDs)
    }

    private var sections: [ItemCollectionSection<String, PersonalCartEntrySnapshot>] {
        let scoped = categories.filter { $0.household?.id == cart.householdID }
        let settingsOrder = CategoryGrouping.ordered(Array(scoped), household: scoped.first?.household)
        let ordered = settingsOrder.filter { !$0.isArchived } + settingsOrder.filter(\.isArchived)
        var remaining = visibleEntries
        var result: [ItemCollectionSection<String, PersonalCartEntrySnapshot>] = []
        for category in ordered {
            let entries = remaining.filter { $0.categoryID == category.id }
            if !entries.isEmpty { result.append(.init(id: category.id.uuidString, title: category.name, items: sorted(entries))) }
            remaining.removeAll { $0.categoryID == category.id }
        }
        for key in Set(remaining.map { $0.categoryID?.uuidString ?? "uncategorized" }).sorted() {
            let entries = remaining.filter { ($0.categoryID?.uuidString ?? "uncategorized") == key }
            result.append(.init(id: key, title: entries.first?.categoryName ?? "Uncategorized", items: sorted(entries)))
        }
        return result
    }

    var body: some View {
        List {
            if let message = cart.error { Text(message).foregroundStyle(.secondary) }
            if visibleEntries.isEmpty { Text("Your cart is empty in this view").foregroundStyle(.secondary) }
            CompactGrocerySections(sections: sections, itemID: \.id) { _, entry in
                Button { selected = entry } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.title).foregroundStyle(Color.primary)
                            Spacer()
                            if let quantity = entry.quantity {
                                Text("\(quantity)").foregroundStyle(Color.secondary).fixedSize()
                            }
                        }
                        if !entry.notes.isEmpty {
                            Text(entry.notes).font(.caption).foregroundStyle(Color.grocerySecondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12)
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("shopping.personalCart.item.\(entry.needID.uuidString)")
                .swipeActions {
                    Button("Remove from cart", systemImage: "cart.badge.minus") { remove(entry) }
                        .tint(.orange)
                }
                .accessibilityAction(named: "Remove from cart") { remove(entry) }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.custom(8))
        .navigationTitle("My cart")
        .safeAreaInset(edge: .bottom) {
            Button("Check out") { prepare(visibleEntries) }
                .buttonStyle(.borderedProminent)
                .disabled(visibleEntries.isEmpty || cart.error != nil)
                .padding(8)
        }
        .sheet(item: $selected) { entry in
            PersonalCartItemView(cart: cart, entry: entry, storeID: navigation.selectedStoreID,
                storeName: stores.first { $0.id == navigation.selectedStoreID }?.name)
        }
        .sheet(item: $checkout) { sheet in
            PersonalCheckoutView(cart: cart, token: sheet.token, storeName: sheet.storeName)
        }
        .onAppear { cart.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave).receive(on: RunLoop.main)) { _ in cart.refresh() }
        .alert("Couldn’t update cart", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func sorted(_ entries: [PersonalCartEntrySnapshot]) -> [PersonalCartEntrySnapshot] {
        entries.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }

    private func remove(_ entry: PersonalCartEntrySnapshot) {
        do { try cart.uncart(entry) } catch { self.error = error.localizedDescription }
    }

    private func prepare(_ entries: [PersonalCartEntrySnapshot]) {
        do {
            checkout = PersonalCheckoutSheet(token: try cart.service.prepareCheckout(
                tokens: entries.map(\.token), storeID: navigation.selectedStoreID),
                storeName: stores.first { $0.id == navigation.selectedStoreID }?.name)
        } catch { self.error = error.localizedDescription }
    }
}

struct PersonalCheckoutSheet: Identifiable {
    let token: PersonalCheckoutToken
    var storeName: String? = nil
    var id: UUID { token.id }
}

#if DEBUG
#Preview { PersonalCartPreviewHost { cart in NavigationStack { PersonalCartView(cart: cart, navigation: GroceryNavigationState()) } } }
#endif
