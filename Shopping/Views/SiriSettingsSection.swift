import AppIntents
import SwiftUI

struct SiriSettingsSection: View {
    @AppStorage("shopping.siri.showAddTip") private var showAddTip = true

    var body: some View {
        Section {
            SiriTipView(intent: AddGroceryIntent(), isVisible: $showAddTip)
            ShortcutsLink()
                .accessibilityIdentifier("shopping.siri.shortcuts")
        } header: {
            Text("Siri & Shortcuts")
        } footer: {
            Text("Ask Siri to add an item in Milk and Bananas, then say its name. For a saved catalog item, you can also say “Add milk to Milk and Bananas.” New items open in the app for you to review and save.")
        }
    }
}

#Preview {
    List { SiriSettingsSection() }
}
