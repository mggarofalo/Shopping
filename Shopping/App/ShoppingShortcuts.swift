import AppIntents

struct ShoppingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddGroceryIntent(), phrases: [
            "Add an item in \(.applicationName)",
            "Add to my grocery list in \(.applicationName)"
        ], shortTitle: "Add item", systemImageName: "plus")
        AppShortcut(intent: SearchCatalogIntent(), phrases: [
            "Search my catalog in \(.applicationName)",
            "Open the catalog in \(.applicationName)"
        ], shortTitle: "Search catalog", systemImageName: "magnifyingglass")
    }
}
