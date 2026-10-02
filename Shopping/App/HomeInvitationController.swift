import CloudKit
import Combine
import CryptoKit
import Foundation

/// Coordinates UI only. The worker owns all invitation decoding and durable file work.
@MainActor
final class HomeInvitationController: ObservableObject {
    static let shared = HomeInvitationController(factory: {
        let bundle = Bundle.main
        let container = bundle.object(forInfoDictionaryKey: "ShoppingCloudKitContainerIdentifier") as? String ?? ""
        let environment = bundle.object(forInfoDictionaryKey: "ShoppingCloudKitEnvironment") as? String ?? ""
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let namespace = SHA256.hash(data: try JSONEncoder().encode([container, environment]))
            .map { String(format: "%02x", $0) }.joined()
        return try HomeInvitationInbox(url: directory.appendingPathComponent("HomeInvitations/" + namespace + ".json"),
            containerIdentifier: container, environment: environment)
    })

    @Published private(set) var entries: [HomeInvitationInbox.Entry] = []
    @Published private(set) var problem: String?
    @Published private(set) var importProblems: [UUID: String] = [:]
    @Published private(set) var hasVerifiedAccount = false
    @Published private(set) var hasPendingActivation = true
    var onChange: (() -> Void)?
    /// Retire an outstanding Open choice at ingress, before the journal worker
    /// can publish its replacement entry. The callback performs no file work.
    var onChoiceInvalidated: ((HomeInvitationIdentity) -> Void)?
    private(set) var allEntries: [HomeInvitationInbox.Entry] = []
    private let worker: HomeInvitationWorker
    private var session: ShopperSession?
    private var sharedStoreIdentifier: String?
    private var transport: (any HomeInvitationTransport)?
    private var draining = false
    private var drainAgain = false
    private var pendingWork = 0
    private var pendingIngress = 0
    private var pendingChoiceChanges: [UUID: HomeInvitationIdentity] = [:]
    private var persistedActivationHold = true
    private var loaded = false
    private var snapshotRevision: UInt64 = 0

    init(inbox: HomeInvitationInbox) {
        allEntries = inbox.entries
        persistedActivationHold = inbox.hasPendingActivation
        hasPendingActivation = inbox.hasPendingActivation
        worker = HomeInvitationWorker(inbox: inbox)
        loaded = true
        publish()
    }

    init(worker: HomeInvitationWorker) { self.worker = worker }

    init(factory: @escaping @Sendable () throws -> HomeInvitationInbox) {
        worker = HomeInvitationWorker(factory: factory)
    }

    var isProcessing: Bool { draining || pendingWork > 0 }
    var isVisible: Bool { !entries.isEmpty || (!hasVerifiedAccount && hasPendingActivation) || problem != nil }

    func hasPendingChoiceChange(for identity: HomeInvitationIdentity) -> Bool {
        pendingChoiceChanges.values.contains(identity)
    }

    private func beginChoiceChange(_ identity: HomeInvitationIdentity) -> UUID {
        let id = UUID()
        pendingChoiceChanges[id] = identity
        onChoiceInvalidated?(identity)
        return id
    }

    /// Bootstrap waits here before deciding whether an empty local store may create a home.
    func prepare() async {
        guard !loaded else { return }
        do { try await perform { _ in () } }
        catch { problem = "Saved invitations could not be opened. Your groceries are retained. Try reopening the app." }
    }

    func receive(_ metadata: CKShare.Metadata) {
        let id = metadata.share.recordID
        let rawName = metadata.share[CKShare.SystemFieldKey.title] as? String
        let trimmedName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName?.isEmpty == false ? trimmedName : nil
        let environment = Bundle.main.object(forInfoDictionaryKey: "ShoppingCloudKitEnvironment") as? String ?? ""
        let identity = HomeInvitationIdentity(containerIdentifier: metadata.containerIdentifier, environment: environment,
            share: HomeShareIdentity(recordName: id.recordName, zoneName: id.zoneID.zoneName, zoneOwnerName: id.zoneID.ownerName))
        let change = beginChoiceChange(identity)
        pendingIngress += 1
        publish()
        submit({ inbox in
            return try inbox.enqueue(identity: identity,
                metadataArchive: ManagedHomeInvitationTransport.archive(metadata),
                displayName: displayName,
                participantPending: metadata.participantStatus == .pending)
        }) { [weak self] result in
            guard let self else { return }
            pendingChoiceChanges.removeValue(forKey: change)
            pendingIngress -= 1
            publish()
            if case .failure = result {
                problem = "This invitation could not be saved or does not belong to this app. Reopen the original link to try again."
            } else { problem = nil }
            process()
        }
    }

