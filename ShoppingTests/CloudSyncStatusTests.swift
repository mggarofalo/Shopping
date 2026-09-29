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
                       failure: CloudSyncStatus.Failure? = nil, active: Bool = false,
                       identifier: UUID? = nil) -> CloudSyncStatus.Event {
        .init(identifier: identifier, store: store, operation: operation, started: Date(timeIntervalSince1970: time),
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
        status.record(event(.upload, time: 10, failure: .network), source: .history)
        status.record(event(.upload, time: 20, active: true), source: .history)
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
        XCTAssertEqual(status.message, "Recent iCloud activity completed.")
    }

    func testStoreAndOperationSnapshotsKeepFailuresAndLastSuccessScoped() {
        var status = CloudSyncStatus()
        status.record(event(.upload, time: 1))
        status.record(event(.upload, time: 2, failure: .quota))
        status.record(event(.download, store: "shared", time: 3))
        status.record(event(.setup, store: "shared", time: 4, active: true))
        let own = status.snapshot(forStores: ["private"])
        let shared = status.snapshot(forStores: ["shared"])
        XCTAssertTrue(own.hasFailure)
        XCTAssertFalse(own.isWorking)
        XCTAssertEqual(own.lastUpload, Date(timeIntervalSince1970: 2), "A later failure does not erase earlier observed success")
        XCTAssertNil(own.lastDownload)
        XCTAssertEqual(own.channels.first?.failure, .quota)
        XCTAssertFalse(shared.hasFailure)
        XCTAssertTrue(shared.isWorking)
        XCTAssertNil(shared.lastUpload)
        XCTAssertEqual(shared.lastDownload, Date(timeIntervalSince1970: 4))
        let upload = status.snapshot(forStore: "shared", operation: .upload)
        XCTAssertTrue(upload.activeEvents.isEmpty)
        XCTAssertNil(upload.latestCompletion)
        XCTAssertNil(upload.failure)
        XCTAssertFalse(upload.hasUnfinishedHistory)
        XCTAssertTrue(status.snapshot(forStores: ["unknown"]).channels.isEmpty)
    }

    func testUnfinishedHistoryIsUnknownRatherThanCurrentlyWorking() {
        var status = CloudSyncStatus()
        let id = UUID()
        let unfinished = event(.download, store: "shared", time: 1, active: true, identifier: id)
        status.record(unfinished, source: .history)
        XCTAssertFalse(status.isWorking)
        XCTAssertTrue(status.snapshot(forStores: ["shared"]).hasUnfinishedHistory)
        XCTAssertFalse(status.snapshot(forStores: ["private"]).hasUnfinishedHistory)
        XCTAssertNil(status.lastDownload)
        XCTAssertTrue(status.message.contains("no recorded completion"))
        status.record(unfinished) // A live notification now provides current activity.
        XCTAssertTrue(status.isWorking)
        XCTAssertFalse(status.snapshot().hasUnfinishedHistory)
        status.record(event(.download, store: "shared", time: 1, identifier: id))
        status.record(unfinished, source: .history)
        XCTAssertFalse(status.isWorking)
        XCTAssertFalse(status.snapshot().hasUnfinishedHistory)
    }

    func testSameTimeDistinctNativeEventsCompleteIndependentlyAndPreserveFailure() {
        var status = CloudSyncStatus()
        let a = UUID(), b = UUID()
        status.record(event(.upload, time: 10, active: true, identifier: a))
        status.record(event(.upload, time: 10, active: true, identifier: b))
        XCTAssertEqual(status.snapshot(forStore: "private", operation: .upload).activeEvents.count, 2)
        status.record(event(.upload, time: 10, identifier: a))
        XCTAssertEqual(status.snapshot(forStore: "private", operation: .upload).activeEvents.map(\.identifier), [b])
        XCTAssertTrue(status.isWorking)
        status.record(event(.upload, time: 10, failure: .network, identifier: b))
        status.record(event(.upload, time: 10, identifier: a)) // Duplicate success is not recovery from B.
        XCTAssertFalse(status.isWorking)
        XCTAssertTrue(status.hasFailure)
        XCTAssertEqual(status.snapshot(forStore: "private", operation: .upload).failure, .network)
        status.record(event(.upload, time: 11, identifier: UUID()))
        XCTAssertFalse(status.hasFailure)
    }

    func testNewerDistinctCompletionDoesNotRemoveAnotherLiveEvent() {
        var status = CloudSyncStatus()
        let earlier = UUID(), later = UUID()
        status.record(event(.upload, time: 1, active: true, identifier: earlier))
        status.record(event(.upload, time: 2, identifier: later))
        XCTAssertTrue(status.isWorking, "A later event's completion cannot terminate this UUID's live observation")
        XCTAssertEqual(status.snapshot(forStore: "private", operation: .upload).activeEvents.map(\.identifier), [earlier])
        status.record(event(.upload, time: 1, identifier: earlier))
        XCTAssertFalse(status.isWorking)
        XCTAssertEqual(status.lastUpload, Date(timeIntervalSince1970: 3))
    }

    func testSameTimeDistinctCompletionsHaveDeterministicConservativeFailureOrdering() {
        let events = [event(.upload, time: 5, identifier: UUID()),
                      event(.upload, time: 5, failure: .network, identifier: UUID()),
                      event(.upload, time: 5, failure: .quota, identifier: UUID())]
        var forwards = CloudSyncStatus(), backwards = CloudSyncStatus()
        for event in events { forwards.record(event) }
        for event in events.reversed() { backwards.record(event) }
        XCTAssertEqual(forwards, backwards)
        XCTAssertEqual(forwards.snapshot(forStore: "private", operation: .upload).failure, .quota)
        XCTAssertTrue(forwards.hasFailure)
        XCTAssertTrue(forwards.message.contains("storage is full"))
    }

    func testLiveTerminalObservationWinsConflictingHydrationForSameNativeUUID() {
        let id = UUID()
        let completed = event(.upload, time: 20, identifier: id)
        let oldFailure = event(.upload, time: 20, failure: .network, identifier: id)
        let oldStart = event(.upload, time: 20, active: true, identifier: id)
        var liveFirst = CloudSyncStatus(), historyFirst = CloudSyncStatus()
        liveFirst.record(completed)
        liveFirst.record(oldFailure, source: .history)
        liveFirst.record(oldStart, source: .history)
        historyFirst.record(oldStart, source: .history)
        historyFirst.record(oldFailure, source: .history)
        historyFirst.record(completed)
        XCTAssertEqual(liveFirst, historyFirst)
        XCTAssertFalse(liveFirst.hasFailure)
        XCTAssertFalse(liveFirst.isWorking)
        XCTAssertFalse(liveFirst.snapshot().hasUnfinishedHistory)
        XCTAssertEqual(liveFirst.lastUpload, completed.ended)
        let before = liveFirst
        liveFirst.record(completed)
        liveFirst.record(oldStart)
        XCTAssertEqual(liveFirst, before, "Duplicate or out-of-order same-event notifications are idempotent")
    }

    func testLiveFailureCannotRetainHydratedSuccessForSameNativeUUID() {
        let id = UUID()
        var status = CloudSyncStatus()
        status.record(event(.upload, time: 1, identifier: id), source: .history)
        status.record(event(.upload, time: 1, failure: .network, identifier: id))
        XCTAssertTrue(status.hasFailure)
        XCTAssertNil(status.lastUpload, "The live terminal outcome replaces that event's stale historical outcome")
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

    @MainActor
    func testMonitorHydratesUnfinishedHistoryWithoutClaimingLiveWork() {
        let cloud = NSPersistentCloudKitContainer(name: "History", managedObjectModel: NSManagedObjectModel())
        let monitor = CloudSyncEventMonitor()
        monitor.attach(to: cloud)
        let id = UUID()
        monitor.receive(event(.upload, store: "shared", time: 1, active: true, identifier: id),
            from: cloud, origin: .history)
        XCTAssertFalse(monitor.status.isWorking)
        XCTAssertTrue(monitor.status.snapshot(forStores: ["shared"]).hasUnfinishedHistory)
        monitor.receive(event(.upload, store: "shared", time: 1, identifier: id), from: cloud)
        monitor.receive(event(.upload, store: "shared", time: 1, failure: .quota, identifier: id),
            from: cloud, origin: .history)
        XCTAssertFalse(monitor.status.hasFailure)
        XCTAssertFalse(monitor.status.snapshot().hasUnfinishedHistory)
        monitor.reset()
    }

    @MainActor
    func testMonitorPublishesRapidActivityOnceButReportsFailureImmediately() async {
        let cloud = NSPersistentCloudKitContainer(name: "Coalescing", managedObjectModel: NSManagedObjectModel())
        let monitor = CloudSyncEventMonitor()
        var published: [CloudSyncStatus] = []
        monitor.attach(to: cloud)
        let completion = expectation(description: "coalesced completion")
        monitor.onChange = { status in
            published.append(status)
            if status.lastUpload != nil && !status.hasFailure { completion.fulfill() }
        }

        monitor.receive(event(.upload, time: 1, active: true), from: cloud)
        monitor.receive(event(.upload, time: 1), from: cloud)
        for time in 2...200 {
            monitor.receive(event(.upload, time: TimeInterval(time)), from: cloud)
        }
        XCTAssertTrue(published.isEmpty)
        await fulfillment(of: [completion], timeout: 5)
        XCTAssertEqual(published.count, 1)
        XCTAssertFalse(published[0].isWorking)
        XCTAssertEqual(published[0].lastUpload, Date(timeIntervalSince1970: 201))

        monitor.receive(event(.upload, time: 201, failure: .network), from: cloud)
        XCTAssertEqual(published.count, 2)
        XCTAssertTrue(published[1].hasFailure)
    }
}
