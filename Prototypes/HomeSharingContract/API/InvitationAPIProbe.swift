import CloudKit
import CoreData
import UIKit

@available(iOS 18.0, *)
func createLink(container: NSPersistentCloudKitContainer, store: NSPersistentStore, share: CKShare) {
    let participant = CKShare.Participant.oneTimeURLParticipant()
    participant.permission = .readWrite
    share.addParticipant(participant)
    let participantID = participant.__participantID
    container.persistUpdatedShare(share, in: store) { savedShare, error in
        guard error == nil, let url = savedShare?.__oneTimeURL(forParticipantID: participantID) else { return }
        Task { @MainActor in
            _ = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        }
    }
}
