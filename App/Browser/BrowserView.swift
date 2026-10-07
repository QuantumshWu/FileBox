import SwiftUI
import UIKit
import WebKit

/// The 浏览器 tab: the app's one browser (see `BrowserSession`). A new model after 清除浏览痕迹
/// brings a new view, so nothing typed or opened in the old one stays.
struct BrowserTab: View {
    @EnvironmentObject private var session: BrowserSession

    var body: some View {
        let model = session.model
        BrowserView(model: model)
            .id(ObjectIdentifier(model))
    }
}

/// Web browser that saves downloads into the vault. Pages, history, logins and downloads stay while
/// the 文件 tab is shown, while locked and while the app is in the background, and the page with its
/// history comes back after a relaunch; only 清除浏览痕迹 removes them. All controls sit in the top bar, so the tab bar is the only bar at the bottom.
struct BrowserView: View {
    @EnvironmentObject private var store: FileStore
    @EnvironmentObject private var lock: LockManager
    @EnvironmentObject private var session: BrowserSession
    @ObservedObject private var model: BrowserModel

    @State private var address = ""
    @FocusState private var addressFocused: Bool
    @State private var sheet: BrowserSheet?
    @State private var collectingMedia = false
    @State private var promptText = ""
    @State private var confirmingClear = false

