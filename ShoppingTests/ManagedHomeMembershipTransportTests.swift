import CloudKit
import XCTest
@testable import Shopping

final class ManagedHomeMembershipTransportTests: XCTestCase {
    func testNativeOneTimeParticipantStartsPendingWithoutRecipientLookupIdentity() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("One-time invitation participants require iOS 18") }
        let participant = try XCTUnwrap(ShoppingMakeOneTimeLinkParticipant(),
            "The public one-time participant factory must be present on this supported runtime")
        // This is an SDK/runtime contract check, not a simulated acceptance result.
        // If it fails, the adapter's pending-only archive validation must be reconsidered.
        XCTAssertEqual(participant.acceptanceStatus, .pending)
        XCTAssertNil(participant.userIdentity.lookupInfo)
        XCTAssertFalse(participant.__participantID.isEmpty)
    }

    func testParticipantMaterialSecureArchivePreservesExactIdentityAndContributorPermission() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("One-time invitation participants require iOS 18") }
        let material = try ManagedHomeMembershipTransport.makeParticipantMaterial()
        XCTAssertFalse(material.archive.isEmpty)
        let participant = try ManagedHomeMembershipTransport.restoredParticipant(material)
        XCTAssertEqual(participant.__participantID, material.participantID)
        XCTAssertEqual(participant.role, .privateUser)
        XCTAssertEqual(participant.permission, .readWrite)
        XCTAssertEqual(participant.acceptanceStatus, .pending)
        XCTAssertNil(participant.userIdentity.lookupInfo)
        let rearchived = try NSKeyedArchiver.archivedData(withRootObject: participant, requiringSecureCoding: true)
        let restored = try ManagedHomeMembershipTransport.restoredParticipant(
            HomeInviteMaterial(participantID: material.participantID, archive: rearchived))
        XCTAssertEqual(restored.__participantID, material.participantID)
        XCTAssertEqual(restored.acceptanceStatus, .pending)
    }

    func testMismatchedParticipantIDAndReadOnlyArchiveAreRejected() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("One-time invitation participants require iOS 18") }
        let material = try ManagedHomeMembershipTransport.makeParticipantMaterial()
        let unrelated = try ManagedHomeMembershipTransport.makeParticipantMaterial()
        XCTAssertNotEqual(material.participantID, unrelated.participantID)
        for id in ["", unrelated.participantID] {
            XCTAssertThrowsError(try ManagedHomeMembershipTransport.restoredParticipant(
                HomeInviteMaterial(participantID: id, archive: material.archive))) {
                XCTAssertEqual($0 as? HomeMembershipError, .invalidParticipant)
            }
        }
        let participant = try ManagedHomeMembershipTransport.restoredParticipant(material)
        participant.permission = .readOnly
        let readOnly = try NSKeyedArchiver.archivedData(withRootObject: participant, requiringSecureCoding: true)
        XCTAssertThrowsError(try ManagedHomeMembershipTransport.restoredParticipant(
            HomeInviteMaterial(participantID: material.participantID, archive: readOnly))) {
            XCTAssertEqual($0 as? HomeMembershipError, .invalidParticipant)
        }
    }

    func testPublicRoleAndCorruptArchiveAreRejected() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("One-time invitation participants require iOS 18") }
        let material = try ManagedHomeMembershipTransport.makeParticipantMaterial()
        let participant = try ManagedHomeMembershipTransport.restoredParticipant(material)
        participant.role = .publicUser
        let publicRole = try NSKeyedArchiver.archivedData(withRootObject: participant, requiringSecureCoding: true)
        XCTAssertThrowsError(try ManagedHomeMembershipTransport.restoredParticipant(
            HomeInviteMaterial(participantID: material.participantID, archive: publicRole))) {
            XCTAssertEqual($0 as? HomeMembershipError, .invalidParticipant)
        }
        XCTAssertThrowsError(try ManagedHomeMembershipTransport.restoredParticipant(
            HomeInviteMaterial(participantID: material.participantID, archive: Data([0, 1, 2, 3]))))
    }
}
