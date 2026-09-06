import CoreData

enum PersistenceModelError: LocalizedError {
    case compiledModelNotFound
    case compiledModelUnreadable(URL)

    var errorDescription: String? {
        switch self {
        case .compiledModelNotFound:
            return "The bundled Shopping Core Data model could not be found."
        case .compiledModelUnreadable(let url):
            return "The bundled Shopping Core Data model at \(url.path) could not be loaded."
        }
    }
}

enum PersistenceModel {
    static let name = "Shopping"
    static let unsetID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let versionIdentifier = "ShoppingSchemaV1"

    static func make() throws -> NSManagedObjectModel {
        guard let modelURL = Bundle(for: PersistenceModelBundleToken.self)
            .url(forResource: name, withExtension: "momd") else {
            throw PersistenceModelError.compiledModelNotFound
        }
        guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
            throw PersistenceModelError.compiledModelUnreadable(modelURL)
        }
        return model
    }
}

private final class PersistenceModelBundleToken: NSObject {}
