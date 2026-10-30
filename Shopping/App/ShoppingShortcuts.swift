import AppIntents

struct ShoppingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Unqualified list requests ("add milk to my shopping list") can reach any app that
        // adopts the Reminders schema, and iOS chooses or asks. An App Shortcut phrase names
        // this app, so it routes here without that choice (SHOPPING-266).
        AppShortcut(intent: AddGroceryIntent(), phrases: [
            "Add an item in \(.applicationName)",
            "Add an item to \(.applicationName)",
            "Add to my grocery list in \(.applicationName)",
            "Add to my shopping list in \(.applicationName)",
            "Add groceries in \(.applicationName)"
        ], shortTitle: "Add item", systemImageName: "plus")
        AppShortcut(intent: SearchCatalogIntent(), phrases: [
            "Search my catalog in \(.applicationName)",
            "Open the catalog in \(.applicationName)"
        ], shortTitle: "Search catalog", systemImageName: "magnifyingglass")
    }
}
