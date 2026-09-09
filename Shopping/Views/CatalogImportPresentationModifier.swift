import SwiftUI
import UniformTypeIdentifiers

struct CatalogImportPresentationModifier: ViewModifier {
    @Binding var showingFileImporter: Bool
    @Binding var session: CatalogImportSession?
    @Binding var errorMessage: String?
    @Binding var notice: String?
    let load: (Result<[URL], Error>) -> Void
    let apply: ([String: CatalogImportAction]) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $session) { session in
                CatalogImportView(session: session, onImport: apply)
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText],
                allowsMultipleSelection: false,
                onCompletion: load
            )
            .alert("Couldn’t load catalog", isPresented: errorPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Catalog import complete", isPresented: noticePresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(notice ?? "")
            }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var noticePresented: Binding<Bool> {
        Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    }
}
