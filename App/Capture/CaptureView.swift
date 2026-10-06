import ReplayKit
import SwiftUI
import UIKit

/// Screenshots (Shortcuts + Back Tap) and screen recording (broadcast extension) into the vault.
struct CaptureView: View {
    @EnvironmentObject private var store: FileStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var pickerHandle = CapturePickerHandle()
    /// True from tapping the record button until the system sheet makes the app inactive.
    @State private var awaitsPicker = false
    /// Shows the system picker button itself when the styled button could not open the sheet.
    @State private var showsSystemPicker = false
    @State private var sharedFolderAvailable = true

    init() {}

    var body: some View {
        List {
            screenshotSection
            recordingSection
        }
        .navigationTitle("截图与录屏")
        .onAppear {
            // The broadcast sheet makes the app inactive; the privacy shield must not cover it.
            PrivacyShield.shared.isSuppressed = true
            CaptureRecordingWatcher.watch(store)
        }
        .onDisappear {
            PrivacyShield.shared.isSuppressed = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { awaitsPicker = false }
        }
        .task {
            sharedFolderAvailable = SharedConfig.sharedRecordingsURL != nil
        }
    }

    // MARK: - Screenshots

    private var screenshotSection: some View {
        Section {
            CaptureStepList(steps: [
                "打开「快捷指令」App，点右上角「+」新建快捷指令。",
                "搜索并添加「截屏」操作。",
                "再搜索「FileBox」，添加「保存截图到 FileBox」，截图选上一步的「截屏」（一般会自动连好）。",
                "点顶部的名称，命名为「截图到 FileBox」之类，点「完成」。",
                "打开「设置」→「辅助功能」→「触控」→「轻点背面」→「轻点两下」，选这个快捷指令。",
                "轻点两下手机背面试一下。第一次如果询问是否允许共享给 FileBox，选「始终允许」。",
            ])
            Button {
                if let url = URL(string: "shortcuts://create-shortcut") { openURL(url) }
            } label: {
                Label("打开「快捷指令」", systemImage: "arrow.up.right.square")
            }
            NavigationLink(value: Route.folder(Vault.folder(Vault.screenshotsName))) {
                Label("查看「截图」文件夹", systemImage: "photo.on.rectangle")
            }
        } header: {
            Text("截图")
        } footer: {
            Text("只需设置一次。以后在任何界面轻点手机背面两下就会截图，并直接存进 FileBox 的「截图」文件夹，不会进入「照片」。快捷指令里还有「保存文件到 FileBox」，可以把任意文件存进「收件箱」。")
        }
    }

    // MARK: - Screen recording

