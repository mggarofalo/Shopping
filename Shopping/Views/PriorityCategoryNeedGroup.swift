import Foundation

struct PriorityCategoryNeedGroup: Identifiable {
    let urgency: NeedUrgency
    let categories: [CategoryNeedGroup]

    var id: String { urgency.rawValue }
    var title: String { urgency == .urgent ? "Urgent" : "Normal" }
}
