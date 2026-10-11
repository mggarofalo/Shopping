import Foundation

/// A retained Home is a replacement candidate only when this exact invitation
/// was opened from that selected local Home, not merely because it is retained.
struct HomeReplacementOrigin: Codable, Equatable, Sendable {
    let source: DeviceLocalHomeSelection
    let invitationID: UUID
    let invitation: HomeInvitationIdentity

}
