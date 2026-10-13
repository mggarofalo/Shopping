import AppIntents
import SwiftUI

struct SiriSettingsSection: View {
    var body: some View {
        Section {
            ShortcutsLink()
                .accessibilityIdentifier("shopping.siri.shortcuts")
        } header: {
            Text("Siri & Shortcuts")
        } footer: {
            Text(instructions)
        }
    }

    private var instructions: String {
        let prompted = "Say “Add an item in Milk and Bananas,” then say its name. New items open in the app for you to review and save."
        if #available(iOS 27.0, *) {
            return "With Siri AI, try “Add milk to Milk and Bananas.” If Siri chooses another app, use the prompted action. " + prompted
        }
        return prompted
    }
}

#Preview {
    List { SiriSettingsSection() }
}