    private var recordingSection: some View {
        Section {
            recordButton
            if showsSystemPicker {
                HStack(spacing: 12) {
                    CaptureBroadcastPicker(handle: nil)
                        .frame(width: 52, height: 52)
                    Text("如果点上面的按钮没有弹出窗口，请点左边的图标开始录屏。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if !sharedFolderAvailable {
                Label("共享文件夹不可用，录屏无法保存。请在 SideStore 里刷新或重新安装 FileBox。", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            CaptureStepList(steps: [
                CaptureRecordExtension.bundleID == nil
                    ? "点「开始录屏」，在弹出的列表里选「FileBox 录屏」。需要录下自己的声音就打开「麦克风」。"
                    : "点「开始录屏」。需要录下自己的声音，就在弹出的窗口里打开「麦克风」。",
                "点「开始直播」，3 秒后开始录制，这时可以切到任意 App。",
                "录完点屏幕顶部的红色标记（或灵动岛），选「停止」。",
                "录屏保存到「录屏」文件夹，回到 FileBox 就能看到。",
            ])
            NavigationLink(value: Route.folder(Vault.folder(Vault.recordingsName))) {
                Label("查看「录屏」文件夹", systemImage: "film")
            }
        } header: {
            Text("录屏")
        } footer: {
            Text("也可以从控制中心开始：长按「屏幕录制」按钮，选「FileBox 录屏」，再点「开始直播」。画面方向以开始录制时为准：要录横屏的游戏或视频，先打开那个 App 并把手机横过来，再从控制中心开始。受保护的内容（例如部分视频 App 的画面）录下来会是黑屏。打开麦克风时，你的声音是单独的一条音轨，有些电脑播放器只播放 App 的声音。录屏不会进入「照片」。")
        }
    }

    private var recordButton: some View {
        Button(action: startRecording) {
            HStack(spacing: 14) {
                Image(systemName: "record.circle")
                    .font(.system(size: 36))
                VStack(alignment: .leading, spacing: 2) {
                    Text("开始录屏")
                        .font(.headline)
                    Text("录下整个屏幕，包括其他 App")
                        .font(.footnote)
                        .opacity(0.85)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            // The real system picker sits invisibly behind the styled button; tapping presses it.
            .background {
                CaptureBroadcastPicker(handle: pickerHandle)
                    .opacity(0.02)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .listRowBackground(Color.clear)
    }

    private func startRecording() {
        guard pickerHandle.trigger() else {
            showsSystemPicker = true
            return
        }
        // If the sheet does not appear (the app stays active, see onChange, and nothing is presented
        // over it), offer the system button.
        awaitsPicker = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if awaitsPicker && !pickerHandle.isPresentingSheet {
                showsSystemPicker = true
            }
            awaitsPicker = false
        }
    }
}

/// Numbered setup steps.
private struct CaptureStepList: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.accentColor))
                    Text(step)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The system broadcast picker, preset to FileBox's own extension.
private struct CaptureBroadcastPicker: UIViewRepresentable {
    /// Receives the view so a custom button can press it; nil for a visible picker.
    let handle: CapturePickerHandle?

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 52, height: 52))
        picker.preferredExtension = CaptureRecordExtension.bundleID
        picker.showsMicrophoneButton = true
        picker.tintColor = .systemRed
        handle?.picker = picker
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {
        handle?.picker = picker
    }
}

/// Lets the styled record button press the picker's internal button, which opens the system sheet.
private final class CapturePickerHandle {
    weak var picker: RPSystemBroadcastPickerView?

    /// Returns false if there is no button to press (the picker's internals changed).
    @MainActor
    func trigger() -> Bool {
        guard let picker else { return false }
        picker.layoutIfNeeded()
        guard let button = Self.firstButton(in: picker) else { return false }
        button.sendActions(for: .touchUpInside)
        return true
    }

    /// True while a sheet (the picker's, if it opened inside the app) covers the screen.
    @MainActor
    var isPresentingSheet: Bool {
        picker?.window?.rootViewController?.presentedViewController != nil
    }

    @MainActor
    private static func firstButton(in view: UIView) -> UIButton? {
        for subview in view.subviews {
            if let button = subview as? UIButton { return button }
            if let nested = firstButton(in: subview) { return nested }
        }
        return nil
    }
}

/// The embedded FileBoxRecord broadcast upload extension.
private enum CaptureRecordExtension {
    /// Its bundle ID as installed. SideStore re-signs extensions under new IDs, so it is read from the
    /// app bundle instead of being hard-coded. Nil if it is missing; the picker then lists every
    /// broadcast extension on the phone.
    static let bundleID: String? = {
        guard let plugIns = Bundle.main.builtInPlugInsURL,
              let urls = try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)
        else { return nil }
        for url in urls where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url),
                  let info = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                  info["NSExtensionPointIdentifier"] as? String == "com.apple.broadcast-services-upload"
            else { continue }
            return bundle.bundleIdentifier
        }
        return nil
    }()
}

/// Moves a finished recording into the vault as soon as the extension reports it. Recordings are
/// normally collected when the app becomes active, but one stopped while FileBox is open is finished
/// only after that. Observes for the rest of the process once the capture screen has been shown.
private enum CaptureRecordingWatcher {
    /// Posted by FileBoxRecord's SampleHandler after it renames a finished recording.
    static let notificationName = "io.github.quantumshwu.filebox.recording-finished"

    @MainActor private static weak var store: FileStore?
    @MainActor private static var isObserving = false

    @MainActor
    static func watch(_ store: FileStore) {
        self.store = store
        guard !isObserving else { return }
        isObserving = true
        startObserving()
    }

    private static func startObserving() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                Task { @MainActor in CaptureRecordingWatcher.recordingFinished() }
            },
            notificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    @MainActor
    private static func recordingFinished() {
        store?.collectIncoming()
    }
}
