import Combine
import SwiftUI
import UIKit
import WebKit

/// A JavaScript alert, confirm or prompt waiting for the user.
struct BrowserDialog: Identifiable {
    enum Kind {
        case alert
        case confirm
        case prompt(String)
    }

    let id = UUID()
    let host: String
    let message: String
    let kind: Kind
}

/// State and WebKit delegates of the private browser. It has one web view in a non-persistent data
/// store, so cookies, history and caches disappear together with it. It lives as long as the 浏览器
/// tab, so switching tabs keeps pages and downloads; the session ends when the app locks.
@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let downloads = BrowserDownloadManager()

    @Published private(set) var progress: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var url: URL?
    @Published private(set) var title: String?
    @Published private(set) var dialog: BrowserDialog?

    /// Whether the 浏览器 tab is showing. A dialog cannot be shown in a hidden tab, so JavaScript
    /// dialogs of a hidden page are answered right away instead of blocking it.
    var isOnScreen = false

    private weak var store: FileStore?
    private let dataStore: WKWebsiteDataStore
    private var lockObserver: AnyCancellable?
    private var userAgent: String?
    private var dialogReply: ((Bool, String?) -> Void)?
    private var lastCrashReload: Date?
    /// Set when the session ends. WebKit raises an exception if a dialog's completion handler is
    /// dropped unanswered, so dialogs that still arrive are answered right away.
    private var isClosed = false
    /// Hosts whose blocked plain-HTTP address was already retried over HTTPS.
    private var httpsRetriedHosts: Set<String> = []

    /// Schemes the web view loads itself; anything else would try to open another app.
    private static let pageSchemes: Set<String> = ["http", "https", "about", "data", "blob"]
    /// Link schemes WebKit can download from (not javascript:, mailto: and the like).
    private static let downloadableSchemes: Set<String> = ["http", "https", "data", "blob"]
    /// `.allow`, but without WebKit handing universal links (https links an installed app claims,
    /// such as shop or video sites) to that app, which would leave and lock FileBox. This is WebKit's
    /// private `_WKNavigationActionPolicyAllowWithoutTryingAppLink`, which Chrome uses for incognito tabs.
    private static let allowWithoutAppLinks = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow

    override init() {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.allowsInlineMediaPlayback = true
        configuration.applicationNameForUserAgent = BrowserModel.userAgentSuffix
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserScripts.touchTracker,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .defaultClient
        ))
        self.dataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.publisher(for: \.estimatedProgress).assign(to: &$progress)
        webView.publisher(for: \.isLoading).assign(to: &$isLoading)
        webView.publisher(for: \.canGoBack).assign(to: &$canGoBack)
        webView.publisher(for: \.canGoForward).assign(to: &$canGoForward)
        webView.publisher(for: \.url).assign(to: &$url)
        webView.publisher(for: \.title).assign(to: &$title)
    }

    /// Connects the model to the app. It shuts down the moment the app locks, before SwiftUI removes
    /// the tabs, so nothing private keeps running even if the model lingers for a while.
    func attach(_ store: FileStore, lock: LockManager) {
        self.store = store
        downloads.store = store
        guard lockObserver == nil, !isClosed else { return }
        lockObserver = lock.$isUnlocked.sink { [weak self] unlocked in
            if !unlocked { self?.shutdown() }
        }
    }

    /// Ends the private session for good: downloads stop, full-screen web video and Picture in
    /// Picture close, the page is unloaded and the session's cookies and caches are deleted.
    func shutdown() {
        guard !isClosed else { return }
        isClosed = true
        lockObserver = nil
        answerDialog(false)
        Self.close(webView, downloads)
    }

    /// Covers the model going away without the app locking first; WebKit is main-thread only.
    deinit {
        let webView = self.webView
        let downloads = self.downloads
        Task { @MainActor in
            BrowserModel.close(webView, downloads)
        }
    }

    private static func close(_ webView: WKWebView, _ downloads: BrowserDownloadManager) {
        downloads.cancelAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.closeAllMediaPresentations(completionHandler: nil)
        if let blank = URL(string: "about:blank") {
            webView.load(URLRequest(url: blank))
        }
        webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
    }

    // MARK: - Navigation

    /// Opens a typed address, or searches Bing for anything that does not look like one.
    func open(_ input: String) {
        guard let url = Self.destination(for: input) else { return }
        webView.load(URLRequest(url: url))
    }

    func reloadOrStop() {
        if webView.isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    /// Lets WebKit download `url` with the page's cookies; `referer` helps with hotlink protection.
    func download(_ url: URL, referer: URL? = nil) {
        var request = URLRequest(url: url)
        if let referer, Self.isWeb(referer) {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        webView.startDownload(using: request) { [weak self] download in
            self?.downloads.track(download, source: url)
        }
    }

    // MARK: - Page media

    /// Cookies, page address and user agent, so files can be fetched outside WebKit like the page would.
    func fetchContext() async -> BrowserFetchContext {
        let cookies = await dataStore.httpCookieStore.allCookies()
        if userAgent == nil {
            let agent = try? await webView.callAsyncJavaScript("return navigator.userAgent;", contentWorld: .defaultClient)
            userAgent = agent as? String
        }
        return BrowserFetchContext(cookies: cookies, referer: url, userAgent: userAgent)
    }

    /// The images, videos and audio of the current page, for the 「本页媒体」 sheet.
    func collectMedia() async -> BrowserMediaRequest? {
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(BrowserScripts.collectMedia, contentWorld: .defaultClient)
        } catch {
            store?.show("无法读取本页媒体：\(error.localizedDescription)")
            return nil
        }
        let items = BrowserMediaItem.items(fromJSON: result as? String ?? "[]")
        return BrowserMediaRequest(items: items, context: await fetchContext())
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        guard let scheme = navigationAction.request.url?.scheme?.lowercased(), !Self.pageSchemes.contains(scheme) else {
            decisionHandler(Self.allowWithoutAppLinks)
            return
        }
        decisionHandler(.cancel)
        // Pages often try to launch their own app by themselves; only mention it after a tap.
        if navigationAction.navigationType == .linkActivated {
            store?.show("无痕浏览器不会打开其他 App（\(scheme):）")
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        let http = navigationResponse.response as? HTTPURLResponse
        // 204/205 mean "stay on this page"; as downloads they would only save empty files.
        if let status = http?.statusCode, status == 204 || status == 205 {
            decisionHandler(.cancel)
            return
        }
        let disposition = http?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let isAttachment = disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment")
        decisionHandler(isAttachment || !navigationResponse.canShowMIMEType ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloads.track(download, source: navigationAction.request.url)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloads.track(download, source: navigationResponse.response.url)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportLoadError(error)
    }

    /// Reloads after a web content crash, but not in a loop when a page keeps crashing (usually
    /// because it runs out of memory).
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let last = lastCrashReload, Date().timeIntervalSince(last) < 10 {
            store?.show("网页反复崩溃（可能内存不足），已停止自动重新载入")
            return
        }
        lastCrashReload = Date()
        webView.reload()
    }

    // MARK: - WKUIDelegate

    /// There is only one tab: target=_blank links and window.open load in place, and
    /// `<a download target=_blank>` links are downloaded.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let target = navigationAction.request.url,
              !target.absoluteString.isEmpty, target.absoluteString != "about:blank"
        else { return nil }
        if navigationAction.shouldPerformDownload {
            download(target, referer: url)
        } else {
            webView.load(navigationAction.request)
        }
        return nil
    }

    /// Long press on a link (WebKit only asks this public method for links).
    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping @MainActor @Sendable (UIContextMenuConfiguration?) -> Void
    ) {
        let link = elementInfo.linkURL
        Task {
            let image = await self.imageUnderPress(elementInfo)
            completionHandler(self.contextMenu(link: link, image: image))
        }
    }

    /// Long press on an image that is not a link: WebKit asks its private delegate method for those.
    /// Answering nil keeps WebKit's own image menu.
    @objc(_webView:contextMenuConfigurationForElement:completionHandler:)
    func browserImageContextMenu(
        _ webView: WKWebView,
        element: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        Task {
            let image = await self.imageUnderPress(element)
            completionHandler(self.contextMenu(link: nil, image: image))
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        ask(BrowserDialog(host: frame.securityOrigin.host, message: message, kind: .alert)) { _, _ in
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        ask(BrowserDialog(host: frame.securityOrigin.host, message: message, kind: .confirm)) { accepted, _ in
            completionHandler(accepted)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        let dialog = BrowserDialog(host: frame.securityOrigin.host, message: prompt, kind: .prompt(defaultText ?? ""))
        ask(dialog) { accepted, text in
            completionHandler(accepted ? (text ?? "") : nil)
        }
    }

    /// Answers the pending JavaScript dialog; WebKit requires every dialog to be answered.
    func answerDialog(_ accepted: Bool, text: String? = nil) {
        let reply = dialogReply
        dialogReply = nil
        dialog = nil
        reply?(accepted, text)
    }

    // MARK: - Helpers

    private func ask(_ dialog: BrowserDialog, reply: @escaping (Bool, String?) -> Void) {
        guard !isClosed, isOnScreen, dialogReply == nil else {
            reply(false, nil)
            return
        }
        dialogReply = reply
        self.dialog = dialog
    }

    /// The image under the long press, found by the touch script (largest srcset candidate first).
    private func imageUnderPress(_ element: WKContextMenuElementInfo) async -> URL? {
        let found = try? await webView.callAsyncJavaScript(BrowserScripts.imageUnderTouch, contentWorld: .defaultClient)
        if let text = found as? String, let url = URL(string: text) {
            return url
        }
        return Self.activatedImageURL(element)
    }

    private func contextMenu(link rawLink: URL?, image: URL?) -> UIContextMenuConfiguration? {
        let link = rawLink.flatMap { Self.downloadableSchemes.contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        guard link != nil || image != nil else { return nil }
        let page = url
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
            var actions: [UIMenuElement] = []
            if let link {
                actions.append(UIAction(title: "下载链接", image: UIImage(systemName: "arrow.down.circle")) { _ in
                    self?.download(link, referer: page)
                })
            }
            if let image {
                actions.append(UIAction(title: "下载图片", image: UIImage(systemName: "photo.badge.arrow.down")) { _ in
                    self?.download(image, referer: page)
                })
                actions.append(UIAction(title: "拷贝图片地址", image: UIImage(systemName: "link")) { _ in
                    UIPasteboard.general.url = image
                    self?.store?.show("已拷贝图片地址")
                })
            }
            let ours: UIMenuElement = UIMenu(title: "", options: .displayInline, children: actions)
            let defaults = suggested.filter { !Self.isUnwantedDefault($0) }
            return UIMenu(title: "", children: [ours] + defaults)
        }
    }

    /// WebKit's default menu items that would leave the private browser or need tabs.
    private static func isUnwantedDefault(_ element: UIMenuElement) -> Bool {
        guard let action = element as? UIAction else { return false }
        let id = action.identifier.rawValue
        let unwanted = ["AddToReadingList", "OpenInDefaultBrowser", "OpenInExternalApplication",
                        "OpenInNewTab", "OpenInNewWindow", "ActionTypeDownload"]
        return unwanted.contains { id.contains($0) }
    }

    /// Fallback for images the touch script cannot see (inside frames): WebKit's private element info.
    private static func activatedImageURL(_ element: WKContextMenuElementInfo) -> URL? {
        let infoSelector = NSSelectorFromString("_activatedElementInfo")
        guard element.responds(to: infoSelector),
              let info = element.perform(infoSelector)?.takeUnretainedValue() as? NSObject
        else { return nil }
        let urlSelector = NSSelectorFromString("imageURL")
        guard info.responds(to: urlSelector) else { return nil }
        return info.perform(urlSelector)?.takeUnretainedValue() as? URL
    }

    private func reportLoadError(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        // 102: the load became a download or was cancelled by policy; 204: a media plug-in took over.
        if nsError.domain == "WebKitErrorDomain" && (nsError.code == 102 || nsError.code == 204) { return }
        // iOS blocks plain HTTP unless the app allows it (App Transport Security). Many such links
        // also work over HTTPS, so try that, once per host in case HTTPS redirects back to HTTP.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorAppTransportSecurityRequiresSecureConnection,
           let failed = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL, failed.scheme?.lowercased() == "http",
           let host = failed.host?.lowercased(), httpsRetriedHosts.insert(host).inserted,
           var components = URLComponents(url: failed, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            if let secure = components.url {
                store?.show("系统不允许不加密的 HTTP 连接，正在改用 HTTPS 打开")
                webView.load(URLRequest(url: secure))
                return
            }
        }
        store?.show("打不开网页：\(error.localizedDescription)")
    }

    private static func isWeb(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    /// Looks like Safari, so sites do not serve their "open in app" pages to an unknown web view.
    private static var userAgentSuffix: String {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return "Version/\(major).0 Mobile/15E148 Safari/604.1"
    }

    /// A URL for typed text: full URLs as they are, host names over HTTPS (HTTP for IP addresses and
    /// localhost), everything else as a Bing search.
    static func destination(for input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil
            || text.lowercased().hasPrefix("about:") {
            if let url = URL(string: text) { return url }
        }
        if !text.contains(where: \.isWhitespace), let url = URL(string: "https://" + text), let host = url.host?.lowercased() {
            if host == "localhost" || host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
                return URL(string: "http://" + text)
            }
            if host.contains("."), let tld = host.split(separator: ".").last, tld.count >= 2,
               tld.hasPrefix("xn--") || tld.allSatisfy({ $0.isLetter }) {
                return url
            }
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let query = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        return URL(string: "https://cn.bing.com/search?q=" + query)
    }
}

/// JavaScript run in WebKit's client content world, which shares the DOM with the page but not its
/// variables, so pages cannot interfere with it.
private enum BrowserScripts {
    /// Remembers where the current touch began (and when it ended), so a long press can be traced
    /// back to an image. Touches inside frames never reach it, so an ended touch soon goes stale.
    static let touchTracker = """
    (function () {
      var options = { capture: true, passive: true };
      window.addEventListener('touchstart', function (event) {
        var touch = event.touches && event.touches[0];
        if (touch) { window.__fileboxTouch = { x: touch.clientX, y: touch.clientY, time: Date.now(), end: 0 }; }
      }, options);
      function ended(event) {
        var current = window.__fileboxTouch;
        if (current && (!event.touches || event.touches.length === 0)) { current.end = Date.now(); }
      }
      window.addEventListener('touchend', ended, options);
      window.addEventListener('touchcancel', ended, options);
    })();
    """

    /// Absolute URLs, the largest candidate of a srcset, and the real source of lazy-loaded images.
    static let helpers = #"""
    function fbAbsolute(doc, value) {
      if (!value) { return null; }
      var text = String(value).trim();
      if (!text) { return null; }
      try { return new URL(text, doc.baseURI).href; } catch (e) { return null; }
    }
    function fbLargest(doc, srcset) {
      if (!srcset) { return null; }
      var s = String(srcset), i = 0, best = null, bestScore = -1;
      while (i < s.length) {
        while (i < s.length && /[\s,]/.test(s[i])) { i++; }
        if (i >= s.length) { break; }
        var start = i;
        while (i < s.length && !/\s/.test(s[i])) { i++; }
        var url = s.slice(start, i), descriptor = '';
        if (/,$/.test(url)) {
          url = url.replace(/,+$/, '');
        } else {
          start = i;
          while (i < s.length && s[i] !== ',') { i++; }
          descriptor = s.slice(start, i);
        }
        var m = descriptor.match(/([\d.]+)\s*([wx])/i);
        var score = m ? parseFloat(m[1]) * (m[2].toLowerCase() === 'x' ? 1000 : 1) : 1;
        if (url && score > bestScore) { best = url; bestScore = score; }
      }
      return fbAbsolute(doc, best);
    }
    function fbImageSource(doc, img) {
      var url = fbLargest(doc, img.getAttribute('srcset')) || fbAbsolute(doc, img.currentSrc || img.src);
      var lazy = img.getAttribute('data-src') || img.getAttribute('data-original') ||
        img.getAttribute('data-actualsrc') || img.getAttribute('data-lazy-src');
      if (lazy && (!url || /^data:/i.test(url))) { url = fbAbsolute(doc, lazy); }
      return url;
    }
    """#

    /// The image (or CSS background image) at the last touch point, looking through overlays.
    static let imageUnderTouch = helpers + "\n" + #"""
    var touch = window.__fileboxTouch, now = Date.now();
    if (!touch || now - touch.time > 10000 || (touch.end && now - touch.end > 1000)) { return null; }
    var stack = document.elementsFromPoint(touch.x, touch.y);
    for (var i = 0; i < stack.length && i < 15; i++) {
      var el = stack[i];
      if (el.tagName === 'IMG') {
        var src = fbImageSource(document, el);
        if (src && !/^data:/i.test(src)) { return src; }
      }
      if (el === document.body || el === document.documentElement) { continue; }
      var background = getComputedStyle(el).backgroundImage || '';
      var match = background.match(/url\(\s*["']?([^"')]+)["']?\s*\)/);
      if (match) {
        var url = fbAbsolute(document, match[1]);
        if (url && !/^data:/i.test(url)) { return url; }
      }
    }
    return null;
    """#

    /// Every img, picture source, video, audio and media link of the page and its same-origin frames,
    /// as a JSON array of {url, type, w, h, poster}.
    static let collectMedia = helpers + "\n" + #"""
    var out = [], seen = {};
    var mediaPattern = /\.(jpe?g|png|gif|webp|heic|heif|avif|bmp|tiff?|mp4|m4v|mov|webm|mkv|avi|flv|3gp|m3u8|mpd|mp3|m4a|aac|wav|flac|ogg|oga|opus)(?:$|[?#])/i;
    function kindOf(url) {
      var m = url.match(mediaPattern);
      if (!m) { return null; }
      var ext = m[1].toLowerCase();
      if (/^(mp3|m4a|aac|wav|flac|ogg|oga|opus)$/.test(ext)) { return 'audio'; }
      if (/^(mp4|m4v|mov|webm|mkv|avi|flv|3gp|m3u8|mpd)$/.test(ext)) { return 'video'; }
      return 'image';
    }
    function add(url, type, extra) {
      if (!url || /^(data|javascript|about):/i.test(url) || seen[url]) { return; }
      seen[url] = true;
      var item = { url: url, type: type };
      if (extra) { for (var key in extra) { if (extra[key]) { item[key] = extra[key]; } } }
      out.push(item);
    }
    function scan(doc, depth) {
      doc.querySelectorAll('video').forEach(function (video) {
        var poster = fbAbsolute(doc, video.getAttribute('poster'));
        add(fbAbsolute(doc, video.currentSrc || video.getAttribute('src')), 'video', { poster: poster });
        video.querySelectorAll('source[src]').forEach(function (source) {
          add(fbAbsolute(doc, source.getAttribute('src')), 'video', { poster: poster });
        });
      });
      doc.querySelectorAll('audio').forEach(function (audio) {
        add(fbAbsolute(doc, audio.currentSrc || audio.getAttribute('src')), 'audio');
        audio.querySelectorAll('source[src]').forEach(function (source) {
          add(fbAbsolute(doc, source.getAttribute('src')), 'audio');
        });
      });
      doc.querySelectorAll('img').forEach(function (img) {
        var w = img.naturalWidth, h = img.naturalHeight;
        if (w && h && w < 48 && h < 48) { return; }
        add(fbImageSource(doc, img), 'image', { w: w, h: h });
      });
      doc.querySelectorAll('picture source[srcset]').forEach(function (source) {
        add(fbLargest(doc, source.getAttribute('srcset')), 'image');
      });
      doc.querySelectorAll('a[href]').forEach(function (link) {
        var url = fbAbsolute(doc, link.getAttribute('href'));
        var kind = url && kindOf(url);
        if (kind) { add(url, kind); }
      });
      if (depth < 3) {
        doc.querySelectorAll('iframe, frame').forEach(function (frame) {
          try { if (frame.contentDocument) { scan(frame.contentDocument, depth + 1); } } catch (e) {}
        });
      }
    }
    scan(document, 0);
    return JSON.stringify(out.slice(0, 500));
    """#
}
