import SwiftUI
import UIKit

struct ShoppingToastHost: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var center: ShoppingToastCenter

    var body: some View {
        VStack(spacing: 8) {
            ForEach(center.toasts) { toast in
                ShoppingFeedbackBar(message: toast.message) {
                    if let action = toast.action {
                        Button(action.title) {
                            center.performAction(for: toast)
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier(action.accessibilityIdentifier)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    UIAccessibility.post(notification: .announcement, argument: toast.message)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shopping.toast.host")
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: center.toasts.map(\.id)
        )
    }
}
