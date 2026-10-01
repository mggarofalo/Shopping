import SwiftUI

struct HomeSharingDetailsView: View {
    @EnvironmentObject private var bootstrap: PersistenceBootstrap

    private var status: HomeSharingStatus { bootstrap.homeSharingStatus }

    var body: some View {
        List {
            ForEach(status.sections) { section in
                Section {
                    Text(section.presentation.details)
                        .accessibilityIdentifier("shopping.sharing.section.\(section.id.rawValue)")
                    if let date = section.lastUpload { observation("Last observed upload", date: date) }
                    if let date = section.lastDownload { observation("Last observed download", date: date) }
                } header: {
                    Label(section.presentation.title, systemImage: section.presentation.symbol)
                }
            }
        }
        .navigationTitle("Sharing details")
    }

    private func observation(_ title: String, date: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(date, format: .dateTime.month().day().hour().minute())
        }
        .accessibilityElement(children: .combine)
    }

}

#Preview {
    ShoppingPreviewHost(.populated) {
        NavigationStack { HomeSharingDetailsView() }
    }
}
