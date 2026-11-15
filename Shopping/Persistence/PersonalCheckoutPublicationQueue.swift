import Foundation

/// Runs household receipt publication after Checkout and Restore return
/// (SHOPPING-287). Requests coalesce: at most one pass waits to run, and a request
/// made while a pass runs starts one more afterwards. A pass blocks on the
/// persistence writer, so it runs on its own GCD queue, never the cooperative
/// pool (see BlockingWriterWork). Held work stays in the durable outbox, which
/// resumePending() retries; this queue keeps no state across launches.
final class PersonalCheckoutPublicationQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mggarofalo.shopping.checkout-publication", qos: .utility)
    private let lock = NSLock()
    private var waiting = false

    func request(_ pass: @escaping @Sendable () -> Void) {
        let enqueue = lock.withLock { () -> Bool in
            guard !waiting else { return false }
            waiting = true
            return true
        }
        guard enqueue else { return }
        queue.async { [self] in
            lock.withLock { waiting = false }
            pass()
        }
    }
}
