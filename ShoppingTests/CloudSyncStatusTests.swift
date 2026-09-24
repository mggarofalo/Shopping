import CloudKit
import CoreData
import XCTest
#if os(watchOS)
@testable import ShoppingWatch
#else
@testable import Shopping
#endif

final class CloudSyncStatusTests: XCTestCase {
    private func event(_ operation: CloudSyncStatus.Operation, store: String = "private", time: TimeInterval,
                       failure: CloudSyncStatus.Failure? = nil, active: Bool = false) -> CloudSyncStatus.Event {
        .init(store: store, operation: operation, started: Date(timeIntervalSince1970: time),
              ended: active ? nil : Date(timeIntervalSince1970: time + 1), failure: failure)
    }

    func testSetupAndOtherStoreSuccessDoNotHideUploadFailure() {
        var status = CloudSyncStatus()
        status.record(event(.upload, time: 1, failure: .configuration))
        status.record(event(.setup, store: "shared", time: 2))
        status.record(event(.download, time: 3))
        status.record(event(.upload, store: "shared", time: 4))
        XCTAssertTrue(status.hasFailure)
        XCTAssertTrue(status.message.contains("upload failed"))
        XCTAssertTrue(status.message.contains("cloud configuration"))
        status.record(event(.upload, time: 5, active: true))
        XCTAssertTrue(status.hasFailure, "A retry starting does not prove recovery")
        status.record(event(.upload, time: 5))
        XCTAssertFalse(status.hasFailure)
    }

    func testHistoryHydrationCannotReplaceNewerLiveCompletion() {
        var status = CloudSyncStatus()
        status.record(event(.upload, time: 20))
        status.record(event(.upload, time: 10, failure: .network))
        status.record(event(.upload, time: 20, active: true))
        XCTAssertFalse(status.hasFailure)
        XCTAssertEqual(status.lastUpload, Date(timeIntervalSince1970: 21))
        XCTAssertTrue(status.message.contains("Recent iCloud activity"))
    }

    func testSetupSuccessDoesNotClaimUploadOrOtherDeviceDelivery() {
        var status = CloudSyncStatus()
        status.record(event(.setup, time: 1))
        XCTAssertNil(status.lastUpload)
        XCTAssertNil(status.lastDownload)
        XCTAssertTrue(status.message.contains("Waiting for iCloud activity"))
        status.record(event(.download, time: 2))
        XCTAssertTrue(status.message.contains("does not confirm another device"))
    }

    func testFailureMessagesClassifyUnderlyingErrorsWithoutLeakingDetails() {
        let secret = "private record contents and account identifier"
        let cloud = NSError(domain: CKErrorDomain, code: CKError.Code.networkUnavailable.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: secret])
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 134400,
                              userInfo: [NSUnderlyingErrorKey: cloud])
        XCTAssertEqual(CloudSyncStatus.Failure.classify(wrapped), .network)
        XCTAssertFalse(CloudSyncStatus.Failure.classify(wrapped).message.contains(secret))
        XCTAssertFalse(CloudSyncStatus.Failure.classify(wrapped).message.contains("iPhone"))
        let rejected = NSError(domain: CKErrorDomain, code: CKError.Code.serverRejectedRequest.rawValue)
        XCTAssertEqual(CloudSyncStatus.Failure.classify(rejected), .configuration)
        XCTAssertFalse(CloudSyncStatus.Failure.classify(rejected).message.contains("schema"))
    }

    func testPartialErrorClassificationIsStableAndActionable() {
        let partial = NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue, userInfo: [
            CKPartialErrorsByItemIDKey: ["one": NSError(domain: CKErrorDomain, code: CKError.Code.quotaExceeded.rawValue),
                                      "two": NSError(domain: CKErrorDomain, code: CKError.Code.networkFailure.rawValue)]
        ])
        XCTAssertEqual(CloudSyncStatus.Failure.classify(partial), .quota)
        XCTAssertEqual(CloudSyncStatus.Failure.classify(NSError(domain: "Other", code: 1)), .unknown)
    }

    @MainActor
    func testMonitorRejectsForeignAndRetiredContainerEvents() throws {
        // No stores or CloudKit options: these containers cannot access an account.
        let own = NSPersistentCloudKitContainer(name: "Own", managedObjectModel: NSManagedObjectModel())
        let foreign = NSPersistentCloudKitContainer(name: "Foreign", managedObjectModel: NSManagedObjectModel())
        let monitor = CloudSyncEventMonitor()
        monitor.attach(to: own)
        monitor.receive(event(.upload, time: 1, failure: .configuration), from: foreign)
        XCTAssertFalse(monitor.status.hasFailure)
        monitor.receive(event(.upload, time: 1, failure: .configuration), from: own)
        XCTAssertTrue(monitor.status.hasFailure)
        monitor.reset()
        monitor.receive(event(.upload, time: 2, failure: .network), from: own)
        XCTAssertEqual(monitor.status, CloudSyncStatus())
        monitor.attach(to: foreign)
        monitor.receive(event(.upload, time: 3), from: own)
        XCTAssertNil(monitor.status.lastUpload)
    }
}
