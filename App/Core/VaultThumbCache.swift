import Foundation
import UIKit

/// A finished thumbnail. `isReal` is false for a Quick Look file-type icon.
struct VaultThumbResult {
    let image: UIImage
    let isReal: Bool
}

/// The thumbnails made so far, kept in memory up to `limit` bytes with the least recently used
/// dropped first. Unlike NSCache it is not emptied when the app goes to the background (FileBox
/// locks itself there, and every unlock would redraw each folder from scratch); a memory warning
/// empties it. It also remembers files that have no thumbnail. Safe on any thread.
final class VaultThumbCache: @unchecked Sendable {
    static let shared = VaultThumbCache()

    private struct Entry {
        let image: UIImage
        let cost: Int
        /// "path|mtime" of the file version it shows.
        let file: String
        let bucket: Int
        let isReal: Bool
        var lastUse: UInt64
    }

    private let lock = NSLock()
    private let limit: Int
    private var entries: [String: Entry] = [:]
    /// Keys of every cached thumbnail of a file version, by file ("path|mtime").
    private var variants: [String: Set<String>] = [:]
    private var failures: Set<String> = []
    private var totalCost = 0
    private var clock: UInt64 = 0
    private var memoryObserver: NSObjectProtocol?

    init(limit: Int = 80 * 1024 * 1024) {
        self.limit = limit
        // UIApplication.didReceiveMemoryWarningNotification, by name: this may run on any thread.
        memoryObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"), object: nil, queue: nil
        ) { [weak self] _ in
            self?.removeAll()
        }
    }

    /// The thumbnail stored under `key`, which then counts as just used.
    func image(forKey key: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.lastUse = clock
        entries[key] = entry
        return entry.image
    }

    /// Another size of the same file version: the smallest one at least `bucket` big, else the
    /// biggest there is.
    func closestVariant(file: String, bucket: Int) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        let candidates = (variants[file] ?? []).compactMap { entries[$0] }
        let larger = candidates.filter { $0.bucket >= bucket }.min { $0.bucket < $1.bucket }
        return (larger ?? candidates.max { $0.bucket < $1.bucket })?.image
    }

    /// The biggest real thumbnail (never a file-type icon) of a file version.
    func largestReal(file: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        let real = (variants[file] ?? []).compactMap { entries[$0] }.filter(\.isReal)
        return real.max { $0.bucket < $1.bucket }?.image
    }

    func insert(_ result: VaultThumbResult, forKey key: String, file: String, bucket: Int) {
        let cost = Self.cost(of: result.image)
        guard cost <= limit else { return }
        lock.lock()
        defer { lock.unlock() }
        if let old = entries[key] { totalCost -= old.cost }
        clock += 1
        entries[key] = Entry(image: result.image, cost: cost, file: file, bucket: bucket, isReal: result.isReal, lastUse: clock)
        variants[file, default: []].insert(key)
        failures.remove(key)
        totalCost += cost
        guard totalCost > limit else { return }
        for (oldKey, entry) in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
            guard totalCost > limit else { break }
            if oldKey == key { continue }
            remove(oldKey, entry)
        }
    }

    func hasFailed(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failures.contains(key)
    }

    /// Remembers that `key` has no thumbnail, so it is not tried again on every appearance.
    func markFailed(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        failures.insert(key)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        variants.removeAll()
        failures.removeAll()
        totalCost = 0
    }

    /// Call with the lock held.
    private func remove(_ key: String, _ entry: Entry) {
        entries[key] = nil
        totalCost -= entry.cost
        variants[entry.file]?.remove(key)
        if variants[entry.file]?.isEmpty == true { variants[entry.file] = nil }
    }

    private static func cost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage { return cgImage.bytesPerRow * cgImage.height }
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        return Int(pixels) * 4
    }
}

/// Runs thumbnail work off the Swift thread pool: at most `limit` jobs at a time, the newest
/// request first (the cells that just scrolled into view). A job whose caller is cancelled before
/// it starts never runs; one already running is told to stop its current step.
final class VaultThumbScheduler: @unchecked Sendable {
    static let shared = VaultThumbScheduler(limit: 3)

