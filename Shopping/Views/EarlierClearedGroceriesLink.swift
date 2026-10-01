import SwiftUI

/// One route policy for both purchase history and the legacy review context.
struct EarlierClearedGroceriesLink: View {
    let cart: PersonalCartPresentation
    @Environment(\.persistenceSelection) private var selection

    var body: some View {
        if cart.canReviewEarlierCleared(in: selection) {
            NavigationLink("Earlier cleared groceries") { RecentlyClearedView() }
                .accessibilityIdentifier("shopping.personalCart.earlierHistory")
        }
    }
}

#if DEBUG
#Preview { PersonalCartPreviewHost { cart in NavigationStack { List { EarlierClearedGroceriesLink(cart: cart) } } } }
#endif
