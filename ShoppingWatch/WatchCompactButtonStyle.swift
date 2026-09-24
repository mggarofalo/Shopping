import SwiftUI

/// The native watch bordered style stays ~52 points tall even at .small.
/// Keep a 44-point native Button hit region with a quieter capsule inside it.
struct WatchCompactButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .background {
                Capsule()
                    .fill(Color.secondary.opacity(configuration.isPressed ? 0.45 : 0.25))
                    .padding(.vertical, 6)
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
    }
}

#if DEBUG
#Preview {
    Button("Check out") {}.buttonStyle(WatchCompactButtonStyle())
}
#endif