    fileprivate let lock = NSLock()
    private let limit: Int
    private let queue = DispatchQueue(label: "FileBox.thumbnails", qos: .userInitiated, attributes: .concurrent)
    private var running = 0
    private var waiting: [VaultThumbJob] = []

    init(limit: Int) {
        self.limit = limit
    }

    /// Runs `work` on the thumbnail queue. It must call `finish` on the job exactly once (from
    /// any thread). A job cancelled before it started returns nil.
    func run(_ work: @escaping (VaultThumbJob) -> Void) async -> VaultThumbResult? {
        let job = VaultThumbJob(scheduler: self, work: work)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.submit(job, continuation)
            }
        } onCancel: {
            self.cancel(job)
        }
    }

    private func submit(_ job: VaultThumbJob, _ continuation: CheckedContinuation<VaultThumbResult?, Never>) {
        lock.lock()
        if job.cancelled {
            job.done = true
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        job.continuation = continuation
        waiting.append(job)
        let ready = takeReady()
        lock.unlock()
        ready.forEach(start)
    }

    /// Call with the lock held: moves waiting jobs, newest first, into free slots.
    private func takeReady() -> [VaultThumbJob] {
        var ready: [VaultThumbJob] = []
        while running < limit, let job = waiting.popLast() {
            running += 1
            job.running = true
            ready.append(job)
        }
        return ready
    }

    private func start(_ job: VaultThumbJob) {
        queue.async {
            job.work(job)
        }
    }

    fileprivate func finish(_ job: VaultThumbJob, with result: VaultThumbResult?) {
        lock.lock()
        guard !job.done else {
            lock.unlock()
            return
        }
        job.done = true
        let continuation = job.continuation
        job.continuation = nil
        job.cancelHandler = nil
        if job.running {
            job.running = false
            running -= 1
        }
        let ready = takeReady()
        lock.unlock()
        continuation?.resume(returning: result)
        ready.forEach(start)
    }

    private func cancel(_ job: VaultThumbJob) {
        lock.lock()
        job.cancelled = true
        if !job.done, let index = waiting.firstIndex(where: { $0 === job }) {
            waiting.remove(at: index)
            job.done = true
            let continuation = job.continuation
            job.continuation = nil
            lock.unlock()
            continuation?.resume(returning: nil)
            return
        }
        let handler = job.running && !job.done ? job.cancelHandler : nil
        lock.unlock()
        handler?()
    }

    fileprivate func setCancelHandler(_ handler: @escaping () -> Void, for job: VaultThumbJob) {
        lock.lock()
        if job.done {
            lock.unlock()
            return
        }
        if job.cancelled {
            lock.unlock()
            handler()
            return
        }
        job.cancelHandler = handler
        lock.unlock()
    }
}

/// One thumbnail being made. Its work checks `isCancelled` between steps, registers how to stop
/// an asynchronous step with `onCancel`, and calls `finish` once at the end.
final class VaultThumbJob: @unchecked Sendable {
    fileprivate let work: (VaultThumbJob) -> Void
    private let scheduler: VaultThumbScheduler
    // Guarded by the scheduler's lock.
    fileprivate var continuation: CheckedContinuation<VaultThumbResult?, Never>?
    fileprivate var cancelled = false
    fileprivate var running = false
    fileprivate var done = false
    fileprivate var cancelHandler: (() -> Void)?

    fileprivate init(scheduler: VaultThumbScheduler, work: @escaping (VaultThumbJob) -> Void) {
        self.scheduler = scheduler
        self.work = work
    }

    var isCancelled: Bool {
        scheduler.lock.lock()
        defer { scheduler.lock.unlock() }
        return cancelled
    }

    /// Called (once, on any thread) if the job is cancelled while this step runs.
    func onCancel(_ handler: @escaping () -> Void) {
        scheduler.setCancelHandler(handler, for: self)
    }

    func finish(_ result: VaultThumbResult?) {
        scheduler.finish(self, with: result)
    }
}
