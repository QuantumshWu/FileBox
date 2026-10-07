import ImageIO
import UIKit

/// Decodes images at a bounded size, off the main thread, so huge photos don't exhaust memory.
/// One decode per picture is shared by everyone who asks for it (the page, the prefetch of its
/// neighbours, image PiP), and the page on screen always goes before anything prepared ahead.
enum MediaImageLoader {
    enum Priority {
        /// A page on screen is waiting for it.
        case visible
        /// Prepared ahead (neighbouring pages, the PiP picture).
        case background

        fileprivate var taskPriority: TaskPriority {
            self == .visible ? .userInitiated : .utility
        }
    }

    /// Longest side decoded for display: sharp when zoomed in a little, without decoding 50 MP.
    static let displayMaxPixel: CGFloat = 3000

    /// The last few decoded pictures, so swiping back does not decode again.
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 150 * 1024 * 1024
        return cache
    }()

    private static let gate = PlayerDecodeGate()

    private enum Outcome: Sendable {
        case image(UIImage)
        case failed
        /// Called off before it got a slot: nothing was decoded.
        case dropped
    }

    /// A decode in progress.
    private struct Flight {
        let id: UUID
        let task: Task<Outcome, Never>
        let priority: Priority
        /// It has a slot (and is decoding): it is no longer called off for a page that needs it.
        var started: Bool
    }

    @MainActor private static var flights: [String: Flight] = [:]
    @MainActor private static var prefetches: [String: Task<Outcome, Never>] = [:]

    /// The decoded picture if it is in the cache. Safe on any thread.
    static func cachedImage(for item: FileItem, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: cacheKey(for: item, maxPixel: maxPixel) as NSString)
    }

    /// The picture at `maxPixel`: from the cache, from a decode already running for it, or from a
    /// new one. A caller that goes away does not stop the shared decode, so a page that is swiped
    /// away and back picks up the same one.
    @MainActor
    static func load(_ item: FileItem, maxPixel: CGFloat, priority: Priority = .visible) async -> UIImage? {
        let key = cacheKey(for: item, maxPixel: maxPixel)
        while true {
            if let hit = cache.object(forKey: key as NSString) { return hit }
            let task: Task<Outcome, Never>
            if let flight = flights[key],
               !(priority == .visible && flight.priority == .background && !flight.started) {
                task = flight.task
            } else {
                // A prefetch still waiting for a slot gives way to the page that needs it now.
                flights[key]?.task.cancel()
                task = startFlight(key: key, url: item.url, maxPixel: maxPixel, priority: priority)
            }
            switch await task.value {
            case .image(let image):
                return image
            case .failed:
                return nil
            case .dropped:
                // The decode joined here was called off before it started; ask again.
                if Task.isCancelled { return nil }
            }
        }
    }

    /// Decodes `items` (images only) ahead of time, in this order and behind any page on screen.
    /// Earlier prefetches of pictures no longer in the list are called off if they have not started.
    @MainActor
    static func prefetch(_ items: [FileItem], maxPixel: CGFloat) {
        let wanted = items.filter { $0.kind == .image }
        let keys = wanted.map { cacheKey(for: $0, maxPixel: maxPixel) }
        for (key, task) in prefetches where !keys.contains(key) {
            task.cancel()
        }
        prefetches = prefetches.filter { keys.contains($0.key) }
        for (item, key) in zip(wanted, keys) {
            guard cache.object(forKey: key as NSString) == nil, flights[key] == nil else { continue }
            prefetches[key] = startFlight(key: key, url: item.url, maxPixel: maxPixel, priority: .background)
        }
    }

    /// Runs `work` off the main thread in one of the decode slots: decoding a big HEIC can take a
    /// few hundred MB, and flicking through a folder must not start one per page. Returns nil
    /// without running `work` if the calling task was cancelled while it waited.
    static func limited<T: Sendable>(priority: Priority = .visible, _ work: @escaping @Sendable () -> T?) async -> T? {
        guard await enterGate(priority) else { return nil }
        let result: T?
        if Task.isCancelled {
            result = nil
        } else {
            result = await Task.detached(priority: priority.taskPriority) { work() }.value
        }
        await gate.leave(priority)
        return result
    }

    /// The image (orientation applied) with its longer side at most `maxPixel` pixels.
    static func decode(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Decoding

    /// A file replaced at the same path (same name, new contents) gets a new key.
    private static func cacheKey(for item: FileItem, maxPixel: CGFloat) -> String {
        "\(Int(maxPixel))|\(item.url.path)|\(item.modified.timeIntervalSince1970)"
    }

    @MainActor
    private static func startFlight(key: String, url: URL, maxPixel: CGFloat, priority: Priority) -> Task<Outcome, Never> {
        let id = UUID()
        // Runs on the main actor between its awaits, so it is registered below before it starts.
        let task = Task<Outcome, Never> {
            let outcome = await MediaImageLoader.runFlight(id: id, key: key, url: url, maxPixel: maxPixel, priority: priority)
            if MediaImageLoader.flights[key]?.id == id { MediaImageLoader.flights[key] = nil }
            return outcome
        }
        flights[key] = Flight(id: id, task: task, priority: priority, started: false)
        return task
    }

    @MainActor
    private static func runFlight(id: UUID, key: String, url: URL, maxPixel: CGFloat, priority: Priority) async -> Outcome {
        guard await enterGate(priority) else { return .dropped }
        if Task.isCancelled {
            await gate.leave(priority)
            return .dropped
        }
        if flights[key]?.id == id { flights[key]?.started = true }
        if let hit = cache.object(forKey: key as NSString) {
            await gate.leave(priority)
            return .image(hit)
        }
        let image = await Task.detached(priority: priority.taskPriority) { () -> UIImage? in
            MediaImageLoader.decode(url, maxPixel: maxPixel).map(MediaImageLoader.displayable)
        }.value
        await gate.leave(priority)
        guard let image else { return .failed }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height }
            ?? Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
        return .image(image)
    }

    /// Unusual bitmaps (16-bit, grayscale, CMYK…) are converted here rather than by Core Animation
    /// on the main thread when the page lands; ordinary 8-bit RGB photos are used as they are.
    private static func displayable(_ cgImage: CGImage) -> UIImage {
        let image = UIImage(cgImage: cgImage)
        guard cgImage.bitsPerComponent != 8 || cgImage.colorSpace?.model != .rgb else { return image }
        return image.preparingForDisplay() ?? image
    }

    /// Waits for a decode slot. False when the calling task was cancelled first (no slot taken).
    private static func enterGate(_ priority: Priority) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await gate.enter(priority, id: id)
        } onCancel: {
            Task { await MediaImageLoader.gate.cancel(id) }
        }
    }
}

