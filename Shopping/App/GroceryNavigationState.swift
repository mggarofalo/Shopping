import Foundation

@MainActor
final class GroceryNavigationState: ObservableObject {
    enum Tab: Hashable { case groceries, catalog, settings }

    @Published var selectedTab: Tab = .groceries
    @Published var selectedStoreID: UUID? { didSet { persist() } }
    @Published var includedStoreIDs: Set<UUID> { didSet { persist() } }
    @Published var excludedStoreIDs: Set<UUID> { didSet { persist() } }
    @Published var urgentOnly: Bool { didSet { persist() } }

    private struct SavedFilter: Codable, Equatable {
        var selectedStoreID: UUID?
        var includedStoreIDs: Set<UUID>
        var excludedStoreIDs: Set<UUID>
        var urgentOnly: Bool
    }

    private let defaults: UserDefaults
    private let keyPrefix: String
    private var householdID: UUID?
    private var isRestoring = false

    init(defaults: UserDefaults = .standard, keyPrefix: String = "shopping.groceryFilter") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        selectedStoreID = nil
        includedStoreIDs = []
        excludedStoreIDs = []
        urgentOnly = false
    }

    var activeFilterCount: Int {
        includedStoreIDs.count + excludedStoreIDs.count + (urgentOnly ? 1 : 0)
    }

    func configure(householdID: UUID?, activeStoreIDs: Set<UUID>) {
        guard self.householdID != householdID else {
            sanitize(activeStoreIDs: activeStoreIDs)
            return
        }
        isRestoring = true
        self.householdID = householdID
        if let householdID,
           let data = defaults.data(forKey: key(for: householdID)),
           let saved = try? JSONDecoder().decode(SavedFilter.self, from: data) {
            selectedStoreID = saved.selectedStoreID
            includedStoreIDs = saved.includedStoreIDs
            excludedStoreIDs = saved.excludedStoreIDs
            urgentOnly = saved.urgentOnly
        } else {
            selectedStoreID = nil
            includedStoreIDs = []
            excludedStoreIDs = []
            urgentOnly = false
        }
        isRestoring = false
        sanitize(activeStoreIDs: activeStoreIDs)
    }

    func selectAll() { selectedStoreID = nil }

    func selectStore(_ id: UUID) { selectedStoreID = id }

    func setIncluded(_ included: Bool, storeID: UUID) {
        if included {
            includedStoreIDs.insert(storeID)
            excludedStoreIDs.remove(storeID)
        } else {
            includedStoreIDs.remove(storeID)
        }
    }

    func setExcluded(_ excluded: Bool, storeID: UUID) {
        if excluded {
            excludedStoreIDs.insert(storeID)
            includedStoreIDs.remove(storeID)
        } else {
            excludedStoreIDs.remove(storeID)
        }
    }

    func resetFilters() {
        includedStoreIDs = []
        excludedStoreIDs = []
        urgentOnly = false
    }

    func sanitize(activeStoreIDs: Set<UUID>) {
        isRestoring = true
        if let selectedStoreID, !activeStoreIDs.contains(selectedStoreID) {
            self.selectedStoreID = nil
        }
        includedStoreIDs.formIntersection(activeStoreIDs)
        excludedStoreIDs.formIntersection(activeStoreIDs)
        isRestoring = false
        persist()
    }

    private func persist() {
        guard !isRestoring, let householdID else { return }
        let saved = SavedFilter(
            selectedStoreID: selectedStoreID,
            includedStoreIDs: includedStoreIDs,
            excludedStoreIDs: excludedStoreIDs,
            urgentOnly: urgentOnly
        )
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: key(for: householdID))
        }
    }

    private func key(for householdID: UUID) -> String {
        "\(keyPrefix).\(householdID.uuidString.lowercased())"
    }
}

struct GroceryAddScope: Identifiable, Equatable {
    let id = UUID()
    let householdID: UUID?
    let listID: UUID?
    let selectedStoreID: UUID?
    let selectedStoreName: String?

    func addOneTime(
        title: String,
        usesSelectedStore: Bool,
        currentSelection: PersistenceSelection,
        service: NeedService?
    ) throws -> UUID {
        guard currentSelection.householdID == householdID,
              currentSelection.listID == listID else {
            throw GroceryAddError.selectionChanged
        }
        guard let service, householdID != nil, let listID else {
            throw GroceryAddError.householdUnavailable
        }
        if usesSelectedStore, let selectedStoreID {
            return try service.addOneTimeNeed(
                title: title,
                storeIDs: [selectedStoreID],
                anyStore: false,
                listID: listID
            )
        }
        return try service.addOneTimeNeed(title: title, anyStore: true, listID: listID)
    }
}

enum GroceryAddError: LocalizedError, Equatable {
    case householdUnavailable
    case selectionChanged

    var errorDescription: String? {
        switch self {
        case .householdUnavailable:
            return "This household is not available yet. Try again when loading finishes."
        case .selectionChanged:
            return "The selected household changed. Close this draft and add the grocery again."
        }
    }
}
