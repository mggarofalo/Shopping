import CoreData
import SwiftUI
import UIKit

/// Displays `model` only. The screen rebuilds the model when its data changes, so the row
/// doesn't observe the need and skips unchanged renders through `Equatable`.
struct GroceryNeedRow: View, Equatable {
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.hapticFeedback) private var hapticFeedback
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The need the row's commands act on.
    let need: Need
    let model: GroceryRowModel
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


#if DEBUG
    /// Records each body evaluation, so tests can prove unchanged rows are skipped.
    @MainActor static var renderedNeedIDs: [UUID] = []
#endif

    var body: some View {
#if DEBUG
        let _ = Self.renderedNeedIDs.append(model.needID)
#endif
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    detailsControl
                    if model.hasSupportingDetails || model.quantity != nil {
                        HStack(alignment: .top, spacing: 8) {
                            supportingDetailsControl
                            // This row already has its own line, so the hit region stays inside it.
                            quantityControl.frame(minHeight: ShoppingListMetrics.minimumRowHeight)
                        }
                        .padding(.bottom, ShoppingListMetrics.itemTextVerticalPadding)
                    }
                }
            } else {
                // The quantity aligns with the name's first line, however tall the row grows.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    detailsControl
                    quantityControl
                }
            }
        }
        .shoppingItemRow()
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let onCartedChange {
                Button {
                    onCartedChange(need, !model.isCarted)
                } label: {
                    Label(cartActionTitle, systemImage: cartActionSymbol).labelStyle(.iconOnly)
                }
                .tint(model.isCarted ? .orange : .groceryAccent)
                .disabled(!model.cartActionAvailable)
                .accessibilityIdentifier("shopping.checklist.cart.\(model.needID.uuidString)")
            }
            if onRemoved != nil {
                // The cart action remains first, so a full swipe still carts/uncarts.
                Button(action: remove) {
                    Label("Remove", systemImage: "trash").labelStyle(.iconOnly)
                }
                .tint(.red)
                .disabled(removalPending)
                .accessibilityIdentifier("shopping.checklist.remove.\(model.needID.uuidString)")
            }
        }
        .accessibilityAction(named: Text(cartActionAccessibilityTitle)) {
            onCartedChange?(need, !model.isCarted)
        }
        .accessibilityActions {
            if onRemoved != nil {
                Button("Remove \(model.title)", action: remove)
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
            .accessibilityLabel("Edit \(model.title)")
            .accessibilityValue(accessibilityValue)
            .accessibilityIdentifier("shopping.grocery.row.\(model.needID.uuidString)")
        } else {
            details
                .accessibilityLabel(model.title)
                .accessibilityValue(accessibilityValue)
        }
    }

    @ViewBuilder
    private var quantityControl: some View {
        if let quantity = model.quantity {
            if let onQuantityChange {
                // The 44-point hit region reaches into the row padding instead of growing the row.
                ShoppingRowAccessoryLayout {
                    Button {
                        quantityPresentation = QuantityPresentation(quantity: model.quantity, revision: model.revision)
                    } label: {
                        Text("\(quantity)×")
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .fixedSize()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.quantityActionAvailable)
                    .accessibilityLabel("Edit quantity for \(model.title)")
                    .accessibilityValue("\(quantity)")
                    .accessibilityIdentifier("shopping.checklist.quantity.edit.\(model.needID.uuidString)")
                }
                .sheet(item: $quantityPresentation) { presentation in
                    ShoppingQuantityEditor(itemName: model.title, quantity: presentation.quantity,
                                           actionAvailable: model.quantityActionAvailable,
                                           itemChanged: model.revision != presentation.revision) {
                        guard model.quantityActionAvailable, need.revision == presentation.revision else { return }
                        onQuantityChange(need, $0)
                    }
                }
            } else {
                Text("\(quantity)×").foregroundStyle(Color.grocerySecondary)
                    .accessibilityLabel("Quantity \(quantity)")
                    .accessibilityIdentifier("shopping.checklist.quantity.value.\(model.needID.uuidString)")
            }
        }
    }

    private var storeMetadata: ShoppingItemStoreSummary {
        ShoppingItemStoreSummary(anyStore: model.anyStore, storeLabels: model.storeLabels,
            hasSavedStores: model.hasSavedStores, hasResolvedIdentity: model.hasResolvedIdentity,
            symbol: model.storeIndicator?.symbol)
    }

    private var accessibilityValue: String {
        model.accessibilityDetails
            + (model.presenceNames.isEmpty ? "" : ", In cart: " + model.presenceNames.joined(separator: ", "))
    }

    private var cartActionTitle: String {
        model.isCarted ? "Remove from cart" : "In cart"
    }

    private var cartActionSymbol: String {
        model.isCarted ? "cart.badge.minus" : "cart.fill"
    }

    private var cartActionAccessibilityTitle: String {
        "\(cartActionTitle) \(model.title)"
    }

    private var titleDetails: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            titleWithAssignment
                .accessibilityLabel(model.title)
            if model.isUrgent {
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
        ShoppingItemRowContent(storeSummary: storeMetadata) {
            VStack(alignment: .leading, spacing: 2) {
                titleDetails
                if !dynamicTypeSize.isAccessibilitySize && model.hasSupportingDetails { supportingDetails }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: ShoppingListMetrics.minimumRowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var supportingDetails: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.isOneTime {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { metadataLabels }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 2) { metadataLabels }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if !model.notes.isEmpty { Text(model.notes).font(.caption).foregroundStyle(Color.grocerySecondary) }
            if !model.presenceNames.isEmpty {
                Text("In cart: " + model.presenceNames.joined(separator: ", "))
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
        if model.isOneTime {
            Label("One-time", systemImage: "1.circle")
                .labelStyle(.titleAndIcon)
                .font(.caption).foregroundStyle(Color.grocerySecondary)
        }

    }

    private var titleWithAssignment: Text {
        if let personLabel = model.personLabel {
            return Text("\(Text(model.title).font(.body)) \(Text("(\(personLabel))").font(.caption).foregroundColor(Color.grocerySecondary))")
        }
        return Text(model.title).font(.body)
    }

    /// Commands are the screen's methods and read its current state when invoked, so a row
    /// whose model is unchanged keeps those from an earlier render.
    static func == (lhs: GroceryNeedRow, rhs: GroceryNeedRow) -> Bool {
        lhs.need === rhs.need && lhs.model == rhs.model
    }
}
