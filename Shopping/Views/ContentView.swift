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

#Preview {
    ContentView()
}
