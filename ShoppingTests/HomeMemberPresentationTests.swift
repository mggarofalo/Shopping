import XCTest
@testable import Shopping

final class HomeMemberPresentationTests: XCTestCase {
    func testCurrentOwnerWithoutIdentityHasOneRoleAndYouLabel() {
        let member = HomeMember(id: "owner", name: nil, role: .owner,
            acceptance: .accepted, isCurrentUser: true, canResend: false)
        let presentation = HomeMemberPresentation(member: member)
        XCTAssertEqual(presentation.title, "You")
        XCTAssertEqual(presentation.detail, "Owner")
    }

    func testSuppliedEmailPrecedesNameAndBlankEmailFallsBackToName() {
        var member = HomeMember(id: "member", name: "Morgan", role: .contributor,
            acceptance: .accepted, isCurrentUser: true, canResend: false,
            email: " morgan@example.invalid ")
        XCTAssertEqual(HomeMemberPresentation(member: member).title, "morgan@example.invalid · You")
        member.email = "  "
        XCTAssertEqual(HomeMemberPresentation(member: member).title, "Morgan · You")
    }

    func testUnnamedOwnerDoesNotRepeatItsRole() {
        let member = HomeMember(id: "owner", name: nil, role: .owner,
            acceptance: .accepted, isCurrentUser: false, canResend: false)
        let presentation = HomeMemberPresentation(member: member)
        XCTAssertEqual(presentation.title, "Owner")
        XCTAssertNil(presentation.detail)
    }

    func testPendingOneTimeInvitationDoesNotPretendToIdentifyRecipient() {
        let member = HomeMember(id: "pending", name: "Unused", role: .contributor,
            acceptance: .pending, isCurrentUser: false, canResend: true,
            email: "unused@example.invalid")
        let presentation = HomeMemberPresentation(member: member)
        XCTAssertEqual(presentation.title, "Invitation pending")
        XCTAssertNil(presentation.detail)
    }

    func testReadOnlyMemberKeepsItsAccessLabel() {
        let member = HomeMember(id: "member", name: "Taylor", role: .restricted,
            acceptance: .accepted, isCurrentUser: false, canResend: false)
        XCTAssertEqual(HomeMemberPresentation(member: member).detail, "Read-only access")
    }
}
