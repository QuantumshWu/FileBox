import SwiftUI

/// Screens pushed on the main navigation stack (`NavigationLink(value: Route...)`).
enum Route: Hashable {
    case folder(URL)
    case browser
    case capture
    case transfer
    case settings
    case trash
}

/// The two tabs shown while unlocked. Both keep their state when switching; everything is torn
/// down when the app locks.
enum MainTab: Hashable {
    case files
    case browser
}

@MainActor
final class TabCoordinator: ObservableObject {
    @Published var selected: MainTab = .files
}

struct ViewerRequest: Identifiable {
    let id: UUID
    /// The media files (images, videos, audio) of one folder, in display order.
    let items: [FileItem]
    let startIndex: Int
    /// False when the viewer should appear already settled (returning from Picture in Picture).
    let animated: Bool

    init(id: UUID = UUID(), items: [FileItem], startIndex: Int, animated: Bool = true) {
        self.id = id
        self.items = items
        self.startIndex = startIndex
        self.animated = animated
    }
}

/// Opens the full-screen media viewer. It is presented by RootView above everything else, so a
/// playing video (and its Picture in Picture) survives the app locking itself in the background.
@MainActor
final class ViewerCoordinator: ObservableObject {
    @Published var request: ViewerRequest?

    /// Presents the viewer without the system's slide-up; the viewer animates itself in.
    func open(_ items: [FileItem], at index: Int, animated: Bool = true) {
        guard items.indices.contains(index) else { return }
        withoutAnimation {
            request = ViewerRequest(items: items, startIndex: index, animated: animated)
        }
    }

    /// Closes with the system's dismissal (the app going to the background, the hub).
    func close() {
        request = nil
    }

    /// Closes at once: the viewer has already animated its content away.
    func closeImmediately() {
        withoutAnimation { request = nil }
    }

    /// Takes a deleted file out of the open viewer, which stays on screen with the others.
    func remove(_ url: URL) {
        guard let current = request else { return }
        let items = current.items.filter { $0.url != url }
        guard items.count != current.items.count, !items.isEmpty else { return }
        let start = min(max(0, current.startIndex), items.count - 1)
        withoutAnimation {
            request = ViewerRequest(id: current.id, items: items, startIndex: start, animated: false)
        }
    }

    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}

/// Playback facts the app shell needs; the media viewer keeps them up to date.
@MainActor
final class PlaybackState: ObservableObject {
    static let shared = PlaybackState()

    /// True while a video is playing or Picture in Picture is active or about to start. Then going to
    /// the background keeps the viewer open and skips the privacy shield, which would block PiP.
    @Published var keepsViewerInBackground = false
    @Published var isPictureInPictureActive = false
}
