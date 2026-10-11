#if DEBUG
import Foundation

/// Isolated SQLite evidence and substituted native membership only; this fixture
/// does not exercise CloudKit invitation acceptance or server convergence.
enum HomeReplacementUITestFixture {
    static func seed(mode: String, base: URL, invitation: HomeInvitationInbox.Entry,
                     target: HomeGraphIdentity, priorTarget: HomeGraphIdentity? = nil) throws {
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.shopping-homes",
            environment: "Development", accountRecordName: "isolated-home-test-account")
        let url = base.appendingPathComponent("Starter.sqlite")
        let persistence = try PersistenceController(storeURL: url)
        defer {
            persistence.writer.performAndWait { persistence.writer.reset() }
            persistence.container.viewContext.performAndWait { persistence.container.viewContext.reset() }
            for store in persistence.container.persistentStoreCoordinator.persistentStores {
                try? persistence.container.persistentStoreCoordinator.remove(store)
            }
        }
        guard let storeID = persistence.primaryStore?.identifier else { throw HomeDeletionError.scopeChanged }
        let command = try LocalHomeCreationJournal(storeURL: url).begin(
            name: mode == "same-name" ? "Second home" : "My Home", storeIdentifier: storeID)
        _ = try NeedService(persistence: persistence).createLocalHousehold(command: command)
        guard let evidence = try LocalStarterJournal(storeURL: url).load() else { throw HomeDeletionError.scopeChanged }
        let source = DeviceLocalHomeSelection(sourceURL: url, graph: evidence.graph, homeName: evidence.name, session: session)
        try DeviceLocalHomeSelectionJournal(baseDirectory: base).select(source)
        try HomeReplacementOriginJournal(base: base, session: session).save(.init(
            source: source, invitationID: invitation.id, invitation: invitation.identity))
        if mode == "populated" {
            _ = try NeedService(persistence: persistence).addOneTimeNeed(title: "Keep these groceries", quantity: 1,
                householdID: evidence.graph.householdID, listID: evidence.graph.listID)
        }
        if mode == "pending" || mode == "prior-kept" {
            let proposal = HomeReplacementProposal(id: UUID(), source: evidence, sourceURL: url,
                invitationID: mode == "prior-kept" ? UUID() : invitation.id, invitation: invitation.identity, session: session, navigationIntent: UUID())
            let journal = HomeReplacementJournal(url: try session.storeDirectory(in: base)
                .appendingPathComponent("home-replacement.json"), session: session)
            var previous = try journal.confirm(proposal)
            let stages: [HomeReplacementRecord.Stage] = mode == "prior-kept"
                ? [.joining, .activating, .sourceKept] : [.joining, .activating, .targetActivated]
            for stage in stages {
                var next = previous
                next.stage = stage
                if stage == .activating { next.target = ActiveHomeScope(session: session, graph: mode == "prior-kept" ? (priorTarget ?? target) : target) }
                try journal.update(next, replacing: previous)
                previous = next
            }
        }
    }
}
#endif
