import Foundation

struct HomeMemberPresentation: Equatable {
    let title: String
    let detail: String?

    init(member: HomeMember) {
        let role: String
        switch member.role {
        case .owner: role = "Owner"
        case .contributor: role = "Contributor"
        case .restricted: role = "Read-only access"
        }
        let label = member.label
        if member.isCurrentUser {
            let hasIdentity = [member.email, member.name].contains {
                !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
            title = hasIdentity ? "\(label) · You" : "You"
        } else {
            title = label
        }
        switch member.acceptance {
        case .pending:
            detail = member.role == .restricted ? role : nil
        case .accepted:
            detail = title == role ? nil : role
        case .unknown:
            detail = title == role ? "Checking acceptance" : "\(role) · Checking acceptance"
        }
    }
}
