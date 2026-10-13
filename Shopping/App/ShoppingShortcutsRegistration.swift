import AppIntents

/// Static phrases need one registration per launch, independent of catalog size or edits.
@MainActor
final class ShoppingShortcutsRegistration {
    init(update: () -> Void = { ShoppingShortcuts.updateAppShortcutParameters() }) {
        update()
    }
}