/// Two decode slots. Pages on screen are served before anything prepared ahead, the newest request
/// first (after a fling, the page the user stopped on), and at most one slot ever runs background
/// work, so a page never waits long.
private actor PlayerDecodeGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let slots = 2
    private var running = 0
    private var runningBackground = 0
    private var visibleWaiters: [Waiter] = []
    private var backgroundWaiters: [Waiter] = []

    /// True once the caller holds a slot; false if it was cancelled before it got one.
    func enter(_ priority: MediaImageLoader.Priority, id: UUID) async -> Bool {
        if Task.isCancelled { return false }
        if hasRoom(for: priority) {
            take(priority)
            return true
        }
        return await withCheckedContinuation { continuation in
            let waiter = Waiter(id: id, continuation: continuation)
            switch priority {
            case .visible: visibleWaiters.append(waiter)
            case .background: backgroundWaiters.append(waiter)
            }
        }
    }

    /// A waiting caller was cancelled: it leaves without a slot.
    func cancel(_ id: UUID) {
        if let index = visibleWaiters.firstIndex(where: { $0.id == id }) {
            visibleWaiters.remove(at: index).continuation.resume(returning: false)
        } else if let index = backgroundWaiters.firstIndex(where: { $0.id == id }) {
            backgroundWaiters.remove(at: index).continuation.resume(returning: false)
        }
    }

    func leave(_ priority: MediaImageLoader.Priority) {
        running -= 1
        if priority == .background { runningBackground -= 1 }
        admit()
    }

    private func hasRoom(for priority: MediaImageLoader.Priority) -> Bool {
        running < slots && (priority == .visible || runningBackground < 1)
    }

    private func take(_ priority: MediaImageLoader.Priority) {
        running += 1
        if priority == .background { runningBackground += 1 }
    }

    private func admit() {
        while running < slots {
            if let next = visibleWaiters.popLast() {
                take(.visible)
                next.continuation.resume(returning: true)
            } else if runningBackground < 1, let next = backgroundWaiters.popLast() {
                take(.background)
                next.continuation.resume(returning: true)
            } else {
                break
            }
        }
    }
}
