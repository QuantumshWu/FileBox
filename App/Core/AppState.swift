import SwiftUI

/// Screens pushed on the main navigation stack (`NavigationLink(value: Route...)`).
enum Route: Hashable {
    case folder(URL)
    case browser
    case capture
    case transfer
    case settings
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
    let id = UUID()
    /// The media files (images, videos, audio) of one folder, in display order.
    let items: [FileItem]
    let startIndex: Int
}

/// Opens the full-screen media viewer. It is presented by RootView above everything else, so a
/// playing video (and its Picture in Picture) survives the app locking itself in the background.
@MainActor
final class ViewerCoordinator: ObservableObject {
    @Published var request: ViewerRequest?

    func open(_ items: [FileItem], at index: Int) {
        guard items.indices.contains(index) else { return }
        request = ViewerRequest(items: items, startIndex: index)
    }

    func close() {
        request = nil
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
