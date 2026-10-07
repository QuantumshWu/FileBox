import Combine
import Foundation

/// The 文件 tab's navigation path. It lives above the lock, so unlocking lands in the folder that
/// was open; it is only kept in memory. Whenever the lock changes, only the leading folders that
/// still exist are kept, and nothing from the first screen that is not a folder on (Wi-Fi transfer
/// starts its server as soon as it is shown, so it must never come back by itself).
@MainActor
final class FolderUINavigation: ObservableObject {
    @Published var path: [Route] = []

    private var lockObserver: AnyCancellable?

    init() {
        lockObserver = LockManager.shared.$isUnlocked
            .dropFirst()
            .sink { [weak self] _ in self?.prune() }
    }

    private func prune() {
        let fm = FileManager.default
        var kept: [Route] = []
        for route in path {
            guard case .folder(let url) = route else { break }
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else { break }
            kept.append(route)
        }
        if kept != path { path = kept }
    }
}
