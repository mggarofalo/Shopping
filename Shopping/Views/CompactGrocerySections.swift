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
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(
                            item[keyPath: itemID] == section.items.last?[keyPath: itemID]
                                ? .hidden : .visible,
                            edges: .bottom
                        )
                        .listRowSeparator(.hidden, edges: .top)
                }
            } header: {
                Text(section.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.grocerySecondary)
                    .textCase(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }
}
