import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Your grocery list",
                systemImage: "cart",
                description: Text("One place for your household’s groceries.")
            )
            .accessibilityIdentifier("shopping.emptyState")
            .navigationTitle("Groceries")
        }
    }
}

#Preview("Populated grocery environment") {
    ShoppingPreviewHost(.populated) {
        ContentView()
    }
}

#Preview("Empty grocery environment") {
    ShoppingPreviewHost(.empty) {
        ContentView()
    }
}

#Preview("Large text · Accessibility") {
    ShoppingPreviewHost(.largeText) {
        ContentView()
            .environment(\.dynamicTypeSize, .accessibility3)
    }
}
