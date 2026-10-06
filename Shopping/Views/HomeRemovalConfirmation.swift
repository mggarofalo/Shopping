import SwiftUI

private struct HomeRemovalConfirmation: ViewModifier {
    @ObservedObject var model: HomeDetailsModel
    var invitedName: String?
    var enabled: Bool

    func body(content: Content) -> some View {
        let prompt = model.removalConfirmation.map { MembershipRemovalPrompt(confirmation: $0,
            members: model.snapshot?.members ?? [], invitedName: invitedName) }
        content.alert(prompt?.title ?? "", isPresented: Binding(
            get: { enabled && model.removalConfirmation != nil }, set: { _ in }
        )) {
            if let confirmation = model.removalConfirmation, let prompt {
                Button(prompt.action, role: .destructive) { Task { await model.confirmRemoval(confirmation) } }
                    .disabled(!model.canManageMembers)
                    .accessibilityIdentifier("shopping.home.confirmRemoval")
            }
            Button(prompt?.dismissAction ?? "Cancel", role: .cancel) { model.removalConfirmation = nil }
                .accessibilityIdentifier("shopping.home.cancelRemoval")
        } message: {
            if let message = prompt?.message { Text(message) }
        }
    }
}

extension View {
    func homeRemovalConfirmation(model: HomeDetailsModel, invitedName: String? = nil, enabled: Bool = true) -> some View {
        modifier(HomeRemovalConfirmation(model: model, invitedName: invitedName, enabled: enabled))
    }
}

enum HomeInvitationPreview {
    static var scope: ActiveHomeScope {
        let session = try! ShopperSession.authenticated(containerIdentifier: "iCloud.preview", environment: "Development", accountRecordName: "preview")
        return ActiveHomeScope(session: session, graph: HomeGraphIdentity(storeIdentifier: "preview", rootURI: "preview", householdID: UUID(), listID: UUID()))
    }
    static var actions: HomeDetailsActions {
        HomeDetailsActions(refresh: { throw HomeMembershipError.shareUnavailable }, pending: { nil },
            invite: { _ in throw HomeMembershipError.shareUnavailable }, resend: { _ in throw HomeMembershipError.shareUnavailable },
            acknowledge: { _ in }, rename: { _ in })
    }
}
