import CoreData
import SwiftUI

struct PillFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        let subviewProposal = ProposedViewSize(width: width.isFinite ? width : nil, height: nil)
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let measured = subview.sizeThatFits(subviewProposal)
            let size = CGSize(width: min(measured.width, width), height: measured.height)
            if rowWidth > 0 && rowWidth + spacing + size.width > width {
                contentWidth = max(contentWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth == 0 ? 0 : spacing) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        contentWidth = max(contentWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: proposal.width ?? contentWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let measured = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let size = CGSize(width: min(measured.width, bounds.width), height: measured.height)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct SelectionPill: View {
    let title: String
    let isSelected: Bool
    var systemImage: String? = nil
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                } else if isSelected {
                    Image(systemName: "checkmark")
                }
                Text(title)
            }
            .font(.subheadline)
            .fontWeight(isSelected ? .semibold : .regular)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? Color.groceryAccent.opacity(0.18) : Color.secondary.opacity(0.1))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.groceryAccent : Color.secondary.opacity(0.35))
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .applyAccessibilityIdentifier(identifier)
    }
}

private extension View {
    @ViewBuilder
    func applyAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

struct CategoryPills: View {
    @Binding var selection: UUID?
    let categories: [Category]
    var includeUnavailable = false
    var onAddCategory: (() -> Void)? = nil

    var body: some View {
        Section {
            PillFlowLayout {
                SelectionPill(
                    title: "Uncategorized",
                    isSelected: selection == nil,
                    identifier: "shopping.category.none"
                ) { selection = nil }
                ForEach(categories, id: \.objectID) { category in
                    SelectionPill(
                        title: category.name,
                        isSelected: selection == category.id,
                        identifier: "shopping.category.\(category.id.uuidString)"
                    ) { selection = category.id }
                }
                if includeUnavailable, let selection,
                   !categories.contains(where: { $0.id == selection }) {
                    SelectionPill(title: "Unavailable category", isSelected: true) {}
                        .disabled(true)
                }
                if let onAddCategory {
                    Button(action: onAddCategory) {
                        Label("Add category", systemImage: "plus")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("shopping.category.add")
                }
            }
        } header: {
            Text("Category")
        } footer: {
            Text("Categories group groceries across all stores.")
        }
    }
}

enum PurchaseRulesStoreScope {
    static func listsRequest() -> NSFetchRequest<GroceryList> {
        let request = GroceryList.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
        return request
    }

    static func validStores(
        _ stores: [Store],
        lists: [GroceryList],
        householdID: UUID?,
        listID: UUID?
    ) -> [Store] {
        guard let householdID, let listID,
              householdID != PersistenceModel.unsetID, listID != PersistenceModel.unsetID else { return [] }
        let matchingLists = lists.filter { $0.id == listID }
        guard matchingLists.count == 1, let household = matchingLists[0].household,
              household.id == householdID,
              let persistentStore = household.objectID.persistentStore,
              matchingLists[0].objectID.persistentStore == persistentStore else { return [] }
        let counts = Dictionary(grouping: stores, by: \.id).mapValues(\.count)
        return stores.filter {
            $0.id != PersistenceModel.unsetID && counts[$0.id] == 1 &&
                $0.household == household && $0.objectID.persistentStore == persistentStore
        }
    }
}

struct PurchaseRulesPicker: View {
    @Environment(\.persistenceSelection) private var selection
    @Binding var storeIDs: Set<UUID>
    @Binding var anyStore: Bool
    let householdID: UUID?
    let listID: UUID?
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: PurchaseRulesStoreScope.listsRequest()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>

    private var scopedListID: UUID? {
        listID ?? (selection.householdID == householdID ? selection.listID : nil)
    }

    private var validStores: [Store] {
        GroceryRowScope.validStores(Array(stores), canonicalList: canonicalList)
    }

    private var canonicalList: GroceryList? {
        guard selection.householdID == householdID, selection.listID == scopedListID else { return nil }
        return GroceryRowScope.canonicalList(Array(lists), households: Array(households), selection: selection)
    }

