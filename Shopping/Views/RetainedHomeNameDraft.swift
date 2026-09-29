import SwiftUI

/// Name-only editors share the same retention rule: scope retirement keeps the draft;
/// ordinary dismissal (save/cancel/swipe) ends it. The scope is captured only once.
private struct RetainedHomeNameDraft: ViewModifier {
    @Binding var name: String
    let editor: String?
    @Environment(\.persistenceSelection) private var selection
    @Environment(\.persistencePresentation) private var presentation
    @Environment(\.homeEditorDraftStore) private var store
    @State private var originalScope: ActiveHomeScope?
    @State private var originalEditor: String?
    @State private var lease: HomeEditorDraftStore.Lease?
    @State private var loaded = false
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !loaded else { return }
                loaded = true
                originalScope = selection.homeScope
                originalEditor = editor
                guard let originalScope, let originalEditor, let store else { return }
                lease = store.open(scope: originalScope, editor: originalEditor)
                do {
                    if let saved = try store.load(String.self, scope: originalScope, editor: originalEditor) {
                        name = saved
                    }
                } catch { self.error = error.localizedDescription }
            }
            .onChange(of: name) { _, _ in retain() }
            .onDisappear {
                guard let lease else { return }
                if presentation?.isActive == false { retain() }
                else { store?.finish(lease) }
            }
            .alert("Couldn’t retain this draft", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(error ?? "") }
    }

    private func retain() {
        guard loaded, let lease, let store else { return }
        do { try store.save(name, lease: lease) }
        catch { self.error = error.localizedDescription }
    }
}

extension View {
    func retainedHomeNameDraft(_ name: Binding<String>, editor: String?) -> some View {
        modifier(RetainedHomeNameDraft(name: name, editor: editor))
    }
}

private struct HomeEditorParentKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var homeEditorParentKey: String? {
        get { self[HomeEditorParentKey.self] }
        set { self[HomeEditorParentKey.self] = newValue }
    }
}
