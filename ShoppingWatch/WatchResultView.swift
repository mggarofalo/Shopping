import SwiftUI

struct WatchResultView: View {
    let result: WatchActionResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Text(result.title).font(.headline)
            Text(result.message).font(.footnote)
            if !result.skippedNames.isEmpty {
                Section("Left unchanged") {
                    ForEach(Array(result.skippedNames.enumerated()), id: \.offset) { _, name in Text(name) }
                }
            }
            Button("Done") { dismiss() }
        }
        .listStyle(.plain)
        .navigationTitle("Result")
    }
}

#if DEBUG
#Preview("Partial checkout") {
    NavigationStack {
        WatchResultView(result: WatchActionResult(id: UUID(), title: "2 items cleared", message: "1 changed item stayed in your cart. You can recover cleared items in Recently cleared.", skippedNames: ["Oat milk"], snapshot: WatchPreviewService.sample))
    }
}
#endif