    /// Value ingress also serves isolated fixtures; production scene ingress archives on the worker.
    @discardableResult
    func enqueue(identity: HomeInvitationIdentity, metadataArchive: Data,
                 displayName: String? = nil,
                 participantPending: Bool = false) async throws -> HomeInvitationInbox.Entry {
        let change = beginChoiceChange(identity)
        pendingIngress += 1
        publish()
        defer { pendingChoiceChanges.removeValue(forKey: change); pendingIngress -= 1; publish() }
        let entry = try await perform {
            try $0.enqueue(identity: identity, metadataArchive: metadataArchive,
                displayName: displayName, participantPending: participantPending)
        }
        process()
        return entry
    }

    /// Only a freshly verified provider state may bind an unbound invitation.
    func configure(session: ShopperSession?, sharedStoreIdentifier: String? = nil,
                   transport: (any HomeInvitationTransport)? = nil) {
        self.session = session
        self.sharedStoreIdentifier = sharedStoreIdentifier
        self.transport = transport
        hasVerifiedAccount = session != nil
        if allEntries.contains(where: { !$0.activationResolved && $0.state != .dismissed }) {
            persistedActivationHold = true
        }
        publish()
        // Submit synchronously to preserve scene/account command order on the worker queue.
        submit({ try $0.setSession(session) }) { [weak self] result in
            guard let self else { return }
            if case .failure = result { problem = "The invitation could not be saved. Try again after reopening the app." }
            process()
        }
    }

    func retry(_ id: UUID) {
        submit({ try $0.retry(id: id) }) { [weak self] result in
            guard let self else { return }
            if case .failure = result { problem = "This invitation cannot be retried yet. Reopen its original link if the problem continues." }
            else { problem = nil }
            process()
        }
    }

    func retryAndWait(_ id: UUID) async throws {
        try await perform { try $0.retry(id: id) }
        problem = nil
        process()
    }

    func dismiss(_ id: UUID) {
        let change = allEntries.first(where: { $0.id == id }).map { beginChoiceChange($0.identity) }
        submit({ try $0.dismiss(id: id) }) { [weak self] result in
            if let change { self?.pendingChoiceChanges.removeValue(forKey: change) }
            if case .failure = result { self?.problem = "The invitation could not be dismissed. Try again." }
            self?.publish()
        }
    }

    func dismissAndWait(_ id: UUID) async throws {
        let change = allEntries.first(where: { $0.id == id }).map { beginChoiceChange($0.identity) }
        defer { if let change { pendingChoiceChanges.removeValue(forKey: change) }; publish() }
        try await perform { try $0.dismiss(id: id) }
    }

    func requestOpen(_ id: UUID) async throws {
        try await perform { try $0.requestOpen(id: id) }
        process()
    }

    func deferOpen(_ id: UUID, expectedSession: ShopperSession? = nil) async throws {
        let change = allEntries.first(where: { $0.id == id }).map { beginChoiceChange($0.identity) }
        defer { if let change { pendingChoiceChanges.removeValue(forKey: change) }; publish() }
        try await perform { try $0.deferOpen(id: id, expectedSession: expectedSession) }
    }

    func resolveActivation(_ id: UUID) async throws {
        let change = allEntries.first(where: { $0.id == id }).map { beginChoiceChange($0.identity) }
        defer { if let change { pendingChoiceChanges.removeValue(forKey: change) }; publish() }
        try await perform { try $0.resolveActivation(id: id) }
    }
    func checkAgain() {
        submit({ _ in () }) { [weak self] result in
            if case .success = result { self?.process() }
        }
    }

