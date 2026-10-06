import SwiftUI
import UIKit
import WebKit

/// Private (non-persistent) web browser that saves downloads into the vault.
struct BrowserView: View {
    @EnvironmentObject private var store: FileStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BrowserModel()

    @State private var address = ""
    @FocusState private var addressFocused: Bool
    @State private var sheet: BrowserSheet?
    @State private var collectingMedia = false
    @State private var confirmLeave = false
    @State private var promptText = ""

    init() {}

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            progressLine
            Divider()
            BrowserWebContainer(webView: model.webView)
                .overlay {
                    if model.url == nil && !model.isLoading {
                        startPage
                    }
                }
        }
        // A custom back button instead of the system one: the edge swipe then goes back in the page
        // history, and leaving can warn about running downloads.
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .toolbar { bottomBar }
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
        .confirmationDialog("下载还没完成", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("停止下载并离开", role: .destructive) { dismiss() }
            Button("继续下载", role: .cancel) {}
        } message: {
            Text("离开浏览器会停止没下载完的文件。")
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
        .onAppear { model.attach(store) }
        .onDisappear { model.shutdown() }
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
            if model.url == nil { addressFocused = true }
        }
    }

    // MARK: - Address bar

    private var addressBar: some View {
        HStack(spacing: 10) {
            if !addressFocused {
                Button(action: leave) {
                    Image(systemName: "chevron.backward")
                        .font(.title3.weight(.semibold))
                }
                .accessibilityLabel("返回")
            }
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
            if addressFocused {
                Button("取消") { addressFocused = false }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .animation(.default, value: addressFocused)
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

    /// The host while browsing (like Safari); the full address appears when editing.
    private var displayAddress: String {
        guard let url = model.url else { return "" }
        return url.host ?? url.absoluteString
    }

    private var startPage: some View {
        ContentUnavailableView {
            Label("无痕浏览", systemImage: "eye.slash")
        } description: {
            Text("在上方输入网址，或输入文字用必应搜索。\n离开浏览器后，浏览记录、Cookie 和网站数据都会清除；下载的文件保存在「下载」文件夹。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button { model.webView.goBack() } label: {
                Label("后退", systemImage: "chevron.left")
            }
            .disabled(!model.canGoBack)
            Spacer()
            Button { model.webView.goForward() } label: {
                Label("前进", systemImage: "chevron.right")
            }
            .disabled(!model.canGoForward)
            Spacer()
            Button(action: showMedia) {
                Label("本页媒体", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(model.url == nil || collectingMedia)
            Spacer()
            pageMenu
            Spacer()
            BrowserDownloadsButton(downloads: model.downloads) { sheet = .downloads }
        }
    }

    private var pageMenu: some View {
        Menu {
            if let url = model.url {
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
        } label: {
            Label("分享", systemImage: "square.and.arrow.up")
        }
        .disabled(model.url == nil)
    }

    // MARK: - Actions

    private func go() {
        model.open(address)
        addressFocused = false
    }

    private func leave() {
        if model.downloads.activeCount > 0 {
            confirmLeave = true
        } else {
            dismiss()
        }
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

/// Hosts the model's web view, which outlives SwiftUI view updates.
private struct BrowserWebContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> BrowserWebHost {
        BrowserWebHost(webView: webView)
    }

    func updateUIView(_ uiView: BrowserWebHost, context: Context) {}
}

/// Holds the web view and, while on screen, turns off the navigation controller's swipe-back
/// gestures, so a swipe goes back in the page history instead of closing the browser (and with it
/// the private session).
private final class BrowserWebHost: UIView {
    /// The gestures turned off here and whether each was enabled before.
    private var paused: [(gesture: UIGestureRecognizer, wasEnabled: Bool)] = []

    init(webView: WKWebView) {
        super.init(frame: .zero)
        webView.frame = bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(webView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            restoreGestures()
        } else if paused.isEmpty {
            pauseGestures()
        }
    }

    /// Tries again if the navigation controller was not reachable yet when the view joined the window.
    override func layoutSubviews() {
        super.layoutSubviews()
        if window != nil && paused.isEmpty {
            pauseGestures()
        }
    }

    private func pauseGestures() {
        guard let navigation = enclosingNavigationController() else { return }
        var candidates: [UIGestureRecognizer?] = [navigation.interactivePopGestureRecognizer]
        if #available(iOS 26.0, *) {
            // Swiping anywhere on the content pops since iOS 26.
            candidates.append(navigation.interactiveContentPopGestureRecognizer)
        }
        let gestures = candidates.compactMap { $0 }
        paused = gestures.map { (gesture: $0, wasEnabled: $0.isEnabled) }
        gestures.forEach { $0.isEnabled = false }
    }

    private func restoreGestures() {
        for entry in paused {
            entry.gesture.isEnabled = entry.wasEnabled
        }
        paused = []
    }

    private func enclosingNavigationController() -> UINavigationController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller.navigationController ?? (controller as? UINavigationController)
            }
            responder = current.next
        }
        return nil
    }
}

private struct BrowserDownloadsButton: View {
    @ObservedObject var downloads: BrowserDownloadManager
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("下载", systemImage: downloads.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                .symbolEffect(.pulse, isActive: downloads.activeCount > 0)
        }
    }
}
