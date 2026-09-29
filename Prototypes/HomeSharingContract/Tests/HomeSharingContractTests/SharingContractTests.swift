import Foundation
import XCTest
@testable import HomeSharingContract

final class SharingContractTests: XCTestCase {
    private let owner = Scope(account: "owner", home: "home", share: "share")

    private func snapshot() -> ShareSnapshot {
        ShareSnapshot(scope: owner, owner: "owner", participants: [
            Participant(id: "claimed-link", acceptance: .accepted, account: "wife"),
            Participant(id: "pending-link", acceptance: .pending)
        ], version: 1, groceryIDs: ["milk", "one-time", "archived-restriction"],
                      privateCartIDs: ["owner-cart", "wife-cart"])
    }

    private func withFile(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("checkpoint.json"))
    }

    func testInvitationRequiresExportAndCanBeClaimedWithoutAHandle() throws {
        try withFile { url in
            let model = try SharingContract(url: url, scope: owner, actor: "owner")
            let cloud = MockCloud(snapshot())
            let id = UUID()
            try model.prepare(id: id, snapshot: cloud.share, action: .inviteLink("new-link"))
            XCTAssertFalse(model.canDeliverInvitation(id))
            let intent = try model.beginExport(id)
            XCTAssertFalse(model.canDeliverInvitation(id))
            try cloud.apply(intent)
            try model.reconcile(id, observed: cloud.share)
            XCTAssertTrue(model.canDeliverInvitation(id))
            XCTAssertNil(cloud.share.participants.last?.account)
            // Dismissing Messages/Share sheet has no membership rollback. The pending
            // link can be sent again, or explicitly revoked with a new confirmed intent.
            let reopened = try SharingContract(url: url, scope: owner, actor: "owner")
            XCTAssertTrue(reopened.canDeliverInvitation(id))
            try cloud.acceptLink("new-link", as: "new-contributor")
            XCTAssertThrowsError(try cloud.acceptLink("new-link", as: "forwarded-recipient"))
            XCTAssertEqual(cloud.share.participants.last?.account, "new-contributor")
        }
    }

    func testOwnerRemoveOneAndRemoveAllPreserveOwnerGraphAndPrivateCarts() throws {
        for targets: Set<String> in [["claimed-link"], ["claimed-link", "pending-link"]] {
            try withFile { url in
                let cloud = MockCloud(snapshot())
                let before = cloud.share
                let model = try SharingContract(url: url, scope: owner, actor: "owner")
                let id = UUID()
                try model.prepare(id: id, snapshot: before, action: .remove(targets))
                try cloud.apply(model.beginExport(id))
                try model.reconcile(id, observed: cloud.share)
                XCTAssertEqual(model.checkpoint.intents.first?.stage, .applied)
                XCTAssertEqual(cloud.share.groceryIDs, before.groceryIDs)
                XCTAssertEqual(cloud.share.privateCartIDs, before.privateCartIDs)
                XCTAssertEqual(cloud.share.scope, before.scope)
                XCTAssertTrue(targets.isDisjoint(with: cloud.share.participants.map(\.id)))
                if targets.contains("pending-link") {
                    XCTAssertThrowsError(try cloud.acceptLink("pending-link", as: "stranger"))
                }
            }
        }
    }

    func testConcurrentInvitationDoesNotExpandCapturedRemoval() throws {
        try withFile { url in
            let model = try SharingContract(url: url, scope: owner, actor: "owner")
            let cloud = MockCloud(snapshot())
            let id = UUID()
            try model.prepare(id: id, snapshot: cloud.share,
                              action: .remove(Set(cloud.share.participants.map(\.id))))
            cloud.share.participants.append(Participant(id: "later-link", acceptance: .pending))
            cloud.share.version += 1
            let intent = try model.beginExport(id)
            XCTAssertThrowsError(try cloud.apply(intent))
            try model.reconcile(id, observed: cloud.share)
            XCTAssertEqual(model.checkpoint.intents.first?.stage, .conflict)
            XCTAssertEqual(cloud.share.participants.count, 3)
            // Fresh explicit confirmation captures current membership; no automatic loop.
        }
    }

    func testRestartAfterExportReconcilesWithoutReplayingOldRoster() throws {
        try withFile { url in
            let cloud = MockCloud(snapshot())
            let model = try SharingContract(url: url, scope: owner, actor: "owner")
            let id = UUID()
            try model.prepare(id: id, snapshot: cloud.share, action: .remove(["claimed-link"]))
            try cloud.apply(model.beginExport(id))
            let version = cloud.share.version
            let reopened = try SharingContract(url: url, scope: owner, actor: "owner")
            XCTAssertEqual(reopened.checkpoint.intents.first?.stage, .uncertain)
            XCTAssertThrowsError(try reopened.beginExport(id))
            try reopened.reconcile(id, observed: cloud.share)
            XCTAssertEqual(reopened.checkpoint.intents.first?.stage, .applied)
            XCTAssertEqual(cloud.share.version, version)
        }
    }

    func testFailedExportRemainsUncertainAndCannotDeliverALink() throws {
        try withFile { url in
            let cloud = MockCloud(snapshot())
            cloud.available = false
            let model = try SharingContract(url: url, scope: owner, actor: "owner")
            let id = UUID()
            try model.prepare(id: id, snapshot: cloud.share, action: .inviteLink("unsent-link"))
            XCTAssertThrowsError(try cloud.apply(model.beginExport(id)))
            let reopened = try SharingContract(url: url, scope: owner, actor: "owner")
            XCTAssertFalse(reopened.canDeliverInvitation(id))
            XCTAssertEqual(reopened.checkpoint.intents.first?.stage, .uncertain)
            XCTAssertThrowsError(try reopened.beginExport(id))
            XCTAssertFalse(cloud.share.participants.contains { $0.id == "unsent-link" })
        }
    }

    func testLateCallbackAfterAccountOrHomeSwitchIsQuarantined() throws {
        for scope in [Scope(account: "other", home: "home", share: "share"),
                      Scope(account: "owner", home: "other-home", share: "other-share")] {
            try withFile { url in
                let cloud = MockCloud(snapshot())
                let model = try SharingContract(url: url, scope: owner, actor: "owner")
                let id = UUID()
                try model.prepare(id: id, snapshot: cloud.share, action: .inviteLink("new-link"))
                let intent = try model.beginExport(id)
                model.switchSession(scope: scope, actor: scope.account)
                try cloud.apply(intent) // A request already in flight cannot be recalled.
                try model.reconcile(id, observed: cloud.share)
                XCTAssertEqual(model.checkpoint.intents.first?.stage, .quarantined)
                XCTAssertFalse(model.canDeliverInvitation(id))
            }
        }
    }

    func testContributorLeavePreservesPrivateHistoryAndQuarantinesUnsentEffects() throws {
        try withFile { url in
            let scope = Scope(account: "wife", home: "home", share: "share")
            let initial = LocalCheckpoint(sharedWorkingCopy: ["cached-milk"], privateHistory: ["purchase"],
                                          pendingHouseholdEffects: ["unpublished-receipt"])
            let model = try SharingContract(url: url, scope: scope, actor: "wife", initial: initial)
            let cloud = MockCloud(snapshot())
            let id = UUID()
            try model.prepare(id: id, snapshot: cloud.share, action: .leave)
            XCTAssertEqual(model.checkpoint.sharedWorkingCopy, ["cached-milk"])
            try cloud.apply(model.beginExport(id))
            try model.reconcile(id, observed: cloud.share)
            let reopened = try SharingContract(url: url, scope: scope, actor: "wife")
            XCTAssertTrue(reopened.checkpoint.sharedWorkingCopy.isEmpty)
            XCTAssertEqual(reopened.checkpoint.privateHistory, ["purchase"])
            XCTAssertEqual(reopened.checkpoint.quarantinedEffects, ["unpublished-receipt"])
            XCTAssertTrue(reopened.checkpoint.pendingHouseholdEffects.isEmpty)
            XCTAssertEqual(cloud.share.groceryIDs, snapshot().groceryIDs)
            XCTAssertEqual(cloud.share.privateCartIDs, snapshot().privateCartIDs)
            XCTAssertEqual(cloud.share.participants.map(\.id), ["claimed-link", "pending-link"])
            XCTAssertEqual(cloud.share.participants.first { $0.account == "wife" }?.acceptance, .pending)
        }
    }

    func testContributorCannotManageAnotherHomeButCanOwnTheirOwn() throws {
        try withFile { url in
            let scope = Scope(account: "wife", home: "home", share: "share")
            let model = try SharingContract(url: url, scope: scope, actor: "wife")
            XCTAssertThrowsError(try model.prepare(id: UUID(), snapshot: snapshot(), action: .inviteLink("x")))
            XCTAssertThrowsError(try model.prepare(id: UUID(), snapshot: snapshot(), action: .remove(["pending-link"])))
            let herScope = Scope(account: "wife", home: "her-home", share: "her-share")
            let herHome = ShareSnapshot(scope: herScope, owner: "wife", participants: [], version: 1,
                                       groceryIDs: [], privateCartIDs: [])
            model.switchSession(scope: herScope, actor: "wife")
            XCTAssertNoThrow(try model.prepare(id: UUID(), snapshot: herHome, action: .inviteLink("hers")))
        }
    }

    func testOwnerCannotUseParticipantLeaveAndIDsCannotChangeIntent() throws {
        try withFile { url in
            let model = try SharingContract(url: url, scope: owner, actor: "owner")
            XCTAssertThrowsError(try model.prepare(id: UUID(), snapshot: snapshot(), action: .leave))
            let id = UUID()
            try model.prepare(id: id, snapshot: snapshot(), action: .inviteLink("first"))
            try model.prepare(id: id, snapshot: snapshot(), action: .inviteLink("first"))
            XCTAssertEqual(model.checkpoint.intents.count, 1)
            XCTAssertThrowsError(try model.prepare(id: id, snapshot: snapshot(), action: .inviteLink("second")))
        }
    }

    func testCancelledInvitationCannotBeResentAfterReopen() throws {
        try withFile { url in
            let cloud = MockCloud(snapshot())
            let model = try SharingContract(url: url, scope: owner, actor: "owner")
            let invite = UUID()
            try model.prepare(id: invite, snapshot: cloud.share, action: .inviteLink("cancel-me"))
            try cloud.apply(model.beginExport(invite))
            try model.reconcile(invite, observed: cloud.share)
            XCTAssertTrue(model.canDeliverInvitation(invite))
            let delayedSnapshot = cloud.share
            let cancel = UUID()
            try model.prepare(id: cancel, snapshot: cloud.share, action: .remove(["cancel-me"]))
            try cloud.apply(model.beginExport(cancel))
            try model.reconcile(cancel, observed: cloud.share)
            let reopened = try SharingContract(url: url, scope: owner, actor: "owner")
            XCTAssertFalse(reopened.canDeliverInvitation(invite))
            XCTAssertThrowsError(try reopened.reconcile(invite, observed: delayedSnapshot))
            XCTAssertFalse(reopened.canDeliverInvitation(invite))
            XCTAssertThrowsError(try cloud.acceptLink("cancel-me", as: "someone"))
        }
    }

    func testReconciledFailureCanRetryTheSameLogicalInvitation() throws {
        try withFile { url in
            let cloud = MockCloud(snapshot())
            let model = try SharingContract(url: url, scope: owner, actor: "owner")
            let id = UUID()
            try model.prepare(id: id, snapshot: cloud.share, action: .inviteLink("retry-link"))
            cloud.available = false
            XCTAssertThrowsError(try cloud.apply(model.beginExport(id)))
            XCTAssertThrowsError(try model.reconfirm(id, observed: cloud.share))
            cloud.available = true
            let reopened = try SharingContract(url: url, scope: owner, actor: "owner")
            try reopened.reconcile(id, observed: cloud.share)
            XCTAssertEqual(reopened.checkpoint.intents.first?.stage, .conflict)
            try reopened.reconfirm(id, observed: cloud.share)
            try cloud.apply(reopened.beginExport(id))
            try reopened.reconcile(id, observed: cloud.share)
            XCTAssertEqual(reopened.checkpoint.intents.count, 1)
            XCTAssertEqual(cloud.share.participants.filter { $0.id == "retry-link" }.count, 1)
            XCTAssertTrue(reopened.canDeliverInvitation(id))
            try cloud.acceptLink("retry-link", as: "someone")
            try reopened.reconcile(id, observed: cloud.share)
            XCTAssertFalse(reopened.canDeliverInvitation(id))
        }
    }

    func testFailedCheckpointHasNoExportOrVisibleSuccess() throws {
        try withFile { url in
            let model = try SharingContract(url: url.appendingPathComponent("missing/checkpoint.json"),
                                            scope: owner, actor: "owner")
            let id = UUID()
            XCTAssertThrowsError(try model.prepare(id: id, snapshot: snapshot(), action: .inviteLink("x")))
            XCTAssertTrue(model.checkpoint.intents.isEmpty)
            XCTAssertFalse(model.canDeliverInvitation(id))
            XCTAssertThrowsError(try model.beginExport(id))
        }
    }
}
