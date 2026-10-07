import Combine
import SwiftUI
import WebKit

/// Owns the app's one browser, above the lock. The model (and its web view) is made the first time
/// the 浏览器 tab shows and then lives as long as the app, so the page, its history and downloads
/// survive switching tabs, locking and going to the background. Cookies, logins and site data stay
/// in WebKit's default data store across launches, and the page with its history comes back after
/// a relaunch; nothing is cleared until 清除浏览痕迹.
@MainActor
final class BrowserSession: ObservableObject {
    @Published private(set) var isClearing = false

    private var current: BrowserModel?
    private var lockObserver: AnyCancellable?

    init() {
        lockObserver = LockManager.shared.$isUnlocked
            .dropFirst()
            .sink { [weak self] unlocked in
                if !unlocked { self?.current?.pauseMedia() }
            }
    }

    /// The browser, made on first use.
    var model: BrowserModel {
        if let current { return current }
        let model = BrowserModel()
        current = model
        return model
    }

    /// What the confirmation of 清除浏览痕迹 says.
    var clearMessage: String {
        var text = "会删除所有网站的 Cookie、登录状态、缓存和网站数据，并清空打开的网页、浏览历史、地址栏和下载记录。已经保存到「下载」文件夹的文件不受影响。"
        if (current?.downloads.activeCount ?? 0) > 0 {
            text += "\n正在进行的下载会停止。"
        }
        return text
    }

    /// 清除浏览痕迹: removes website data of every type (cookies and logins, caches, local storage,
    /// databases, service workers) and the page saved for the next launch, and starts the browser
    /// over on its start page, with no history, address or download records. Files already saved
    /// to 下载 stay.
    func clearTraces(store: FileStore) {
        guard !isClearing else { return }
        isClearing = true
        let old = current
        old?.shutdown()
        // Also when the browser has not been opened since launch.
        BrowserModel.removeSavedPage()
        Task {
            // On the next turn, once the confirmation that asked has let go of the old view.
            if old != nil {
                objectWillChange.send()
                current = BrowserModel(afterClearing: true)
            }
            await WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            )
            isClearing = false
            store.show("已清除浏览痕迹")
        }
    }
}
