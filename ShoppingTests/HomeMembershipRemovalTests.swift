import XCTest
@testable import Shopping

@MainActor
final class HomeMembershipRemovalTests: XCTestCase {
    private func fixture() throws -> (URL, ActiveHomeScope, MembershipTransportDouble) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.removal",
            environment: "Development", accountRecordName: "owner")
        let scope = ActiveHomeScope(session: session, graph: HomeGraphIdentity(storeIdentifier: "store",
            rootURI: "x-coredata://store/Household/p1", householdID: UUID(), listID: UUID()))
        let url = directory.appendingPathComponent("intent.json")
        return (url, scope, MembershipTransportDouble(scope: scope, journalURL: url))
    }

    private func submitted(_ url: URL, scope: ActiveHomeScope) throws -> HomeInviteJournal.Intent {
        let journal = HomeInviteJournal(url: url)
        var intent = try journal.begin(scope: scope, share: MembershipTransportDouble.share,
            material: HomeInviteMaterial(participantID: "uncertain", archive: Data([0, 255])), baseChangeTag: "old")
        intent.phase = .submitted
        try journal.update(intent)
        return intent
    }

    func testCancelUncertainAttemptAllowsSeparateNewInviteAndRetainsLateRemovalAuthority() async throws {
        let (url, scope, transport) = try fixture()
        let old = try submitted(url, scope: scope)
        let coordinator = HomeMembershipCoordinator()
        let confirmation = try await coordinator.prepareRemoval(purpose: .cancelInvitation,
            scope: scope, journalURL: url, transport: transport)
        XCTAssertEqual(confirmation.removal.cancelledInvitationID, old.id)
        let cancelled = try await coordinator.confirmRemoval(confirmation, scope: scope, journalURL: url, transport: transport)
        XCTAssertNotNil(cancelled.removals.first?.absentObservedAt)
        XCTAssertNil(try HomeInviteJournal(url: url).load(scope: scope))
        let before = await transport.counts()
        XCTAssertEqual(before.created, 0, "Cancellation must not create another invitation.")
        let fresh = try await HomeMembershipCoordinator().invite(scope: scope, journalURL: url, transport: transport)
        XCTAssertNotEqual(fresh.participantID, old.material.participantID)
        await transport.include(old.material.participantID, acceptance: .pending)
        let recovered = try await HomeMembershipCoordinator().refresh(scope: scope, journalURL: url, transport: transport)
        XCTAssertFalse(recovered.members.contains { $0.id == old.material.participantID })
        XCTAssertTrue(recovered.members.contains { $0.id == fresh.participantID })
        let removed = await transport.removedParticipants
        XCTAssertEqual(removed, [[old.material.participantID]])
        XCTAssertEqual(try HomeInviteJournal(url: url).load(scope: scope)?.id, fresh.id)
    }

    func testStopSharingOnlyRemovesConfirmedParticipantsAndKeepsOwner() async throws {
        let (url, scope, transport) = try fixture()
        await transport.include("accepted", acceptance: .accepted)
        await transport.include("pending", acceptance: .pending)
        let coordinator = HomeMembershipCoordinator()
        let confirmation = try await coordinator.prepareRemoval(purpose: .stopSharing,
            scope: scope, journalURL: url, transport: transport)
        await transport.include("later", acceptance: .pending)
        let snapshot = try await coordinator.confirmRemoval(confirmation, scope: scope, journalURL: url, transport: transport)
        XCTAssertEqual(Set(snapshot.members.map(\.id)), ["owner", "later"])
        XCTAssertEqual(snapshot.share, MembershipTransportDouble.share)
        let removed = await transport.removedParticipants
        XCTAssertEqual(removed, [["accepted", "pending"]])
    }

    func testLostRemovalCallbackResolvesOnlyAfterFreshAbsence() async throws {
        let (url, scope, transport) = try fixture()
        await transport.include("friend", acceptance: .accepted)
        await transport.setRemovalMode(.applyThenFail)
        let coordinator = HomeMembershipCoordinator()
        let confirmation = try await coordinator.prepareRemoval(purpose: .removeMember, participantID: "friend",
            scope: scope, journalURL: url, transport: transport)
        let snapshot = try await coordinator.confirmRemoval(confirmation, scope: scope, journalURL: url, transport: transport)
        XCTAssertNotNil(snapshot.removals.first?.absentObservedAt)
        XCTAssertFalse(snapshot.removals.first?.requiresRetry ?? true)
    }

    func testFailedRemovalRequiresExplicitRetryAndNeverBroadensCapturedSet() async throws {
        let (url, scope, transport) = try fixture()
        await transport.include("friend", acceptance: .accepted)
        await transport.setRemovalMode(.fail)
        let coordinator = HomeMembershipCoordinator()
        let confirmation = try await coordinator.prepareRemoval(purpose: .stopSharing,
            scope: scope, journalURL: url, transport: transport)
        do {
            _ = try await coordinator.confirmRemoval(confirmation, scope: scope, journalURL: url, transport: transport)
            XCTFail("A still-present participant cannot count as removed")
        } catch { XCTAssertEqual(error as? HomeMembershipError, .shareUnavailable) }
        await transport.setRemovalMode(.succeed)
        await transport.include("later", acceptance: .pending)
        let unchanged = try await HomeMembershipCoordinator().refresh(scope: scope, journalURL: url, transport: transport)
        XCTAssertTrue(unchanged.removals.first?.requiresRetry ?? false)
        XCTAssertTrue(unchanged.members.contains { $0.id == "friend" })
        let before = await transport.removedParticipants
        XCTAssertEqual(before.count, 1)
        let retried = try await coordinator.retryRemovals(scope: scope, journalURL: url, transport: transport)
        XCTAssertEqual(Set(retried.members.map(\.id)), ["owner", "later"])
        let after = await transport.removedParticipants
        XCTAssertEqual(after, [["friend"], ["friend"]])
    }

    func testPrivateRetentionFailureDoesNotEraseUncertainIntent() async throws {
        let (url, scope, transport) = try fixture()
        let old = try submitted(url, scope: scope)
        let coordinator = HomeMembershipCoordinator()
        let confirmation = try await coordinator.prepareRemoval(purpose: .cancelInvitation,
            scope: scope, journalURL: url, transport: transport)
        await transport.setRetentionFailure(true)
        do {
            _ = try await coordinator.confirmRemoval(confirmation, scope: scope, journalURL: url, transport: transport)
            XCTFail("Must retain cancellation before releasing the old intent")
        } catch { XCTAssertEqual(error as? HomeMembershipError, .shareUnavailable) }
        XCTAssertEqual(try HomeInviteJournal(url: url).load(scope: scope), old)
        XCTAssertFalse(try HomeInviteJournal(url: url).isSuppressed(old.material.participantID, scope: scope))
    }

    func testOwnerCannotBeTargetedAndContributorCannotPrepareRemoval() async throws {
        let (url, scope, transport) = try fixture()
        let coordinator = HomeMembershipCoordinator()
        do {
            _ = try await coordinator.prepareRemoval(purpose: .removeMember, participantID: "owner",
                scope: scope, journalURL: url, transport: transport)
            XCTFail("Owner removal must fail")
        } catch { XCTAssertEqual(error as? HomeMembershipError, .invalidParticipant) }
        await transport.setOwner(false)
        do {
            _ = try await coordinator.prepareRemoval(purpose: .stopSharing, scope: scope, journalURL: url, transport: transport)
            XCTFail("Contributor removal must fail")
        } catch { XCTAssertEqual(error as? HomeMembershipError, .ownerRequired) }
        let removed = await transport.removedParticipants
        XCTAssertTrue(removed.isEmpty)
    }

    func testVersionOneJournalMigratesAndArchivedCancellationSurvivesRestart() async throws {
        struct VersionOne: Encodable { let version = 1; let intent: HomeInviteJournal.Intent }
        let (url, scope, transport) = try fixture()
        let old = try submitted(url, scope: scope)
        try JSONEncoder().encode(VersionOne(intent: old)).write(to: url, options: .atomic)
        XCTAssertEqual(try HomeInviteJournal(url: url).load(scope: scope), old)
        let coordinator = HomeMembershipCoordinator()
        let confirmation = try await coordinator.prepareRemoval(purpose: .cancelInvitation,
            scope: scope, journalURL: url, transport: transport)
        _ = try await coordinator.confirmRemoval(confirmation, scope: scope, journalURL: url, transport: transport)
        let journal = HomeInviteJournal(url: url)
        XCTAssertNil(try journal.load(scope: scope))
        XCTAssertTrue(try journal.isSuppressed(old.material.participantID, scope: scope))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 2)
        let archives = try XCTUnwrap(json["archivedInvitations"] as? [[String: Any]])
        XCTAssertEqual(archives.count, 1)
        XCTAssertEqual(archives.first?["id"] as? String, old.id.uuidString)
        XCTAssertThrowsError(try journal.update(old)) {
            XCTAssertEqual($0 as? HomeMembershipError, .invitationCancelled)
        }
    }

    func testImportedCancellationSuppressesExistingIntentBeforeResendOrNewInvite() async throws {
        let (url, scope, transport) = try fixture()
        let old = try submitted(url, scope: scope)
        await transport.include(old.material.participantID, acceptance: .pending)
        let removal = HomeMembershipRemoval(id: UUID(), origin: scope, share: old.share, ownerParticipantID: "owner",
            participantIDs: [old.material.participantID], cancelledInvitationID: old.id, purpose: .cancelInvitation, confirmedAt: Date())
        await transport.importAuthorizations([removal])
        do {
            _ = try await HomeMembershipCoordinator().invite(scope: scope, journalURL: url, transport: transport)
            XCTFail("Continue invitation cannot silently become a fresh invitation after imported cancellation")
        } catch { XCTAssertEqual(error as? HomeMembershipError, .invitationCancelled) }
        do {
            _ = try await HomeMembershipCoordinator().resend(participantID: old.material.participantID,
                scope: scope, journalURL: url, transport: transport)
            XCTFail("Cancelled capability cannot be resent")
        } catch { XCTAssertEqual(error as? HomeMembershipError, .invitationCancelled) }
        let counts = await transport.counts()
        XCTAssertEqual(counts.created, 0)
        XCTAssertEqual(counts.urls, 0)
    }

    func testCancellationFencesHeldNativeCallbackBeforeURLDelivery() async throws {
        let (url, scope, transport) = try fixture()
        await transport.setMode(.hold)
        let coordinator = HomeMembershipCoordinator()
        let invitation = Task { try await coordinator.invite(scope: scope, journalURL: url, transport: transport) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await transport.isHeld), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard await transport.isHeld else {
            await transport.release(); _ = await invitation.result
            XCTFail("Native add did not reach its callback gate"); return
        }
        var cancellation: Task<HomeMembershipSnapshot, Error>?
        do {
            let old = try XCTUnwrap(HomeInviteJournal(url: url).load(scope: scope))
            let removal = HomeMembershipRemoval(id: UUID(), origin: scope, share: old.share, ownerParticipantID: "owner",
                participantIDs: [old.material.participantID], cancelledInvitationID: old.id, purpose: .cancelInvitation, confirmedAt: Date())
            let confirmation = HomeMembershipRemovalConfirmation(removal: removal, homeName: "Home", memberNames: [])
            let task = Task { try await coordinator.confirmRemoval(confirmation, scope: scope, journalURL: url, transport: transport) }
            cancellation = task
            let queuedDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while await coordinator.activeRequestCount != 2, ContinuousClock.now < queuedDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let queued = await coordinator.activeRequestCount
            XCTAssertEqual(queued, 2)
            XCTAssertTrue(try HomeInviteJournal(url: url).isSuppressed(old.material.participantID, scope: scope))
            await transport.release()
            let results = await (invitation.result, task.result)
            switch results.0 {
            case .success: XCTFail("Cancelled capability escaped through the late callback")
            case .failure(let error): XCTAssertEqual(error as? HomeMembershipError, .invitationCancelled)
            }
            let snapshot = try results.1.get()
            XCTAssertFalse(snapshot.members.contains { $0.id == old.material.participantID })
            let counts = await transport.counts()
            XCTAssertEqual(counts.urls, 0)
        } catch {
            await transport.release()
            invitation.cancel()
            _ = await invitation.result
            if let cancellation {
                cancellation.cancel()
                _ = await cancellation.result
            }
            throw error
        }
    }
}
