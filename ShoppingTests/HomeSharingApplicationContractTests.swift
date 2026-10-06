import CloudKit
import CoreData
import XCTest
@testable import Shopping

@MainActor
final class HomeSharingApplicationContractTests: XCTestCase {
    func testManagedNamedActionsUseOwnerLocalAssociationAndRetainLinkAcrossReopen() async throws {
        let f = try await HomeSharingContractFixture.make(self)
        func actions() -> HomeNamedInvitationActions {
            HomeNamedInvitationActions.managed(scope: f.scope, coordinator: f.coordinator, context: {
                let transport = f.membership
                let share = try await transport.localInvitationShare(scope: f.scope)
                return .init(journalURL: f.journalURL, transport: transport, share: share,
                    validate: { try f.authority.validate() })
            }, prepareShare: { retry in
                _ = try await f.provisioner.prepare(scope: f.scope, journalURL: f.provisionURL,
                    transport: f.sharing, retryInterrupted: retry)
            })
        }
        let initial = try await actions().load()
        XCTAssertTrue(initial.isEmpty)
        let draft = try await actions().prepare("Beka")
        let saved = try await actions().load()
        XCTAssertEqual(saved.first?.id, draft.id)
        XCTAssertEqual(f.backend.counts.creates, 0)
        let delivery = try await actions().create(draft.id, false)
        XCTAssertNil(try HomeInviteJournal(url: f.journalURL).load(scope: f.scope))
        try f.reopen()
        let loaded = try await actions().load()
        XCTAssertEqual(loaded.first?.participantID, delivery.participantID)
        let reused = try await actions().create(draft.id, false)
        XCTAssertEqual(reused.participantID, delivery.participantID)
        XCTAssertEqual(f.backend.counts.saves, 1)
    }

    func testCachedOwnerCanReadAndEditInvitationHistoryWithoutMembershipAuthority() async throws {
        let f = try await HomeSharingContractFixture.make(self)
        _ = try await f.provisioner.prepare(scope: f.scope, journalURL: f.provisionURL, transport: f.sharing)
        let share = try await f.membership.localInvitationShare(scope: f.scope)
        let draft = try await f.coordinator.prepareInvitation(name: "Beka", scope: f.scope, share: share, transport: f.membership)
        let offline = try ShopperSessionProvider(containerIdentifier: f.scope.containerIdentifier,
            environment: f.scope.environment, cacheDirectory: f.directory.appendingPathComponent("account"),
            lookup: .init(status: { throw CKError(.networkUnavailable) }, recordName: { "unused" }),
            notifications: NotificationCenter())
        await offline.refresh()
        XCTAssertEqual(offline.state, .cached(try f.provider.currentSession()))
        let cart = PersonalCartService(persistence: f.persistence, sessionProvider: offline)
        let transport = ManagedHomeMembershipTransport(persistence: f.persistence, authority: f.authority,
            privateRecords: cart, backend: f.backend)
        let cachedShare = try await transport.localInvitationShare(scope: f.scope)
        XCTAssertEqual(cachedShare, share)
        try await f.coordinator.renameInvitation(recordID: draft.id, name: "Beka Smith", scope: f.scope,
            share: share, transport: transport)
        let records = try await f.coordinator.invitationRecords(scope: f.scope, share: share, transport: transport)
        XCTAssertEqual(records.first?.name, "Beka Smith")
        do {
            _ = try await transport.refresh(scope: f.scope)
            XCTFail("Cached history authority cannot authorize online membership")
        } catch { XCTAssertEqual((error as? CKError)?.code, .networkUnavailable) }
    }

