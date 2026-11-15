import SwiftUI

struct ShoppingToastHost: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var center: ShoppingToastCenter
    /// The app-wide host steps aside while a screen hosts toasts above its own bottom bar.
    var yieldsToScreenHost = false

    var body: some View {
        VStack(spacing: 8) {
            if !yieldsToScreenHost || center.screenHostCount == 0 {
                ForEach(center.toasts) { toast in
                    // A dismissed toast fades where it is; sliding down would carry its tap target over the
                    // tab bar or toolbar and swallow the next tap there.
                    ShoppingToastView(toast: toast, center: center)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity))
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

private struct ShoppingToastView: View {
    let toast: ShoppingToast
    let center: ShoppingToastCenter
    @GestureState private var dragOffset: CGSize = .zero

    var body: some View {
        ShoppingFeedbackBar(message: toast.message, dismiss: dismiss) {
            if let action = toast.action {
                Button(action.title) {
                    center.performAction(for: toast)
                }
                .frame(minHeight: ShoppingListMetrics.minimumRowHeight)
                .accessibilityIdentifier(action.accessibilityIdentifier)
            }
        }
        .offset(x: dragOffset.width, y: max(0, dragOffset.height))
        .onTapGesture(perform: dismiss)
        .gesture(
            DragGesture(minimumDistance: 12)
                .updating($dragOffset) { value, offset, _ in offset = value.translation }
                .onEnded { value in
                    if abs(value.translation.width) > 60 || value.translation.height > 24 { dismiss() }
                }
        )
    }

    private func dismiss() { center.dismiss(toast.id) }
}

extension View {
    /// Hosts toasts in this screen's safe area so they sit above its bottom toolbar or bar inset.
    /// Apply it inside any bottom `safeAreaInset`, so the inset also lifts the toasts.
    func shoppingToastHost() -> some View { modifier(ShoppingScreenToastHost()) }
}

private struct ShoppingScreenToastHost: ViewModifier {
    @Environment(\.shoppingToastCenter) private var center

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let center {
                    ShoppingToastHost(center: center)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
            .onAppear { center?.claimScreenHost() }
            .onDisappear { center?.releaseScreenHost() }
    }
}

#Preview("Toasts") {
    let center = ShoppingToastCenter { _ in try await Task.sleep(for: .seconds(3600)) }
    center.show("3 items moved to In cart.", duration: .success)
    center.show("Item removed", duration: .undo, action: ShoppingToastAction(
        title: "Undo", accessibilityIdentifier: "preview.undo"
    ) { true })
    return ShoppingToastHost(center: center).padding()
}
