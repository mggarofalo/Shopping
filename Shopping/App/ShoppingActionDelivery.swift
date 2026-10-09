import SwiftUI
import UIKit

/// Waits for native modal presentations to finish before delivering navigation.
/// UIKit owns their lifecycle; a system action never dismisses a user's editor.
struct ShoppingActionDelivery: ViewModifier {
    @ObservedObject var router: ShoppingActionRouter
    @ObservedObject var navigation: GroceryNavigationState
    @Environment(\.persistencePresentation) private var presentation
    @Environment(\.scenePhase) private var scenePhase

    private struct DeliveryIdentity: Equatable {
        let requestID: UUID?
        let presentationID: UUID?
        let phase: ScenePhase
    }

    func body(content: Content) -> some View {
        content
            .task(id: DeliveryIdentity(requestID: router.pending?.id, presentationID: presentation?.id, phase: scenePhase)) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled, router.pending != nil {
                    router.expire()
                    guard router.pending != nil else { return }
                    if let presentation, presentation.isActive, scenePhase == .active,
                       !hasPresentedController {
                        do {
                            guard let destination = try router.take(presentationID: presentation.id) else { return }
                            navigation.requestSystemAction(destination)
                        } catch { router.message = error.localizedDescription }
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(250)) }
                    catch { return }
                }
            }
            .safeAreaInset(edge: .top) {
                if router.pending != nil {
                    HStack {
                        Text("Your requested action is waiting.")
                        Spacer()
                        Button("Cancel") { router.cancel() }
                    }
                    .font(.callout)
                    .padding()
                    .background(.regularMaterial)
                }
            }
            .alert("Couldn’t open action", isPresented: Binding(
                get: { router.message != nil }, set: { if !$0 { router.message = nil } }
            )) { Button("OK", role: .cancel) {} }
            message: { Text(router.message ?? "") }
    }

    private var hasPresentedController: Bool {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).filter(\.isKeyWindow)
            .contains { $0.rootViewController?.presentedViewController != nil }
    }
}