    init(model: BrowserModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            progressLine
            Divider()
            BrowserWebContainer(webView: model.webView)
                .overlay {
                    if model.url == nil && !model.isLoading {
                        startPage
                    }
                }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $sheet) { content in
            switch content {
            case .downloads:
                BrowserDownloadsSheet(downloads: model.downloads)
            case .media(let request):
                BrowserMediaSheet(request: request) { chosen in
                    model.downloads.fetch(chosen.map(\.url), context: request.context)
                    sheet = .downloads
                }
            }
        }
        .alert(model.dialog?.host ?? "", isPresented: dialogShown, presenting: model.dialog) { dialog in
            switch dialog.kind {
            case .alert:
                Button("好") { model.answerDialog(true) }
            case .confirm:
                Button("取消", role: .cancel) { model.answerDialog(false) }
                Button("好") { model.answerDialog(true) }
            case .prompt:
                TextField("", text: $promptText)
                Button("取消", role: .cancel) { model.answerDialog(false) }
                Button("好") { model.answerDialog(true, text: promptText) }
            }
        } message: { dialog in
            Text(dialog.message)
        }
        // Switching tabs and locking call these; the page itself stays loaded.
        .onAppear {
            model.attach(store)
            model.isOnScreen = true
            // The view is new after unlocking, but the page it shows may not be.
            if !addressFocused { address = displayAddress }
        }
        .onDisappear { model.isOnScreen = false }
        .onChange(of: model.url) { _, _ in
            if !addressFocused { address = displayAddress }
        }
        .onChange(of: addressFocused) { _, focused in
            address = focused ? (model.url?.absoluteString ?? "") : displayAddress
        }
        .onChange(of: model.dialog?.id) { _, _ in
            if case .prompt(let text)? = model.dialog?.kind { promptText = text }
        }
        .task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if model.url == nil && model.focusesAddressAtStart { addressFocused = true }
        }
    }

    // MARK: - Top bar

    /// Back and forward, the address field, then 本页媒体, downloads and the page menu. While typing
    /// only the field and 取消 remain.
    private var topBar: some View {
        HStack(spacing: 6) {
            if !addressFocused {
                HStack(spacing: 0) {
                    Button { model.webView.goBack() } label: {
                        BrowserBarIcon(title: "后退", systemImage: "chevron.backward")
                    }
                    .disabled(!model.canGoBack)
                    Button { model.webView.goForward() } label: {
                        BrowserBarIcon(title: "前进", systemImage: "chevron.forward")
                    }
                    .disabled(!model.canGoForward)
                }
            }
            addressField
            if addressFocused {
                Button("取消") { addressFocused = false }
            } else {
                HStack(spacing: 0) {
                    Button(action: showMedia) {
                        BrowserBarIcon(title: "本页媒体", systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(model.url == nil || collectingMedia)
                    BrowserDownloadsButton(downloads: model.downloads) { sheet = .downloads }
                    pageMenu
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
        .animation(.default, value: addressFocused)
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: model.url?.scheme == "https" ? "lock.fill" : "magnifyingglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("搜索或输入网址", text: $address)
                .focused($addressFocused)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(go)
            if addressFocused {
                if !address.isEmpty {
                    Button { address = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("清除")
                }
            } else if model.url != nil {
                Button { model.reloadOrStop() } label: {
                    Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                }
                .foregroundStyle(.primary)
                .accessibilityLabel(model.isLoading ? "停止" : "重新载入")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
    }

    private var progressLine: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: proxy.size.width * CGFloat(model.progress))
        }
        .frame(height: 2)
        .opacity(model.isLoading ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: model.progress)
    }

    /// The host without "www." while browsing (like Safari); the full address appears when editing.
    private var displayAddress: String {
        guard let url = model.url else { return "" }
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var startPage: some View {
        ContentUnavailableView {
            Label("浏览器", systemImage: "globe")
        } description: {
            Text("在上方输入网址，或输入文字用必应搜索。\n打开的网页、浏览历史和登录状态会一直保留，锁定或重新打开 App 都不会清除；需要时点右上角「更多」→「清除浏览痕迹」。下载的文件保存在「下载」文件夹。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    /// Page actions, then 锁定 and 清除浏览痕迹, whose question appears at this button.
    private var pageMenu: some View {
        Menu {
            if let url = model.url {
                Section {
                    ShareLink(item: url) {
                        Label("分享链接", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.url = url
                        store.show("已拷贝链接")
                    } label: {
                        Label("拷贝链接", systemImage: "doc.on.doc")
                    }
                    Button { model.download(url) } label: {
                        Label("下载此页面", systemImage: "arrow.down.doc")
                    }
                }
            }
            Section {
                Button { lock.lock() } label: {
                    Label("锁定", systemImage: "lock")
                }
                Button(role: .destructive) { confirmingClear = true } label: {
                    Label("清除浏览痕迹", systemImage: "trash")
                }
                .disabled(session.isClearing)
            }
        } label: {
            BrowserBarIcon(title: "更多", systemImage: "ellipsis.circle")
        }
        .confirmationDialog("清除浏览痕迹？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清除浏览痕迹", role: .destructive) { session.clearTraces(store: store) }
            Button("取消", role: .cancel) {}
        } message: {
            Text(session.clearMessage)
        }
    }

    // MARK: - Actions

    private func go() {
        model.open(address)
        addressFocused = false
    }

    private func showMedia() {
        collectingMedia = true
        Task {
            if let request = await model.collectMedia() {
                sheet = .media(request)
            }
            collectingMedia = false
        }
    }

    /// Every JavaScript dialog is answered through its buttons; closing it otherwise is not possible.
    private var dialogShown: Binding<Bool> {
        Binding(get: { model.dialog != nil }, set: { _ in })
    }
}

private enum BrowserSheet: Identifiable {
    case downloads
    case media(BrowserMediaRequest)

    var id: String {
        switch self {
        case .downloads: return "downloads"
        case .media(let request): return request.id.uuidString
        }
    }
}

/// Hosts the model's web view, which outlives SwiftUI view updates, tab switches and locking. It
/// stays inside the safe area, so pages end above the tab bar instead of underneath it.
private struct BrowserWebContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> BrowserWebHost {
        BrowserWebHost(webView: webView)
    }

    func updateUIView(_ uiView: BrowserWebHost, context: Context) {}
}

/// Takes the web view over from the host it had before locking. The web view keeps its size until
/// this host has one, so the page is never laid out at zero width and keeps its scroll position.
private final class BrowserWebHost: UIView {
    private let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        webView.autoresizingMask = []
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Whichever host is on screen holds the web view.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && webView.superview !== self {
            addSubview(webView)
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !bounds.isEmpty && webView.frame != bounds {
            webView.frame = bounds
        }
    }
}

/// An icon of the top bar with a comfortable tap area; the title is read by VoiceOver.
private struct BrowserBarIcon: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(width: 32, height: 38)
            .contentShape(Rectangle())
    }
}

private struct BrowserDownloadsButton: View {
    @ObservedObject var downloads: BrowserDownloadManager
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BrowserBarIcon(title: "下载", systemImage: downloads.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                .symbolEffect(.pulse, isActive: downloads.activeCount > 0)
        }
    }
}
