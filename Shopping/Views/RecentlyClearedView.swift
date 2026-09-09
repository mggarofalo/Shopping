import CoreData
import SwiftUI
import UIKit

struct RecentlyClearedView: View {
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.clearOperations()) private var operations: FetchedResults<ClearOperation>
    @FetchRequest(fetchRequest: NavigationFetchRequests.lists()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @State private var error: Error?
    @State private var restoreMessage: String?

    var body: some View {
        let canonicalList = GroceryRowScope.canonicalList(
            Array(lists), households: Array(households), selection: selection
        )
        let scopedOperations = GroceryRowScope.validClearOperations(
            Array(operations), canonicalList: canonicalList
        )
        List {
            ForEach(scopedOperations, id: \.objectID) { operation in
                VStack(alignment: .leading) {
                    Text(operation.createdAt, style: .relative)
                    Button("Restore cleared groceries") { restore(operation.id) }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("shopping.recovery.restore.\(operation.id.uuidString)")
                }
                .shoppingListRowInsets()
            }
        }
        .overlay { if scopedOperations.isEmpty { ContentUnavailableView("Nothing recently cleared", systemImage: "clock.arrow.circlepath") } }
        .navigationTitle("Recently cleared")
        .safeAreaInset(edge: .bottom) {
            if let restoreMessage {
                ShoppingFeedbackBar(message: restoreMessage)
            }
        }
        .alert("Couldn’t restore groceries", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error?.localizedDescription ?? "Unknown error") }
    }

    private func restore(_ operationID: UUID) {
        guard let service,
              let list = GroceryRowScope.canonicalList(
                Array(lists), households: Array(households), selection: selection
              ),
              let householdID = list.household?.id else {
            error = GroceryAddError.householdUnavailable
            return
        }
        do {
            let expected = operationExpectedRestoreCount(operationID)
            let restored = try service.undoClear(
                operationID: operationID,
                expectedHouseholdID: householdID,
                expectedListID: list.id
            )
            let skipped = max(0, expected - restored)
            if restored == 0 {
                restoreMessage = "Nothing restored. These groceries were already restored or have newer changes."
            } else if skipped > 0 {
                restoreMessage = "Restored \(restored); skipped \(skipped) with newer changes."
            } else {
                restoreMessage = restored == 1 ? "Restored 1 item" : "Restored \(restored) items"
            }
        } catch { self.error = error }
    }

    private func operationExpectedRestoreCount(_ operationID: UUID) -> Int {
        guard let operation = operations.first(where: { $0.id == operationID }),
              let snapshot = operation.snapshot,
              let token = try? JSONDecoder().decode(ClearCartedToken.self, from: snapshot) else { return 0 }
        return token.revisionsByNeedID.count
    }
}

#Preview("Groceries") { ShoppingPreviewHost(.populated) { GroceriesView(navigation: GroceryNavigationState()) } }
#Preview("Settings") { ShoppingPreviewHost(.archivedStore) { SettingsView() } }
