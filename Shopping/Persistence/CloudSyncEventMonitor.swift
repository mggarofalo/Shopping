import CoreData
import Foundation

/// Create before loading stores; attach afterwards. The queued observer captures startup events.
@MainActor
final class CloudSyncEventMonitor {
    var onChange: ((CloudSyncStatus) -> Void)?
    private(set) var status = CloudSyncStatus()
    private weak var container: NSPersistentCloudKitContainer?
    private var observer: NSObjectProtocol?
    private var generation = 0

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let source = notification.object as? NSPersistentCloudKitContainer,
                  let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            Task { @MainActor in
                guard let self, source === self.container else { return }
                self.record(event, from: source)
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reset() {
        generation += 1
        container = nil
        status = CloudSyncStatus()
        onChange?(status)
    }

    func attach(to container: NSPersistentContainer) {
        reset()
        guard let cloud = container as? NSPersistentCloudKitContainer else { return }
        self.container = cloud
        guard !cloud.persistentStoreCoordinator.persistentStores.isEmpty else { return }
        let generation = generation
        // Core Data retains engine events across launches. Read a bounded recent window;
        // absence of an event must never be interpreted as successful synchronization.
        let context = cloud.newBackgroundContext()
        context.perform { [weak self] in
            let fetch = NSPersistentCloudKitContainerEventRequest.fetchForEvents()
            fetch.fetchLimit = 200
            fetch.sortDescriptors = [NSSortDescriptor(key: "startDate", ascending: false)]
            let request = NSPersistentCloudKitContainerEventRequest.fetchEvents(matchingFetch: fetch)
            do {
                let result = try context.execute(request) as? NSPersistentCloudKitContainerEventResult
                let events = result?.result as? [NSPersistentCloudKitContainer.Event] ?? []
                Task { @MainActor in
                    guard let self, generation == self.generation, self.container === cloud else { return }
                    for event in events { self.record(event, from: cloud) }
                }
            } catch {
                // Live events still work. A failed diagnostic read cannot establish sync failure
                // or replace a concrete engine error with an unrelated history error.
            }
        }
    }

    private func record(_ event: NSPersistentCloudKitContainer.Event, from source: NSPersistentCloudKitContainer) {
        let operation: CloudSyncStatus.Operation
        switch event.type {
        case .setup: operation = .setup
        case .import: operation = .download
        case .export: operation = .upload
        @unknown default: return
        }
        receive(.init(store: event.storeIdentifier, operation: operation,
            started: event.startDate, ended: event.endDate,
            failure: event.endDate == nil || event.succeeded ? nil : event.error.map { CloudSyncStatus.Failure.classify($0) } ?? .unknown), from: source)
    }

    // Both live notifications and recorded startup history pass through the same authority check.
    func receive(_ event: CloudSyncStatus.Event, from source: NSPersistentCloudKitContainer) {
        guard source === container else { return }
        status.record(event)
        onChange?(status)
    }
}
