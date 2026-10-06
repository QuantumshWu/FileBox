import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Serves the vault over HTTP on the local Wi-Fi so a computer's browser can download and upload.
/// The server runs only while this screen is visible and the app is in the foreground.
struct TransferView: View {
    @EnvironmentObject private var store: FileStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = TransferController()

    init() {}

    var body: some View {
        List {
            statusSection
            if controller.status == .running {
                addressSection
            }
            if !controller.transfers.isEmpty {
                activeSection
            }
            howToSection
            logSection
        }
        .navigationTitle("Wi-Fi 传输")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            controller.appear(store: store, sceneActive: scenePhase == .active)
        }
        .onDisappear {
            controller.disappear()
        }
        .onChange(of: scenePhase) { _, phase in
            controller.sceneChanged(active: phase == .active)
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(statusColor.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Wi-Fi 传输")
                        .font(.title3.weight(.semibold))
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Wi-Fi 传输", isOn: enabledBinding)
                    .labelsHidden()
            }
            .padding(.vertical, 6)
        }
    }

    private var addressSection: some View {
        Section {
            if let address = controller.address {
                if controller.isLocalNetworkDenied {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("FileBox 没有「本地网络」权限", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("电脑现在打不开这个地址。请在「设置」里找到 FileBox，打开「本地网络」，再回到这里。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("打开设置", systemImage: "gear")
                    }
                }
                VStack(spacing: 16) {
                    Text(address)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .textSelection(.enabled)
                    TransferQRCodeView(text: address)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                Button {
                    UIPasteboard.general.string = address
                    store.show("地址已复制")
                } label: {
                    Label("复制地址", systemImage: "doc.on.doc")
                }
            } else {
                Label("没有找到 Wi-Fi 地址", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
                Text("请让手机连上 Wi-Fi，并让电脑连同一个 Wi-Fi。没有 Wi-Fi 时，也可以打开手机的「个人热点」让电脑连上。连上后这里会自动显示地址。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("在电脑浏览器里打开")
        } footer: {
            if controller.address != nil && controller.host?.isHotspot == true {
                Text("这是「个人热点」的地址：电脑需要连接这台 iPhone 的热点。")
            }
        }
    }

    private var activeSection: some View {
        Section("正在传输") {
            ForEach(controller.transfers) { transfer in
                VStack(alignment: .leading, spacing: 6) {
                    Label(transfer.name, systemImage: transfer.isUpload ? "arrow.down.circle" : "arrow.up.circle")
                        .lineLimit(1)
                    ProgressView(value: transfer.fraction)
                    Text("\(transfer.isUpload ? "接收" : "发送") \(bytes(transfer.done)) / \(bytes(transfer.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var howToSection: some View {
        Section {
            TransferStepRow(number: 1, text: "电脑和手机连同一个 Wi-Fi")
            TransferStepRow(number: 2, text: "用电脑浏览器打开上面的地址")
            TransferStepRow(number: 3, text: "在网页里下载文件，或者把文件拖进网页上传到 FileBox")
            TransferStepRow(number: 4, text: "传输时请保持 FileBox 在前台、屏幕常亮")
        } header: {
            Text("使用方法")
        } footer: {
            Text("地址里的随机码每次开启都会更换，只有看到这个地址的人才能访问。离开这个页面或切到后台，传输会自动停止。如果电脑打不开网页：确认两台设备连的是同一个 Wi-Fi（访客网络通常互相隔离），并在「设置 → 隐私与安全性 → 本地网络」里允许 FileBox。")
        }
    }

    private var logSection: some View {
        Section("最近传输") {
            if controller.log.isEmpty {
                Text("还没有传输记录")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.log) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: entry.symbol)
                            .font(.title3)
                            .foregroundStyle(entry.isError ? Color.red : Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .lineLimit(2)
                            if let detail = entry.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(entry.date, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Status

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { controller.isEnabled },
            set: { controller.setEnabled($0) }
        )
    }

    private var statusText: String {
        switch controller.status {
        case .off: return controller.isEnabled ? "已暂停" : "已关闭"
        case .starting: return "正在启动…"
        case .running: return controller.port.map { "正在运行 · 端口 \($0)" } ?? "正在运行"
        case .waiting: return "等待网络连接…"
        case .failed(let message): return "启动失败：\(message)"
        }
    }

    private var statusSymbol: String {
        switch controller.status {
        case .off: return "wifi.slash"
        case .starting, .running: return "wifi"
        case .waiting: return "wifi.exclamationmark"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .off: return .gray
        case .starting, .waiting: return .orange
        case .running: return .green
        case .failed: return .red
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

private struct TransferStepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            Text(text)
        }
    }
}

/// The address as a QR code, e.g. for a tablet's camera.
private struct TransferQRCodeView: View {
    let text: String

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(10)
            }
        }
        .frame(width: 180, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("地址二维码")
        .task(id: text) {
            image = Self.makeImage(for: text)
        }
    }

    private static func makeImage(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
