import SwiftUI

/// Shared phone cloud styling keeps activity inside a fixed native control.
struct HomeCloudSymbol: View {
    let isWorking: Bool
    var needsAttention = false
    @ScaledMetric(relativeTo: .body) private var symbolSize = 28
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: needsAttention ? "exclamationmark.icloud" : "icloud")
            .frame(width: symbolSize, height: symbolSize)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(needsAttention ? Color.orange : (isWorking ? Color.accentColor : Color.secondary))
            .symbolEffect(.pulse, isActive: isWorking && !reduceMotion)
            .accessibilityHidden(true)
    }
}

#Preview {
    HStack {
        HomeCloudSymbol(isWorking: false)
        HomeCloudSymbol(isWorking: true)
    }.padding()
}
