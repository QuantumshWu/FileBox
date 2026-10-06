import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: FileStore
    @EnvironmentObject private var lock: LockManager

    @State private var newCode = ""
    @State private var confirmCode = ""
    @State private var codeMessage: String?
    @State private var usedBytes: Int64?

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
                Text("App 切到后台会自动锁定。这里的文件不会出现在「文件」App 里，也不会进入 iCloud 或电脑备份，删除 App 就会全部丢失。")
            }

            Section("存储") {
                LabeledContent("已用空间") {
                    if let usedBytes {
                        Text(ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file))
                    } else {
                        ProgressView()
                    }
                }
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
        }
        .navigationTitle("设置")
        .task {
            usedBytes = await Task.detached { Vault.totalSize() }.value
        }
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
