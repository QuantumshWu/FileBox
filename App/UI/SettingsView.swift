import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: FileStore
    @EnvironmentObject private var lock: LockManager
    @EnvironmentObject private var browser: BrowserSession

    /// Seconds a double tap on the left or right of a video skips.
    @AppStorage("mediaDoubleTapStep") private var doubleTapStep = 10
    @AppStorage("mediaResumePosition") private var resumePosition = true
    /// "track": previous / next file; "skip": back / forward 15 seconds.
    @AppStorage("mediaLockScreenButtons") private var lockScreenButtons = "track"

    @State private var newCode = ""
    @State private var confirmCode = ""
    @State private var codeMessage: String?
    @State private var usedBytes: Int64?
    @State private var trashBytes: Int64?
    @State private var confirmingClear = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                SecureField("新口令", text: $newCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("再输入一次", text: $confirmCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("修改口令", action: changeCode)
                    .disabled(newCode.isEmpty || confirmCode.isEmpty)
                if let codeMessage {
                    Text(codeMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("口令")
            } footer: {
                Text("在首页的搜索框里输入口令就会显示你的文件。不区分大小写。")
            }

            Section {
                Button("立即锁定") { lock.lock() }
            } header: {
                Text("隐私")
            } footer: {
                Text("从后台划掉 FileBox 或点「锁定」后才会上锁；切到后台再回来不用重新输入口令。这里的文件不会出现在「文件」App 里，也不会进入 iCloud 或电脑备份，删除 App 就会全部丢失。")
            }

            Section {
                Button("清除浏览痕迹", role: .destructive) { confirmingClear = true }
                    .disabled(browser.isClearing)
                    .confirmationDialog("清除浏览痕迹？", isPresented: $confirmingClear, titleVisibility: .visible) {
                        Button("清除浏览痕迹", role: .destructive) { browser.clearTraces(store: store) }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text(browser.clearMessage)
                    }
            } header: {
                Text("浏览器")
            } footer: {
                Text("网页、Cookie、登录状态和下载记录会一直保留，锁定或切到后台都不会清除。清除后浏览器回到起始页，已下载的文件仍在「下载」里。")
            }

            Section {
                Picker("双击快进/快退", selection: $doubleTapStep) {
                    ForEach([5, 10, 15, 30], id: \.self) { seconds in
                        Text("\(seconds) 秒").tag(seconds)
                    }
                }
                Toggle("记住播放位置", isOn: $resumePosition)
                Picker("锁屏按钮", selection: $lockScreenButtons) {
                    Text("上一个/下一个").tag("track")
                    Text("快退/快进 15 秒").tag("skip")
                }
            } header: {
                Text("播放")
            } footer: {
                Text("较长的视频和音频会从上次停下的地方继续播放。")
            }
            .onChange(of: lockScreenButtons) {
                MediaPlaybackController.shared.lockScreenButtonsChanged()
            }

            Section("存储") {
                LabeledContent("已用空间") {
                    sizeText(usedBytes)
                }
                LabeledContent("回收站占用") {
                    sizeText(trashBytes)
                }
                NavigationLink("回收站", value: Route.trash)
            }

            Section("关于") {
                LabeledContent("版本", value: version)
                Text(Bundle.main.bundleIdentifier ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(SharedConfig.diagnostics)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            Section {
                Text(MediaDiagnostics.text)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text("小窗记录")
            } footer: {
                Text("小窗没出现时，截一张这里的图发给开发者。")
            }
        }
        .navigationTitle("设置")
        .task {
            usedBytes = await Task.detached { Vault.totalSize() }.value
            trashBytes = await Task.detached { SettingsView.trashSize() }.value
        }
    }

    @ViewBuilder
    private func sizeText(_ bytes: Int64?) -> some View {
        if let bytes {
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        } else {
            ProgressView()
        }
    }

    /// Everything waiting in the trash (its 7 days are not up yet).
    nonisolated private static func trashSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: Vault.trashRoot, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    private func changeCode() {
        guard newCode == confirmCode else {
            codeMessage = "两次输入的不一样"
            return
        }
        codeMessage = lock.changePasscode(to: newCode) ? "口令已修改" : "口令不能为空"
        newCode = ""
        confirmCode = ""
    }
}
