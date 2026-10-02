import Foundation

/// A saved cart carries its own home label, independent of the app's selection.
struct SavedCartHomeDisplay: Equatable, Sendable {
    let scope: PersonalCartScopeSnapshot
    let name: String

    static func unknown(_ scope: PersonalCartScopeSnapshot) -> Self {
        Self(scope: scope, name: "Saved Home")
    }
}
