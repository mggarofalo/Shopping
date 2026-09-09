import Foundation

struct CatalogImportRow: Equatable, Identifiable {
    var id: String {
        parseError == nil ? "\(sourceID)\u{0}\(itemID)" : "invalid-line-\(line)"
    }
    let line: Int
    let sourceID: String
    let itemID: String
    let name: String
    let notes: String
    let categoryName: String?
    let storeNames: [String]
    let parseError: String?

    init(
        line: Int,
        sourceID: String,
        itemID: String,
        name: String,
        notes: String,
        categoryName: String?,
        storeNames: [String],
        parseError: String? = nil
    ) {
        self.line = line
        self.sourceID = sourceID
        self.itemID = itemID
        self.name = name
        self.notes = notes
        self.categoryName = categoryName
        self.storeNames = storeNames
        self.parseError = parseError
    }
}

enum CatalogImportDisposition: Equatable {
    case create
    case update
    case nameConflict([UUID])
    case invalid(String)
}

struct CatalogImportEntry: Equatable, Identifiable {
    var id: String { row.id }
    let row: CatalogImportRow
    let catalogItemID: UUID
    let existingRevision: Int64?
    let categoryID: UUID?
    let categoryRevision: Int64?
    let storeIDs: Set<UUID>
    let storeRevisions: [UUID: Int64]
    let reviewedIncomingCollisionIDs: Set<UUID>
    let allowedIncomingCollisionIDs: Set<UUID>
    let collisionRevisions: [UUID: Int64]
    let disposition: CatalogImportDisposition
}

struct CatalogImportPreview: Equatable {
    let householdID: UUID
    let listID: UUID
    let entries: [CatalogImportEntry]
}

struct CatalogImportSession: Identifiable {
    let id = UUID()
    let filename: String
    let preview: CatalogImportPreview
}

enum CatalogImportAction: String, CaseIterable, Identifiable {
    case skip
    case create
    case update

    var id: Self { self }
    var title: String {
        switch self {
        case .skip: "Skip"
        case .create: "Import new item"
        case .update: "Update linked item"
        }
    }
}

struct CatalogImportResult: Equatable {
    let created: Int
    let updated: Int
    let skipped: Int
    let changed: Int
}
