import CoreData
import SwiftUI
import UIKit

struct GroceryNeedRow: View {
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.hapticFeedback) private var hapticFeedback
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FetchRequest(fetchRequest: NavigationFetchRequests.people()) private var people: FetchedResults<Person>
    @ObservedObject var need: Need
    let activeStores: [Store]
    let selectedStoreID: UUID?
    var personalCarted: Bool? = nil
    var presenceNames: [String] = []
    var cartActionAvailable = true
    var quantityActionAvailable = true
    var onEdit: ((Need) -> Void)? = nil
    var onCartedChange: ((Need, Bool) -> Void)? = nil
    var onQuantityChange: ((Need, Int64?) -> Void)? = nil
    var onRemoved: ((UUID, UUID, UUID) -> Void)? = nil
    @State private var removalError: String?
    @State private var removalPending = false
    @State private var quantityPresentation: QuantityPresentation?

    private struct QuantityPresentation: Identifiable {
        let id = UUID()
        let quantity: Int64?
        let revision: Int64
    }


    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    detailsControl
                    HStack(alignment: .top, spacing: 8) {
                        supportingDetailsControl
                        quantityControl
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    detailsControl
                    quantityControl
                }
            }
        }
        .shoppingItemRow()
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let onCartedChange {
                Button {
                    onCartedChange(need, !(personalCarted ?? need.carted))
                } label: {
                    Label(cartActionTitle, systemImage: cartActionSymbol).labelStyle(.iconOnly)
                }
                .tint((personalCarted ?? need.carted) ? .orange : .groceryAccent)
                .disabled(!cartActionAvailable)
                .accessibilityIdentifier("shopping.checklist.cart.\(need.id.uuidString)")
            }
            if onRemoved != nil {
                // The cart action remains first, so a full swipe still carts/uncarts.
                Button(action: remove) {
                    Label("Remove", systemImage: "trash").labelStyle(.iconOnly)
                }
                .tint(.red)
                .disabled(removalPending)
                .accessibilityIdentifier("shopping.checklist.remove.\(need.id.uuidString)")
            }
        }
        .accessibilityAction(named: Text(cartActionAccessibilityTitle)) {
            onCartedChange?(need, !(personalCarted ?? need.carted))
        }
        .accessibilityActions {
            if onRemoved != nil {
                Button("Remove \(title)", action: remove)
            }
        }
        .alert("Couldn’t remove item", isPresented: Binding(
            get: { removalError != nil }, set: { if !$0 { removalError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(removalError ?? "") }
    }

    private func remove() {
        guard !removalPending, let service, onRemoved != nil, !need.archived,
              let householdID = selection.householdID, let listID = selection.listID,
              need.list?.household?.id == householdID, need.list?.id == listID else { return }
        let needID = need.id
        let revision = need.revision
        removalPending = true
        Task {
            defer { removalPending = false }
            do {
                let operationID = try await Task.detached(priority: .userInitiated) {
                    try service.removeNeed(needID: needID, householdID: householdID,
                        listID: listID, expectedRevision: revision)
                }.value
                onRemoved?(operationID, householdID, listID)
                hapticFeedback.play(.warning)
            } catch { removalError = error.localizedDescription }
        }
    }

    @ViewBuilder
    private var detailsControl: some View {
        if let onEdit {
            Button {
                onEdit(need)
            } label: {
                details
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(title)")
            .accessibilityValue(accessibilityDetails + (presenceNames.isEmpty ? "" : ", In cart: " + presenceNames.joined(separator: ", ")))
            .accessibilityIdentifier("shopping.grocery.row.\(need.id.uuidString)")
        } else {
            details
                .accessibilityLabel(title)
                .accessibilityValue(accessibilityDetails + (presenceNames.isEmpty ? "" : ", In cart: " + presenceNames.joined(separator: ", ")))
        }
    }

    @ViewBuilder
    private var quantityControl: some View {
        if let quantity = need.quantity {
            if let onQuantityChange {
                Button {
                    quantityPresentation = QuantityPresentation(quantity: need.quantity, revision: need.revision)
                } label: {
                    Text("\(quantity)×")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                    .fixedSize()
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!quantityActionAvailable)
                .accessibilityLabel("Edit quantity for \(title)")
                .accessibilityValue("\(quantity)")
                .accessibilityIdentifier("shopping.checklist.quantity.edit.\(need.id.uuidString)")
                .sheet(item: $quantityPresentation) { presentation in
                    ShoppingQuantityEditor(itemName: title, quantity: presentation.quantity,
                                           actionAvailable: quantityActionAvailable,
                                           itemChanged: need.revision != presentation.revision) {
                        guard quantityActionAvailable, need.revision == presentation.revision else { return }
                        onQuantityChange(need, $0)
                    }
                }
            } else {
                Text("\(quantity)×").foregroundStyle(Color.grocerySecondary)
                    .accessibilityLabel("Quantity \(quantity)")
                    .accessibilityIdentifier("shopping.checklist.quantity.value.\(need.id.uuidString)")
            }
        }
    }

    private var storeMetadata: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let storeIndicator {
                Image(systemName: storeIndicator.symbol)
                    .imageScale(.small)
                    .foregroundStyle(Color.grocerySecondary)
                    .accessibilityHidden(true)
            }
            ShoppingItemStoreSummary(anyStore: anyStore, storeLabels: storeLabels,
                hasSavedStores: !assignedStores.isEmpty,
                hasResolvedIdentity: need.kind == NeedKind.oneTime.rawValue || need.item != nil,
                alignment: .leading)
                .accessibilityHidden(true)
        }
    }

    private var cartActionTitle: String {
        (personalCarted ?? need.carted) ? "Remove from cart" : "In cart"
    }

    private var cartActionSymbol: String {
        (personalCarted ?? need.carted) ? "cart.badge.minus" : "cart.fill"
    }

    private var cartActionAccessibilityTitle: String {
        "\(cartActionTitle) \(title)"
    }

    private var titleDetails: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            titleWithAssignment
                .accessibilityLabel(title)
            if need.urgency == NeedUrgency.urgent.rawValue {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(Color.groceryUrgent)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var supportingDetailsControl: some View {
        if let onEdit {
            Button { onEdit(need) } label: { supportingDetails }
                .buttonStyle(.plain)
                // The name control already announces this complete summary.
                .accessibilityHidden(true)
        } else {
            supportingDetails.accessibilityHidden(true)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleDetails
            if !dynamicTypeSize.isAccessibilitySize { supportingDetails }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: ShoppingListMetrics.minimumRowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var supportingDetails: some View {
        VStack(alignment: .leading, spacing: 2) {
            storeMetadata
            if need.kind == NeedKind.oneTime.rawValue {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { metadataLabels }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 2) { metadataLabels }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if !need.notes.isEmpty { Text(need.notes).font(.caption).foregroundStyle(Color.grocerySecondary) }
            if !presenceNames.isEmpty {
                Text("In cart: " + presenceNames.joined(separator: ", "))
                    .font(.caption).foregroundStyle(Color.grocerySecondary)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var metadataLabels: some View {
        if need.kind == NeedKind.oneTime.rawValue {
            Label("One-time", systemImage: "1.circle")
                .labelStyle(.titleAndIcon)
                .font(.caption).foregroundStyle(Color.grocerySecondary)
        }

    }

    private var titleWithAssignment: Text {
        if let personLabel {
            return Text("\(Text(title).font(.body)) \(Text("(\(personLabel))").font(.caption).foregroundColor(Color.grocerySecondary))")
        }
        return Text(title).font(.body)
    }

    private var title: String { need.item?.name ?? need.title }

    private var assignedStores: Set<Store> {
        need.item?.stores ?? (need.kind == NeedKind.oneTime.rawValue ? need.oneTimeStores : nil) ?? []
    }

    private var anyStore: Bool {
        need.item?.anyStore ?? (need.kind == NeedKind.oneTime.rawValue && need.oneTimeAnyStore)
    }

    private var storeLabels: [String] {
        assignedStores.map { $0.isArchived ? "\($0.name) (archived)" : $0.name }.sorted()
    }

    private var storeSummary: String {
        CatalogSuggestionPurchaseSummary.text(anyStore: anyStore, savedStoreLabels: storeLabels,
            hasSavedStores: !assignedStores.isEmpty,
            hasResolvedIdentity: need.kind == NeedKind.oneTime.rawValue || need.item != nil)
    }

    private var storeIndicator: GroceryStoreScopeIndicator? {
        GroceryStoreScopeIndicator.value(
            for: need,
            selectedStoreID: selectedStoreID,
            activeStoreIDs: Set(activeStores.map(\.id))
        )
    }

    private var personLabel: String? {
        GroceryPersonLabel.text(
            for: need.person, people: Array(people), household: need.list?.household
        )
    }

    private var accessibilityDetails: String {
        var values: [String] = []
        if need.urgency == NeedUrgency.urgent.rawValue { values.append("Urgent") }
        if need.kind == NeedKind.oneTime.rawValue { values.append("One-time") }
        if (personalCarted ?? need.carted) { values.append("In cart") }
        if let storeIndicator { values.append(storeIndicator.title) }
        values.append(storeSummary)
        if let quantity = need.quantity { values.append("Quantity \(quantity)") }
        if let personLabel { values.append("For \(personLabel)") }
        if !need.notes.isEmpty { values.append(need.notes) }
        return values.joined(separator: ", ")
    }

}
