import CoreData

/// Data imports always refresh history. Sync status alone only retries deferred repair.
final class PersistentHistoryObserver {
    private let history: PersistentHistoryConsumer
    private let changed: () -> Void
    private let notifications: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(persistence: PersistenceController, history: PersistentHistoryConsumer, notifications: NotificationCenter = .default, changed: @escaping () -> Void) {
        self.history = history
        self.changed = changed
        self.notifications = notifications
        tokens.append(notifications.addObserver(forName: .NSPersistentStoreRemoteChange,
            object: persistence.container.persistentStoreCoordinator, queue: nil) { [weak self] _ in
                self?.changed()
            })
        tokens.append(notifications.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: persistence.container, queue: nil) { [weak self] notification in
                guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                        as? NSPersistentCloudKitContainer.Event,
                      event.endDate != nil, event.succeeded,
                      event.type == .import || event.type == .export else { return }
                Task { await self?.successfulSyncCompleted() }
            })
    }

    func requestRefresh() { changed() }

    func successfulSyncCompleted() async {
        guard await history.hasPendingNeedReconciliation else { return }
        changed()
    }

    deinit {
        for token in tokens { notifications.removeObserver(token) }
    }
}
