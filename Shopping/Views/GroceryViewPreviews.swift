import CoreData
import SwiftUI
import UIKit

extension Color {
    static let grocerySecondary = Color(UIColor { traits in
        UIColor(white: traits.userInterfaceStyle == .dark ? 0.75 : 0.35, alpha: 1)
    })

    static let groceryUrgent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.95, green: 0.58, blue: 0.30, alpha: 1)
            : UIColor(red: 0.60, green: 0.20, blue: 0.07, alpha: 1)
    })

    static let groceryAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.35, green: 0.72, blue: 0.55, alpha: 1)
            : UIColor(red: 0.10, green: 0.32, blue: 0.23, alpha: 1)
    })
}

private struct AddGroceryPreview: View {
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>

    var body: some View {
        let store = stores.first { $0.name == "Costco" && !$0.isArchived }
        OneTimeGrocerySheet(
            scope: GroceryAddScope(
                householdID: selection.householdID,
                listID: selection.listID,
                selectedStoreID: store?.id,
                selectedStoreName: store?.name
            ),
            onSaved: {}
        )
    }
}

private struct GroceryFiltersPreview: View {
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: NavigationFetchRequests.categories()) private var categories: FetchedResults<Category>
    @StateObject private var navigation = GroceryNavigationState()

    var body: some View {
        GroceryFiltersView(
            navigation: navigation,
            stores: stores.filter { $0.household?.id == selection.householdID && !$0.isArchived },
            categories: categories.filter { $0.household?.id == selection.householdID },
            onReset: { navigation.resetFilters() }
        )
    }
}

#Preview("Add one-time item · Costco") { ShoppingPreviewHost(.populated) { AddGroceryPreview() } }
#Preview("Add one-time item · unavailable") {
    OneTimeGrocerySheet(
        scope: GroceryAddScope(householdID: nil, listID: nil, selectedStoreID: nil, selectedStoreName: nil),
        onSaved: {}
    )
}
#Preview("Grocery filters") { ShoppingPreviewHost(.populated) { GroceryFiltersPreview() } }
#Preview("Groceries in cart") { ShoppingPreviewHost(.populated) { NavigationStack { CartedGroceriesView() } } }
#Preview("Recently cleared") { ShoppingPreviewHost(.populated) { NavigationStack { RecentlyClearedView() } } }