    func testOwnerInviteTraversesPersistedEquivalentReplicasBeforePresentingDelivery() async throws {
        let f = try await HomeSharingContractFixture.make(self, replicatedEvents: true)
        let model = f.model()
        await model.refresh()
        XCTAssertTrue(model.canInvite)
        XCTAssertEqual(model.snapshot?.source, .localUnshared)
        await model.invite()
        let delivery = try XCTUnwrap(model.delivery)
        XCTAssertNil(model.error)
        XCTAssertEqual(delivery.scope, f.scope)
        XCTAssertEqual(model.snapshot?.source, .server)
        XCTAssertEqual(model.snapshot?.pendingCount, 1)
        XCTAssertEqual(f.backend.counts.creates, 1)
        XCTAssertEqual(f.backend.counts.saves, 1)
        let intent = try XCTUnwrap(HomeInviteJournal(url: f.journalURL).load(scope: f.scope))
        XCTAssertEqual(intent.phase, .applied)
        XCTAssertEqual(intent.material.participantID, delivery.participantID)
        let records = try f.persistence.container.viewContext.performAndWait {
            try f.persistence.container.viewContext.fetch(NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord"))
        }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.id)).count, 1)
        XCTAssertEqual(Set(records.map(\.objectID)).count, 2)
        let lookedUp = Set(f.backend.associationLookups.flatMap { $0 })
        XCTAssertTrue(records.allSatisfy { lookedUp.contains($0.objectID.uriRepresentation()) })
    }

    func testGraphMutationAtCreateBoundaryIsValidatedBeforeExternalSubmission() async throws {
        let f = try await HomeSharingContractFixture.make(self)
        f.backend.setBeforeCreate {
            try await MainActor.run {
                let context = f.persistence.container.viewContext
                try context.performAndWait {
                    let root = try XCTUnwrap(context.fetch(Household.fetchRequest()).first), id = UUID()
                    for _ in 0..<2 {
                        let category = Category(context: context)
                        category.id = id; category.household = root
                    }
                    try context.save()
                }
            }
        }
        let model = f.model()
        await model.refresh(); await model.invite()
        XCTAssertEqual(model.error, HomeShareGraphValidator.Failure.ambiguousIdentity.localizedDescription)
        XCTAssertNil(model.delivery); XCTAssertNil(model.pending)
        XCTAssertNil(f.backend.share)
        XCTAssertEqual(f.backend.counts.creates, 0); XCTAssertEqual(f.backend.counts.saves, 0)
        XCTAssertNil(try HomeInviteJournal(url: f.journalURL).load(scope: f.scope))
        XCTAssertTrue(try XCTUnwrap(HomeShareProvisioningJournal(url: f.provisionURL).existingIntent(scope: f.scope)).attempted)
    }

    func testInvalidDomainIdentityStopsInviteBeforeExternalWriteOrJournal() async throws {
        let f = try await HomeSharingContractFixture.make(self)
        let context = f.persistence.container.viewContext
        try context.performAndWait {
            let root = try XCTUnwrap(context.fetch(Household.fetchRequest()).first), id = UUID()
            for _ in 0..<2 {
                let category = Category(context: context)
                category.id = id; category.household = root
            }
            try context.save()
        }
        let model = f.model()
        await model.refresh(); await model.invite()
        XCTAssertEqual(model.error, HomeShareGraphValidator.Failure.ambiguousIdentity.localizedDescription)
        XCTAssertNil(model.delivery); XCTAssertNil(model.pending)
        XCTAssertEqual(f.backend.counts.creates, 0); XCTAssertEqual(f.backend.counts.saves, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.provisionURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.journalURL.path))
    }

    func testAssociatedPrivateRecordStopsNewInvitationAndRetainsPrivateData() async throws {
        let f = try await HomeSharingContractFixture.make(self)
        _ = try await f.provisioner.prepare(scope: f.scope, journalURL: f.provisionURL, transport: f.sharing)
        let context = f.persistence.container.viewContext
        let id = try context.performAndWait {
            let record = PersonalCartRecord(context: context)
            record.id = UUID(); record.accountBinding = f.scope.accountBinding
            try context.save()
            return record.objectID
        }
        f.backend.associatePrivateObject(id)
        let model = f.model()
        await model.refresh(); await model.invite()
        XCTAssertEqual(model.error, HomeShareGraphValidator.Failure.privateObject.localizedDescription)
        XCTAssertNil(model.delivery); XCTAssertNil(model.pending)
        XCTAssertEqual(f.backend.counts.creates, 1); XCTAssertEqual(f.backend.counts.saves, 0)
        XCTAssertNil(try HomeInviteJournal(url: f.journalURL).load(scope: f.scope))
        XCTAssertNoThrow(try context.existingObject(with: id))
    }

    func testUnavailableLinkPendingStateSurvivesOfflineSQLiteReopenAndRecoversSameInvitation() async throws {
        let f = try await HomeSharingContractFixture.make(self)
        f.backend.setLinksReady(false)
        let model = f.model()
        await model.refresh(); await model.invite()
        XCTAssertNil(model.delivery)
        let pending = try XCTUnwrap(model.pending)
        XCTAssertEqual(pending.phase, .applied)
        XCTAssertEqual(model.error, HomeMembershipError.missingURL.localizedDescription)
        f.backend.setOffline(true)
        try f.reopen()
        let reopened = f.model()
        await reopened.refresh()
        XCTAssertEqual(reopened.pending, pending)
        XCTAssertFalse(reopened.isCurrent)
        XCTAssertEqual(f.backend.counts.saves, 1)
        f.backend.setOffline(false); f.backend.setLinksReady(true)
        await reopened.refresh(); await reopened.invite()
        let delivery = try XCTUnwrap(reopened.delivery)
        XCTAssertEqual(delivery.id, pending.id)
        XCTAssertEqual(delivery.participantID, pending.participantID)
        XCTAssertEqual(f.backend.counts.creates, 1); XCTAssertEqual(f.backend.counts.saves, 1)
    }

    func testLostSaveCompletionRecoversAppliedMembershipWithoutDuplicateWriteAfterReopen() async throws {
        let f = try await HomeSharingContractFixture.make(self)
        f.backend.setNextSave(.applyThenLoseCompletion)
        let model = f.model()
        await model.refresh(); await model.invite()
        let first = try XCTUnwrap(model.delivery)
        XCTAssertNil(model.error)
        try f.reopen()
        let reopened = f.model()
        await reopened.refresh(); await reopened.invite()
        let second = try XCTUnwrap(reopened.delivery)
        XCTAssertEqual(second.id, first.id); XCTAssertEqual(second.participantID, first.participantID)
        XCTAssertEqual(f.backend.counts.creates, 1); XCTAssertEqual(f.backend.counts.saves, 1)
    }

    func testOfflinePreparationAfterReopenRequiresExplicitSameRootRetry() async throws {
        let f = try await HomeSharingContractFixture.make(self)
        f.backend.setOffline(true)
        let model = f.model()
        await model.refresh(); await model.invite()
        XCTAssertNil(model.delivery); XCTAssertNil(model.pending)
        XCTAssertTrue(model.needsPreparationRetry)
        let original = try XCTUnwrap(HomeShareProvisioningJournal(url: f.provisionURL).existingIntent(scope: f.scope))
        XCTAssertTrue(original.attempted)
        XCTAssertNil(original.identity)
        XCTAssertEqual(f.backend.counts.creates, 1)
        try f.reopen()
        f.backend.setOffline(false)
        let reopened = f.model()
        await reopened.refresh(); await reopened.invite()
        XCTAssertEqual(reopened.error, HomeSharingError.retryRequired.localizedDescription)
        XCTAssertTrue(reopened.needsPreparationRetry)
        XCTAssertEqual(f.backend.counts.creates, 1)
        await reopened.invite(retryPreparation: true)
        XCTAssertNotNil(reopened.delivery)
        XCTAssertNil(reopened.error)
        let restored = try XCTUnwrap(HomeShareProvisioningJournal(url: f.provisionURL).existingIntent(scope: f.scope))
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.scope, original.scope)
        XCTAssertEqual(restored.identity, f.backend.identity)
        XCTAssertEqual(f.backend.counts.creates, 2); XCTAssertEqual(f.backend.counts.saves, 1)
    }

    func testLostCreateCompletionRecoversManagedAssociationBeforeMembershipWrite() async throws {
        let f = try await HomeSharingContractFixture.make(self)
        f.backend.setNextCreate(.applyThenLoseCompletion)
        let model = f.model()
        await model.refresh(); await model.invite()
        let first = try XCTUnwrap(model.delivery)
        XCTAssertNil(model.error)
        XCTAssertEqual(try HomeShareProvisioningJournal(url: f.provisionURL).existingIntent(scope: f.scope)?.identity,
            f.backend.identity)
        try f.reopen()
        let reopened = f.model()
        await reopened.refresh(); await reopened.invite()
        XCTAssertEqual(reopened.delivery?.participantID, first.participantID)
        XCTAssertEqual(f.backend.counts.creates, 1); XCTAssertEqual(f.backend.counts.saves, 1)
    }

    func testUnobservedSaveOutcomeRemainsSubmittedAfterReopenWithoutAnotherWrite() async throws {
        let f = try await HomeSharingContractFixture.make(self)
        f.backend.setNextSave(.loseCompletionWithoutApplying)
        let model = f.model()
        await model.refresh(); await model.invite()
        let pending = try XCTUnwrap(model.pending)
        XCTAssertEqual(pending.phase, .submitted)
        XCTAssertEqual(model.error, HomeMembershipError.outcomeUncertain.localizedDescription)
        try f.reopen()
        let reopened = f.model()
        await reopened.refresh(); await reopened.invite()
        XCTAssertEqual(reopened.pending, pending); XCTAssertNil(reopened.delivery)
        XCTAssertEqual(reopened.error, HomeMembershipError.outcomeUncertain.localizedDescription)
        XCTAssertEqual(f.backend.counts.saves, 1)
    }

    func testAcceptedMembershipRetiresPendingJournalAndAllowsDistinctNextInvitation() async throws {
        let f = try await HomeSharingContractFixture.make(self)
        let model = f.model()
        await model.refresh(); await model.invite()
        let first = try XCTUnwrap(model.delivery)
        try f.backend.accept(first.participantID)
        try f.reopen()
        let reopened = f.model()
        await reopened.refresh()
        XCTAssertNil(reopened.pending)
        XCTAssertEqual(reopened.snapshot?.acceptedOtherCount, 1)
        XCTAssertEqual(reopened.snapshot?.pendingCount, 0)
        await reopened.invite()
        let second = try XCTUnwrap(reopened.delivery)
        XCTAssertNotEqual(second.participantID, first.participantID)
        XCTAssertEqual(f.backend.counts.creates, 1); XCTAssertEqual(f.backend.counts.saves, 2)
    }

    func testAuthorityRetirementAtSubmissionBoundaryPreventsWriteAndKeepsPreparedIntent() async throws {
        let f = try await HomeSharingContractFixture.make(self), authority = f.authority
        f.backend.setBeforeSave { authority.retire() }
        let model = f.model()
        await model.refresh(); await model.invite()
        XCTAssertNil(model.delivery)
        XCTAssertEqual(model.error, "This home action couldn’t be completed. Try again.")
        XCTAssertEqual(f.backend.counts.saves, 0)
        XCTAssertEqual(try HomeInviteJournal(url: f.journalURL).load(scope: f.scope)?.phase, .prepared)
    }

    func testAccountInvalidationAtSubmissionBoundaryPreventsWriteAndKeepsPreparedIntent() async throws {
        let f = try await HomeSharingContractFixture.make(self), notifications = f.notifications
        f.backend.setBeforeSave { notifications.post(name: .CKAccountChanged, object: nil) }
        let model = f.model()
        await model.refresh(); await model.invite()
        XCTAssertNil(model.delivery)
        XCTAssertEqual(model.error, HomeMembershipError.scopeChanged.localizedDescription)
        XCTAssertEqual(f.backend.counts.saves, 0)
        XCTAssertEqual(try HomeInviteJournal(url: f.journalURL).load(scope: f.scope)?.phase, .prepared)
    }

    func testPermissionLossWithholdsInviteAndCannotSubmitAgainstEarlierSnapshot() async throws {
        let f = try await HomeSharingContractFixture.make(self)
        _ = try await f.provisioner.prepare(scope: f.scope, journalURL: f.provisionURL, transport: f.sharing)
        let expected = try await f.membership.refresh(scope: f.scope)
        let material = try await f.membership.makeInvitationParticipant(scope: f.scope)
        f.backend.setEditable(false)
        do {
            _ = try await f.membership.addInvitation(material, expected: expected)
            XCTFail("Earlier owner observation cannot authorize a write after permission loss")
        } catch let error as HomeMembershipNotSubmitted {
            XCTAssertEqual(error.reason as? HomeMembershipError, .unsupportedAccess)
        }
        let model = f.model()
        await model.refresh()
        XCTAssertFalse(model.canInvite); XCTAssertNil(model.delivery)
        XCTAssertEqual(f.backend.counts.saves, 0)
    }
}
