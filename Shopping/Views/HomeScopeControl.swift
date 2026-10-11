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

/// Settings owns home switching; shopping screens show conditional read-only context.
/// Home content belongs to the screen's native scroll layout, not its safe area.
struct HomeScopeControl: View {
    var allowsSwitching = true
    @Environment(\.homeScopeDisplay) private var scope
    @Environment(\.presentHomes) private var presentHomes

    var body: some View {
        if allowsSwitching {
            Button(action: presentHomes) {
                HStack(spacing: 7) {
                    Image(systemName: "house")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Homes").foregroundStyle(.primary)
                        Text(scope?.name ?? "Choose a Home").font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.groceryAccent)
            .accessibilityLabel("Homes")
            .accessibilityValue(scope.map {
                $0.name + ($0.isLocal && !$0.name.hasSuffix("On This iPhone") ? ", On This iPhone" : "") + ", Selected"
            } ?? "Choose a Home")
            .accessibilityIdentifier("shopping.home.scope")
        } else if let scope, scope.showsContext {
            homeLabel(scope)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Home")
                .accessibilityValue(scope.name)
                .accessibilityIdentifier("shopping.home.context")
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
        List { HomeScopeControl() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
    }
    .environment(\.homeScopeDisplay, HomeScopeDisplay(name: "My Home", isLocal: true))
}
