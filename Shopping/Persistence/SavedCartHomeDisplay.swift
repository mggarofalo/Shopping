import Foundation

/// A saved cart carries its own home label, independent of the app's selection.
struct SavedCartHomeDisplay: Equatable, Sendable {
    let scope: PersonalCartScopeSnapshot
    let name: String
    let context: String?

    init(scope: PersonalCartScopeSnapshot, name: String, context: String? = nil) {
        self.scope = scope
        self.name = name
        self.context = context
    }

    var displayName: String { HomePresentationName(name: name, context: context).title }

    static func unknown(_ scope: PersonalCartScopeSnapshot) -> Self {
        Self(scope: scope, name: "Saved Home")
    }
}