    private func publish() {
        hasPendingActivation = persistedActivationHold || pendingIngress > 0
        entries = allEntries.filter { entry in
            let needsAttention: Bool
            switch entry.state {
            case .ready, .failed: needsAttention = entry.acceptanceAttempted
            default: needsAttention = false
            }
            return (entry.session == nil || entry.session == session)
                && (!entry.dismissalRequested || needsAttention)
                && !entry.activationResolved && entry.state != .dismissed
        }
        onChange?()
    }

    private func submit<Value: Sendable>(_ operation: @escaping @Sendable (HomeInvitationInbox) throws -> Value,
                                        completion: @escaping @MainActor (Result<Value, Error>) -> Void) {
        pendingWork += 1
        worker.perform(operation) { result in
            Task { @MainActor [self] in
                self.pendingWork -= 1
                switch result {
                case .success(let result):
                    let snapshot = result.snapshot
                    if snapshot.revision >= self.snapshotRevision {
                        self.snapshotRevision = snapshot.revision
                        self.allEntries = snapshot.entries
                        self.loaded = true
                        self.persistedActivationHold = snapshot.currentSession == self.session ? snapshot.hasPendingActivation
                            : self.allEntries.contains { !$0.activationResolved && ($0.state != .dismissed || $0.acceptanceAttempted) }
                        self.publish()
                    }
                    completion(.success(result.value))
                case .failure(let error): completion(.failure(error))
                }
            }
        }
    }

    private func perform<Value: Sendable>(_ operation: @escaping @Sendable (HomeInvitationInbox) throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            submit(operation) { continuation.resume(with: $0) }
        }
    }

    private func process() {
        if draining { drainAgain = true; return }
        guard loaded, let session, let store = sharedStoreIdentifier, let transport else { return }
        draining = true
        Task {
            defer {
                draining = false
                publish()
                if drainAgain { drainAgain = false; process() }
            }
            for entry in allEntries where entry.session == session && entry.state == .queued {
                guard self.session == session, self.sharedStoreIdentifier == store else { return }
                do {
                    let attempt = try await perform { try $0.beginAcceptance(id: entry.id, sharedStoreIdentifier: store) }
                    do {
                        let alreadyJoined: Bool
                        if attempt.requiresNativeAcceptance { alreadyJoined = false }
                        else { alreadyJoined = try await transport.existingShare(identity: attempt.identity.share) }
                        if !alreadyJoined {
                            try await transport.accept(metadataArchive: attempt.metadataArchive, identity: attempt.identity.share)
                        }
                        _ = try await perform { try $0.finishAcceptance(attempt) }
                    } catch {
                        let message = Self.message(for: error)
                        _ = try await perform { try $0.finishAcceptance(attempt, failure: .acceptance(message)) }
                    }
                } catch { problem = "The invitation could not be saved. Try again." }
            }
            for entry in allEntries where entry.session == session && entry.state == .loading {
                guard self.session == session, self.sharedStoreIdentifier == store else { return }
                do {
                    let attempt = try await perform { try $0.beginImportResolution(id: entry.id, sharedStoreIdentifier: store) }
                    if let graph = try await transport.importedHome(identity: attempt.identity.share) {
                        _ = try await perform { try $0.markReady(attempt, graph: graph) }
                    }
                    importProblems.removeValue(forKey: entry.id)
                } catch {
                    importProblems[entry.id] = "The home’s groceries could not be loaded yet. Check your connection and try again."
                }
            }
        }
    }

    private static func message(for error: Error) -> String {
        guard let cloudError = error as? CKError else {
            return "The invitation could not be completed. Check your iCloud account and try again."
        }
        switch cloudError.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            return "iCloud could not be reached. Check your connection and try again."
        case .notAuthenticated: return "Sign in to iCloud, then try the invitation again."
        case .operationCancelled: return "Joining was cancelled. You can try again."
        case .unknownItem: return "iCloud could not find this invitation. Ask the owner for a new link."
        case .permissionFailure: return "iCloud did not allow this invitation. Ask the owner to check your access."
        default: return "The invitation could not be completed. Try again or ask the owner for a new link."
        }
    }
}
