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
    var showsContext = false
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

/// Home content belongs to the screen's native scroll layout, not its safe area.
struct HomeScopeControl: View {
    var allowsSwitching = true
    @Environment(\.homeScopeDisplay) private var scope
    @Environment(\.presentHomes) private var presentHomes

    var body: some View {
        if let scope, allowsSwitching || scope.showsContext {
            if allowsSwitching {
                Button(action: presentHomes) {
                    HStack(spacing: 7) {
                        homeLabel(scope)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.groceryAccent)
                .accessibilityLabel("Choose home")
                .accessibilityValue(scope.name
                    + (scope.isLocal && !scope.name.hasSuffix("On This iPhone") ? ", On This iPhone" : "")
                    + ", Selected")
                .accessibilityIdentifier("shopping.home.scope")
            } else {
                homeLabel(scope)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Home")
                    .accessibilityValue(scope.name)
                    .accessibilityIdentifier("shopping.home.context")
            }
        }
    }

    private func homeLabel(_ scope: HomeScopeDisplay) -> some View {
        Label(scope.name, systemImage: scope.isLocal ? "iphone" : "house")
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
    }
}

#Preview {
    NavigationStack {
        List { HomeScopeControl(); Text("Apples") }
            .navigationTitle("Groceries")
            .navigationBarTitleDisplayMode(.inline)
    }
    .environment(\.homeScopeDisplay, HomeScopeDisplay(name: "My Home", isLocal: true))
}
