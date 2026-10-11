import AppIntents

struct OpenGroceriesIntent: AppIntent {
    static var title: LocalizedStringResource = "Open grocery list"
    static var openAppWhenRun: Bool = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult {
        try ShoppingApplicationRuntime.shared.request(.groceries)
        return .result()
    }
}
