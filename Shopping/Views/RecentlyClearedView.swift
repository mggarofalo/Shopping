import CoreData
import SwiftUI

struct RecentlyClearedView: View {
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.shoppingToastCenter) private var toastCenter
    @FetchRequest(fetchRequest: NavigationFetchRequests.clearOperations()) private var operations: FetchedResults<ClearOperation>
    @FetchRequest(fetchRequest: NavigationFetchRequests.lists()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @State private var error: Error?

    var body: some View {
        let canonicalList = GroceryRowScope.canonicalList(
            Array(lists), households: Array(households), selection: selection
        )
        let scopedOperations = GroceryRowScope.validClearOperations(
            Array(operations), canonicalList: canonicalList
        )
        Group {
            if scopedOperations.isEmpty {
                ContentUnavailableView(
                    "Nothing recently cleared",
                    systemImage: "clock.arrow.circlepath"
                )
            } else {
                List {
                    Section {
                        ForEach(scopedOperations, id: \.objectID) { operation in
                            Button { restore(operation.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "arrow.uturn.backward.circle.fill")
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Restore cleared groceries")
                                            .foregroundStyle(.primary)
                                        Text(operation.createdAt, style: .relative)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("shopping.recovery.restore.\(operation.id.uuidString)")
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Recently cleared")
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
                toastCenter?.show(
                    "Nothing restored. These groceries were already restored or have newer changes.",
                    duration: .attention
                )
            } else if skipped > 0 {
                toastCenter?.show(
                    "Restored \(restored); skipped \(skipped) with newer changes.",
                    duration: .attention
                )
            } else {
                toastCenter?.show(
                    restored == 1 ? "Restored 1 item" : "Restored \(restored) items",
                    duration: .success
                )
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
