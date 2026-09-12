import Foundation

enum CategoryNeedGroupID: Hashable {
    case category(UUID)
    case unavailable
    case uncategorized
}

struct CategoryNeedGroup: Identifiable {
    let id: CategoryNeedGroupID
    let categoryID: UUID?
    let title: String
    let needs: [Need]
}
