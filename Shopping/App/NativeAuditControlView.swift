#if DEBUG
import SwiftUI

// Temporary SHOPPING-131 calibration. Remove this entire file before integration.
struct NativeAuditControlView: View {
    enum Layout: String {
        case stack
        case list
    }

    let layout: Layout
    private static let names = [
        "Alexandra Penelope Montgomery-Wellington",
        "Taylor Morgan", "Jordan Blake", "Casey Parker", "Avery Quinn",
        "Riley Cameron", "Sam Bennett", "Drew Ellis", "Robin Hayes", "Jamie Reed"
    ]

    var body: some View {
        switch layout {
        case .stack:
            VStack(alignment: .leading) {
                Text("Headline")
                    .font(.headline)
                    .accessibilityIdentifier("native.audit.stack.headline")
                Text("Body")
                    .font(.body)
                    .accessibilityIdentifier("native.audit.stack.body")
                Text("Caption")
                    .font(.caption)
                    .accessibilityIdentifier("native.audit.stack.caption")
            }
            .padding()
        case .list:
            List {
                Text("Headline")
                    .font(.headline)
                    .accessibilityIdentifier("native.audit.list.headline")
                Text("Body")
                    .font(.body)
                    .accessibilityIdentifier("native.audit.list.body")
                Text("Caption")
                    .font(.caption)
                    .accessibilityIdentifier("native.audit.list.caption")
                ForEach(Self.names, id: \.self) { name in
                    Text("\(name). Your personal cart and saved history remain on this device.")
                        .font(.body)
                        .accessibilityIdentifier("native.audit.list.member.\(name)")
                }
                Text("Saved work remains on this device.")
                    .font(.body)
                    .accessibilityIdentifier("native.audit.list.deep")
                Text("End of control.")
                    .font(.body)
                    .padding(.vertical, 120)
                    .accessibilityIdentifier("native.audit.list.footer")
            }
            .accessibilityIdentifier("native.audit.list")
        }
    }
}

#Preview("Native stack audit control") {
    NativeAuditControlView(layout: .stack)
}

#Preview("Native list audit control") {
    NativeAuditControlView(layout: .list)
}
#endif
