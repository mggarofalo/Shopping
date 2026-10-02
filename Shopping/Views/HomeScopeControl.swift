import SwiftUI

private struct PresentHomesKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct PresentInvitationKey: EnvironmentKey {
    static let defaultValue: (UUID) -> Void = { _ in }
}

struct HomeScopeDisplay: Equatable {
    let name: String
    let isLocal: Bool
}

private struct HomeScopeDisplayKey: EnvironmentKey {
    static let defaultValue: HomeScopeDisplay? = nil
}

extension EnvironmentValues {
    var homeScopeDisplay: HomeScopeDisplay? {
        get { self[HomeScopeDisplayKey.self] }
        set { self[HomeScopeDisplayKey.self] = newValue }
    }

    var presentHomes: () -> Void {
        get { self[PresentHomesKey.self] }
        set { self[PresentHomesKey.self] = newValue }
    }

    var presentInvitation: (UUID) -> Void {
        get { self[PresentInvitationKey.self] }
        set { self[PresentInvitationKey.self] = newValue }
    }
}

/// Keeps the selected home visible without competing with each screen's toolbar.
struct HomeScopeControl: View {
    @Environment(\.homeScopeDisplay) private var scope
    @Environment(\.presentHomes) private var presentHomes

    var body: some View {
        if let scope {
            Button(action: presentHomes) {
                HStack(spacing: 7) {
                    Image(systemName: "house")
                    Text(scope.name)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.groceryAccent)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose home")
            .accessibilityValue(scope.name + (scope.isLocal ? ", On This iPhone" : ", Selected"))
            .accessibilityIdentifier("shopping.home.scope")
            .background(Color(uiColor: .systemBackground))
            Divider()
        }
    }
}

private struct HomeScopeInset: ViewModifier {
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) { HomeScopeControl() }
    }
}

extension View {
    func homeScopeControl() -> some View { modifier(HomeScopeInset()) }
}

#Preview {
    NavigationStack {
        List { Text("Apples") }
            .navigationTitle("Groceries")
            .homeScopeControl()
    }
    .environment(\.homeScopeDisplay, HomeScopeDisplay(name: "My Home", isLocal: true))
}