    var body: some View {
        Section("Where to buy") {
            PillFlowLayout {
                SelectionPill(
                    title: "Any store",
                    isSelected: anyStore,
                    identifier: "shopping.purchase.anyStore"
                ) { anyStore.toggle() }
                ForEach(validStores.filter { !$0.isArchived || storeIDs.contains($0.id) }, id: \.objectID) { store in
                    SelectionPill(
                        title: store.isArchived ? "\(store.name) · Archived" : store.name,
                        isSelected: storeIDs.contains(store.id),
                        identifier: "shopping.purchase.store.\(store.id.uuidString)"
                    ) {
                        if storeIDs.contains(store.id) { storeIDs.remove(store.id) }
                        else { storeIDs.insert(store.id) }
                    }
                }
            }
            if anyStore {
                Text("Can buy at any store, even when tagged.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            let unavailable = storeIDs.subtracting(Set(validStores.map(\.id)))
            if !unavailable.isEmpty {
                Text("Remove unavailable tags, then choose where to buy.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Remove unavailable tags", systemImage: "xmark.circle") {
                    storeIDs.subtract(unavailable)
                }
            }
            if !anyStore && storeIDs.isEmpty {
                Text("Choose a store or turn on Any store.").font(.footnote).foregroundStyle(.secondary)
            }
            if !anyStore && !storeIDs.isEmpty &&
                !validStores.contains(where: { !$0.isArchived && storeIDs.contains($0.id) }) {
                Text("Choose an active store or turn on Any store.").font(.footnote).foregroundStyle(.secondary)
            }
            NavigationLink {
                StoreCreationView(householdID: householdID, listID: scopedListID) { id in
                    storeIDs.insert(id)
                }
            } label: { Label("Add store", systemImage: "plus") }
                .accessibilityIdentifier("shopping.tags.addStore")
                .disabled(canonicalList == nil)
        }

    }
}

private struct StoreCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.needService) private var service
    @Environment(\.persistenceSelection) private var selection
    @FetchRequest(fetchRequest: NavigationFetchRequests.stores()) private var stores: FetchedResults<Store>
    @FetchRequest(fetchRequest: PurchaseRulesStoreScope.listsRequest()) private var lists: FetchedResults<GroceryList>
    @FetchRequest(fetchRequest: NavigationFetchRequests.households()) private var households: FetchedResults<Household>
    @State private var name = ""
    @State private var error: Error?
    @State private var capturedScope: StoreManagementCommandScope?
    @State private var didCaptureScope = false
    let householdID: UUID?
    let listID: UUID?
    let onSelected: (UUID) -> Void

    private var scopeAvailable: Bool {
        service != nil && StoreManagementScope.permits(capturedScope, canonicalList: canonicalList)
    }

    private var canonicalList: GroceryList? {
        guard householdID != nil, listID != nil,
            selection.householdID == householdID, selection.listID == listID else { return nil }
        return GroceryRowScope.canonicalList(Array(lists), households: Array(households), selection: selection)
    }

    private var matches: [Store] {
        let query = CatalogProjection.normalizedName(name)
        guard !query.isEmpty else { return [] }
        return GroceryRowScope.validStores(Array(stores), canonicalList: canonicalList)
            .filter { CatalogProjection.normalizedName($0.name).contains(query) }
    }

    var body: some View {
        Form {
                TextField("Store name", text: $name)
                    .accessibilityIdentifier("shopping.tags.storeName")
                if !matches.isEmpty {
                    Section("Existing stores") {
                        ForEach(matches, id: \.objectID) { store in
                            Button(store.isArchived ? "Restore and use \(store.name)" : "Use \(store.name)") {
                                select(store)
                            }
                            .disabled(!scopeAvailable)
                        }
                    }
                }
                Text("Save store adds it to your household. The grocery is saved separately.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !scopeAvailable { Text("This household is unavailable. Your store draft is still here.") }
                if let error { Text(error.localizedDescription).foregroundStyle(.red) }
            }
            .navigationTitle("Add store")
            .onAppear {
                guard !didCaptureScope else { return }
                capturedScope = StoreManagementCommandScope(canonicalList: canonicalList)
                didCaptureScope = true
            }
            .navigationBarBackButtonHidden()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save store", systemImage: "checkmark", action: save)
                        .disabled(!scopeAvailable || CatalogProjection.normalizedName(name).isEmpty)
                }
            }
    }

    private func select(_ store: Store) {
        guard scopeAvailable, matches.contains(store), let service, let capturedScope else { return }
        do {
            if store.isArchived {
                try service.setStoreArchived(
                    false, storeID: store.id, householdID: capturedScope.householdID, listID: capturedScope.listID)
            }
            onSelected(store.id)
            dismiss()
        } catch { self.error = error }
    }

    private func save() {
        guard scopeAvailable, let service, let capturedScope else { return }
        do {
            onSelected(try service.createStore(
                name: name, householdID: capturedScope.householdID, listID: capturedScope.listID))
            dismiss()
        } catch { self.error = error }
    }
}

private struct PurchaseRulesPreview: View {
    @Environment(\.persistenceSelection) private var selection
    @State private var ids: Set<UUID> = []
    @State private var anyStore = true
    var body: some View {
        NavigationStack { Form {
            PurchaseRulesPicker(storeIDs: $ids, anyStore: $anyStore,
                                householdID: selection.householdID, listID: selection.listID)
        } }
    }
}

#Preview("Purchase tags") { ShoppingPreviewHost(.populated) { PurchaseRulesPreview() } }
#Preview("Add store") {
    let fixture = try! ShoppingPreviewFixtures.make(.populated)
    NavigationStack { StoreCreationView(householdID: fixture.ids.householdID, listID: fixture.ids.listID, onSelected: { _ in })
        .environment(\.managedObjectContext, fixture.persistence.container.viewContext)
        .environment(\.needService, fixture.service)
        .environment(\.persistenceSelection, fixture.selection) }
}
