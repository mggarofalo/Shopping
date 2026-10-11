import AppIntents

struct SearchCatalogIntent: AppIntent {
    static var title: LocalizedStringResource = "Search catalog"
    static var openAppWhenRun: Bool = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Search text") var query: String?
    static var parameterSummary: some ParameterSummary { Summary("Search catalog for \(\.$query)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        try ShoppingApplicationRuntime.shared.request(.catalog(query ?? ""))
        return .result()
    }
}
