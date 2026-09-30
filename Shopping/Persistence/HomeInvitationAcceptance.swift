import Foundation

/// A retained home can outlive its imported graph. Its portable private evidence
/// still identifies the exact server share that must be checked before acceptance.
enum HomeInvitationAcceptance {
    struct Capture: Sendable {
        let scope: HomeEffectScope
        let share: HomeEffectShare
        let storeIdentifier: String
        let nativeRequest: HomeNativeAccessGate.Request?
        let restrictionIDs: Set<UUID>
    }

    /// Called inside the participant-zone turn. A typed loss is retained before
    /// native acceptance can make the share writable again. Failure at any step
    /// leaves acceptance unsubmitted; stale invitation metadata is not evidence.
    static func perform(preflight: any HomeInvitationAccessPreflighting,
        share: HomeEffectShare, session: ShopperSession,
        accept: @Sendable () async throws -> Void) async throws {
        if let capture = try await preflight.captureAcceptance(share: share, session: session) {
            let observation = try await preflight.observeAcceptance(capture)
            try await preflight.persistAcceptance(observation, capture: capture)
        }
        // Private imports can add leave evidence while native observation is suspended.
        try await preflight.validateJoin(share: share, session: session)
        try await accept()
    }
}

protocol HomeInvitationAccessPreflighting: Sendable {
    func validateJoin(share: HomeEffectShare, session: ShopperSession) async throws
    func captureAcceptance(share: HomeEffectShare, session: ShopperSession) async throws -> HomeInvitationAcceptance.Capture?
    func observeAcceptance(_ capture: HomeInvitationAcceptance.Capture) async throws -> ManagedHomeAccessObserver.Observation
    func persistAcceptance(_ observation: ManagedHomeAccessObserver.Observation,
        capture: HomeInvitationAcceptance.Capture) async throws
}
