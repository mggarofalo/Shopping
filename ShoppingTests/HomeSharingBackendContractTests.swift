import CloudKit
import CoreData
import XCTest
@testable import Shopping

@available(iOS 18.0, *)
@MainActor
final class HomeSharingBackendContractTests: XCTestCase {
    func testCreateAssociatesRegisteredGraphAndRejectsReplacementForSameRoot() async throws {
        let f = try await HomeSharingContractFixture.make(self)
        let root = try XCTUnwrap(f.persistence.container.persistentStoreCoordinator.managedObjectID(
            forURIRepresentation: XCTUnwrap(URL(string: f.scope.graph.rootURI))))
        let store = try XCTUnwrap(f.persistence.primaryStore)
        let first = try await f.backend.create(store: store, authorize: {}, prepareGraph: { _ in
                HomeBackendCreation(rootID: root, title: "Contract home", existing: nil)
            })
        do {
            _ = try await f.backend.create(store: store, authorize: {}, prepareGraph: { _ in
                HomeBackendCreation(rootID: root, title: "Contract home", existing: nil)
            })
            XCTFail("The external backend must not forgive duplicate creation")
        } catch StatefulHomeSharingBackend.Failure.alreadyShared {}
        XCTAssertEqual(f.backend.share?.identity, first.identity)
        XCTAssertEqual(f.backend.share?.changeTag, first.changeTag)
        XCTAssertEqual(first.participants.count, 1)
        XCTAssertEqual(first.participants.first?.role, .owner)
        XCTAssertEqual(try f.backend.associatedShares([root])[root]?.identity, first.identity)
    }

    func testSaveChangesOnlyMatchingVersionAndLostCompletionStillCommits() async throws {
        let f = try await HomeSharingContractFixture.make(self)
        _ = try await f.provisioner.prepare(scope: f.scope, journalURL: f.provisionURL, transport: f.sharing)
        let initial = try XCTUnwrap(f.backend.share), store = try XCTUnwrap(f.persistence.primaryStore)
        let material = try ManagedHomeMembershipTransport.makeParticipantMaterial()
        f.backend.setNextSave(.applyThenLoseCompletion)
        do {
            _ = try await f.backend.save(initial, mutation: .add(material), store: store, authorize: {})
            XCTFail("Lost completion must remain visible")
        } catch { XCTAssertEqual((error as? CKError)?.code, .networkFailure) }
        let applied = try XCTUnwrap(f.backend.share)
        XCTAssertNotEqual(applied.changeTag, initial.changeTag)
        XCTAssertEqual(applied.participants.filter { $0.id == material.participantID }.count, 1)
        let other = try ManagedHomeMembershipTransport.makeParticipantMaterial()
        do {
            _ = try await f.backend.save(initial, mutation: .add(other), store: store, authorize: {})
            XCTFail("Stale version must fail")
        } catch { XCTAssertEqual((error as? CKError)?.code, .serverRecordChanged) }
        XCTAssertEqual(f.backend.share?.participants, applied.participants)
        XCTAssertEqual(f.backend.share?.changeTag, applied.changeTag)
    }

    func testOfflineReadAndLinkReadinessDoNotAlterMembershipAndAcceptanceRemovesLink() async throws {
        let f = try await HomeSharingContractFixture.make(self)
        let model = f.model()
        await model.refresh(); await model.invite()
        let delivery = try XCTUnwrap(model.delivery), before = try XCTUnwrap(f.backend.share)
        f.backend.setOffline(true)
        do {
            _ = try await f.backend.fetch(before.identity, scope: f.scope, role: .ownerPrivate)
            XCTFail("Offline fetch must fail")
        } catch { XCTAssertEqual((error as? CKError)?.code, .networkUnavailable) }
        XCTAssertEqual(f.backend.share?.participants, before.participants)
        f.backend.setOffline(false); f.backend.setLinksReady(false)
        XCTAssertNil(try f.backend.invitationURL(before, participantID: delivery.participantID))
        f.backend.setLinksReady(true)
        XCTAssertNotNil(try f.backend.invitationURL(before, participantID: delivery.participantID))
        try f.backend.accept(delivery.participantID)
        XCTAssertNil(try f.backend.invitationURL(before, participantID: delivery.participantID))
        XCTAssertEqual(f.backend.share?.participants.first { $0.id == delivery.participantID }?.acceptance, .accepted)
        XCTAssertEqual(f.backend.counts.saves, 1)
    }
}
