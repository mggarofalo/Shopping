import SwiftUI

/// The grocery and cart collections share a compact section rhythm. Catalog keeps its own list style.
struct CompactGrocerySections<SectionID: Hashable, ItemID: Hashable, Item, Row: View>: View {
    let sections: [ItemCollectionSection<SectionID, Item>]
    let itemID: KeyPath<Item, ItemID>
    @ViewBuilder let row: (SectionID, Item) -> Row

    var body: some View {
        ForEach(sections) { section in
            Section {
                ForEach(section.items, id: itemID) { item in
                    row(section.id, item)
                        .listRowSeparator(
                            item[keyPath: itemID] == section.items.last?[keyPath: itemID]
                                ? .hidden : .visible,
                            edges: .bottom
                        )
                        .listRowSeparator(.hidden, edges: .top)
                }
            } header: {
                Text(section.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.grocerySecondary)
                    .textCase(nil)
                    .frame(maxWidth: .infinity, minHeight: 16, alignment: .bottomLeading)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }
}
