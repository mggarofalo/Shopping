import Foundation

enum NeedUrgency: String, Codable, CaseIterable, Sendable {
    case normal
    case urgent
}

enum NeedKind: String, Codable {
    case remembered
    case oneTime
}
