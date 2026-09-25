import CoreData
import SwiftUI
import UIKit

private struct GroceryTitleAlignment: AlignmentID {
    static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
        dimensions[VerticalAlignment.center]
    }
}

private extension VerticalAlignment {
    static let groceryTitle = VerticalAlignment(GroceryTitleAlignment.self)
}

struct GroceryNeedRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.hapticFeedback) private var hapticFeedback
    @FetchRequest(fetchRequest: NavigationFetchRequests.people()) private var people: FetchedResults<Person>
    @ObservedObject var need: Need
    let activeStores: [Store]
    let selectedStoreID: UUID?
    var personalCarted: Bool? = nil
    var presenceNames: [String] = []
    var onEdit: ((Need) -> Void)? = nil
    var onCartedChange: ((Need, Bool) -> Void)? = nil
    var onQuantityChange: ((Need, Int64?) -> Void)? = nil
    var onRemoved: ((UUID, UUID, UUID) -> Void)? = nil
    @State private var removalError: String?


    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .groceryTitle, spacing: 12))
        layout {
            detailsControl
            if storeIndicator != nil || need.quantity != nil {
                controls.fixedSize(horizontal: true, vertical: false)
                    .alignmentGuide(.groceryTitle) { $0[VerticalAlignment.center] }
                    .frame(
                        maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                        alignment: .trailing
                    )
                    .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 12 : 0)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let onCartedChange {
                Button {
                    onCartedChange(need, !(personalCarted ?? need.carted))
                } label: {
                    Label(cartActionTitle, systemImage: cartActionSymbol).labelStyle(.iconOnly)
                }
                .tint((personalCarted ?? need.carted) ? .orange : .blue)
                .accessibilityIdentifier("shopping.checklist.cart.\(need.id.uuidString)")
            }
            if onRemoved != nil {
                // The cart action remains first, so a full swipe still carts/uncarts.
                Button(action: remove) {
                    Label("Remove", systemImage: "trash").labelStyle(.iconOnly)
                }
                .tint(.red)
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
        guard let service, onRemoved != nil, !need.archived,
              let householdID = selection.householdID, let listID = selection.listID,
              need.list?.household?.id == householdID, need.list?.id == listID else { return }
        let needID = need.id
        let revision = need.revision
        do {
            let operationID = try service.removeNeed(
                needID: needID, householdID: householdID,
                listID: listID, expectedRevision: revision
            )
            onRemoved?(operationID, householdID, listID)
            hapticFeedback.play(.warning)
        } catch { removalError = error.localizedDescription }
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

    private var controls: some View {
        HStack(spacing: 4) {
            if let storeIndicator {
                Image(systemName: storeIndicator.symbol)
                    .imageScale(.small)
                    .foregroundStyle(Color.grocerySecondary)
                    .frame(width: 20)
                    // The row's accessibility value already announces this rule.
                    .accessibilityHidden(true)
            }
            if let quantity = need.quantity {
                if let onQuantityChange {
                    quantityButton("minus", quantity: quantity, change: -1, action: onQuantityChange)
                    Text("\(quantity)")
                        .monospacedDigit()
                        .fixedSize()
                        .foregroundStyle(Color.grocerySecondary)
                        .accessibilityLabel("Quantity \(quantity)")
                        .accessibilityIdentifier("shopping.checklist.quantity.value.\(need.id.uuidString)")
                    quantityButton("plus", quantity: quantity, change: 1, action: onQuantityChange)
                } else {
                    Text("\(quantity)").foregroundStyle(Color.grocerySecondary)
                        .accessibilityLabel("Quantity \(quantity)")
                        .accessibilityIdentifier("shopping.checklist.quantity.value.\(need.id.uuidString)")
                }
            }
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

    private func quantityButton(
        _ symbol: String, quantity: Int64, change: Int64, action: @escaping (Need, Int64?) -> Void
    ) -> some View {
        Button {
            action(need, quantity + change)
        } label: {
            Image(systemName: symbol).frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .disabled(change < 0 ? quantity <= 1 : quantity >= 99)
        .accessibilityLabel("\(change < 0 ? "Decrease" : "Increase") quantity for \(title)")
        .accessibilityIdentifier(
            "shopping.checklist.quantity.\(change < 0 ? "decrease" : "increase").\(need.id.uuidString)")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
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
            .alignmentGuide(.groceryTitle) { $0[VerticalAlignment.center] }
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
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
        if let personLabel { values.append("For \(personLabel)") }
        if !need.notes.isEmpty { values.append(need.notes) }
        return values.joined(separator: ", ")
    }

}
