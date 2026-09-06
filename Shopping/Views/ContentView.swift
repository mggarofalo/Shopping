import SwiftUI

struct ContentView: View {
    @StateObject private var navigation = GroceryNavigationState()

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            GroceriesView(navigation: navigation)
                .tabItem { Label("Groceries", systemImage: "cart") }
                .tag(GroceryNavigationState.Tab.groceries)
            CatalogView()
                .tabItem { Label("Catalog", systemImage: "books.vertical") }
                .tag(GroceryNavigationState.Tab.catalog)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(GroceryNavigationState.Tab.settings)
        }
        .tint(.groceryAccent)
    }
}

#Preview("Populated grocery environment") {
    ShoppingPreviewHost(.populated) { ContentView() }
}

#Preview("Empty grocery environment") {
    ShoppingPreviewHost(.empty) { ContentView() }
}

#Preview("Large text · Accessibility") {
    ShoppingPreviewHost(.largeText) {
        ContentView().environment(\.dynamicTypeSize, .accessibility3)
    }
}
