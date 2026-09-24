import SwiftUI

struct WatchItemSections: View {
    let session: WatchShoppingSession
    let sections: [WatchItemSection]

    var body: some View {
        ForEach(sections) { section in
            Section(section.title) {
                ForEach(section.items) { item in
                    NavigationLink {
                        WatchItemCard(session: session, itemID: item.id)
                    } label: {
                        WatchItemLabel(item: item)
                    }
                    .accessibilityLabel(item.name)
                    .accessibilityValue(item.accessibilityValue)
                    .accessibilityHint("Opens item details")
                    .accessibilityIdentifier("watch.item.\(item.id)")
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if item.isInOwnCart && item.canRemove {
                            Button("Remove", systemImage: "cart.badge.minus") {
                                Task { await session.perform(.remove(token: item.commandToken)) }
                            }
                            .tint(.orange)
                            .disabled(session.isBusy)
                        } else if !item.isInOwnCart && item.canAdd {
                            Button("Add", systemImage: "cart.badge.plus") {
                                Task { await session.perform(.add(token: item.commandToken, quantity: item.quantity)) }
                            }
                            .tint(.green)
                            .disabled(session.isBusy)
                        }
                    }
                    .accessibilityActions {
                        if item.isInOwnCart && item.canRemove {
                            Button("Remove from your cart") {
                                Task { await session.perform(.remove(token: item.commandToken)) }
                            }
                        } else if !item.isInOwnCart && item.canAdd {
                            Button("Add to your cart") {
                                Task { await session.perform(.add(token: item.commandToken, quantity: item.quantity)) }
                            }
                        }
                    }
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        List { WatchItemSections(session: WatchShoppingSession(service: WatchPreviewService()), sections: WatchPreviewService.sample.grocerySections) }
    }
}
#endif
