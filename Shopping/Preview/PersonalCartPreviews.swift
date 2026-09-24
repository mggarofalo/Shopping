import SwiftUI

#if DEBUG
struct PersonalCartFixtureSessionProvider: ShopperSessionProviding {
    let session: ShopperSession

    init(shopper: String = "preview-shopper") throws {
        session = try ShopperSession.authenticated(containerIdentifier: "iCloud.com.mggarofalo.shopping.fixtures",
            environment: "Development", accountRecordName: shopper)
    }

    func currentSession() throws -> ShopperSession { session }
}

struct PersonalCartPreviewHost<Content: View>: View {
    private let environment: ShoppingPreviewEnvironment?
    private let cart: PersonalCartPresentation?
    private let failure: String?
    let content: (PersonalCartPresentation) -> Content

    init(@ViewBuilder content: @escaping (PersonalCartPresentation) -> Content) {
        self.content = content
        do {
            let environment = try ShoppingPreviewFixtures.make(.populated)
            let service = PersonalCartService(persistence: environment.persistence,
                sessionProvider: try PersonalCartFixtureSessionProvider())
            try service.captureLegacyReview()
            for entry in try service.legacyReview() where !entry.archived {
                try service.decideLegacyReview(id: entry.id, claim: true)
            }
            self.environment = environment
            cart = PersonalCartPresentation(service: service,
                householdID: environment.ids.householdID, listID: environment.ids.listID)
            failure = nil
        } catch { environment = nil; cart = nil; failure = error.localizedDescription }
    }

    var body: some View {
        if let environment, let cart {
            content(cart)
                .environment(\.managedObjectContext, environment.persistence.container.viewContext)
                .environment(\.needService, environment.service)
                .environment(\.persistenceSelection, environment.selection)
                .environment(\.personalCart, cart)
        } else { Text(failure ?? "Preview unavailable") }
    }
}
#endif
