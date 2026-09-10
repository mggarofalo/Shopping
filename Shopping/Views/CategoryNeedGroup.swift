import Foundation

struct CategoryNeedGroup: Identifiable {
    let categoryID: UUID?
    let title: String
    let needs: [Need]

    var id: String { categoryID?.uuidString ?? "uncategorized" }
}
