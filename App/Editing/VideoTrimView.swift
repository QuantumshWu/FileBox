import AVFoundation
import SwiftUI
import UIKit

/// Cuts a part out of a video and saves it as a new file next to the original.
struct VideoTrimView: View {
    let item: FileItem

    @EnvironmentObject private var store: FileStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: VideoEditTrimModel
    @State private var precise = false

    init(item: FileItem) {
        self.item = item
        _model = StateObject(wrappedValue: VideoEditTrimModel(item: item))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .loading:
                    ProgressView("正在读取视频…")
                case .failed(let message):
                    ContentUnavailableView("无法剪辑", systemImage: "exclamationmark.triangle", description: Text(message))
                case .ready:
                    editor
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("剪辑视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if model.isExporting {
                            model.cancelExport()
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        model.save(precise: precise, to: store) { dismiss() }
                    }
                    .bold()
                    .disabled(!model.canSave)
                }
            }
            .overlay {
                if let progress = model.exportProgress {
                    VideoEditProgressOverlay(title: "正在导出剪辑…", progress: progress) {
                        model.cancelExport()
                    }
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .task { await model.load() }
        .onDisappear { model.stop() }
        .alert("无法完成", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var editor: some View {
        VStack(spacing: 14) {
            VideoEditPlayerView(player: model.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { model.togglePlay() }
                .overlay {
                    if !model.isPlaying {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(radius: 4)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 8) {
                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(model.isPlaying ? "暂停" : "播放")
                Text("\(VideoEditExport.timeText(model.current)) / \(VideoEditExport.timeText(model.duration))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            VideoEditTimeline(model: model)

            HStack {
                Text("开始 \(VideoEditExport.timeText(model.start))")
                Spacer()
                Text("已选 \(VideoEditExport.lengthText(model.selectedLength))")
                    .foregroundStyle(.yellow)
                Spacer()
                Text("结束 \(VideoEditExport.timeText(model.end))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            Picker("剪辑方式", selection: $precise) {
                Text("快速（无损）").tag(false)
                Text("精确").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(model.isExporting)

            Text(precise ? Self.preciseNote : Self.fastNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }

    private static let fastNote = "直接复制原视频的数据，速度快，画质和 HDR 完全不变。剪切点会对齐到附近的关键帧，实际的开头和结尾可能和所选位置差零点几秒。原视频会保留。"
    private static let preciseNote = "重新编码（HEVC），剪切点精确到帧，但速度较慢，画质会有轻微损失。原视频会保留。"

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

/// Filmstrip with draggable start and end handles and a playhead; dragging anywhere else scrubs.
private struct VideoEditTimeline: View {
    @ObservedObject var model: VideoEditTrimModel

    @State private var startOrigin: Double?
    @State private var endOrigin: Double?

    private let handleWidth: CGFloat = 22
    private let stripHeight: CGFloat = 54
    private let border: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let track = max(1, geometry.size.width - handleWidth * 2)
            let startX = position(of: model.start, track: track)
            let endX = position(of: model.end, track: track)
            ZStack(alignment: .topLeading) {
                filmstrip(track: track)
                    .offset(x: handleWidth, y: border)
                Color.black.opacity(0.6)
                    .frame(width: max(0, startX - handleWidth), height: stripHeight)
                    .offset(x: handleWidth, y: border)
                Color.black.opacity(0.6)
                    .frame(width: max(0, handleWidth + track - endX), height: stripHeight)
                    .offset(x: endX, y: border)
                Rectangle()
                    .fill(Color.yellow)
                    .frame(width: max(0, endX - startX), height: border)
                    .offset(x: startX)
                Rectangle()
                    .fill(Color.yellow)
                    .frame(width: max(0, endX - startX), height: border)
                    .offset(x: startX, y: border + stripHeight)
                handle(systemImage: "chevron.compact.left")
                    .offset(x: startX - handleWidth)
                    .gesture(startGesture(track: track))
                handle(systemImage: "chevron.compact.right")
                    .offset(x: endX)
                    .gesture(endGesture(track: track))
                Capsule()
                    .fill(Color.white)
                    .frame(width: 3, height: stripHeight + border * 2 + 8)
                    .shadow(radius: 1)
                    .offset(x: position(of: model.current, track: track) - 1.5, y: -4)
                    .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(scrubGesture(track: track))
        }
        .frame(height: stripHeight + border * 2)
    }

    private func position(of seconds: Double, track: CGFloat) -> CGFloat {
        handleWidth + CGFloat(seconds / max(model.duration, 0.001)) * track
    }

    private func seconds(forTranslation width: CGFloat, track: CGFloat) -> Double {
        Double(width / track) * model.duration
    }

    private func filmstrip(track: CGFloat) -> some View {
        let cellWidth = track / CGFloat(max(1, model.frames.count))
        return HStack(spacing: 0) {
            ForEach(model.frames.indices, id: \.self) { index in
                Group {
                    if let frame = model.frames[index] {
                        Image(uiImage: frame)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.gray.opacity(0.3)
                    }
                }
                .frame(width: cellWidth, height: stripHeight)
                .clipped()
            }
        }
        .frame(width: track, height: stripHeight, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func handle(systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.yellow)
            .frame(width: handleWidth, height: stripHeight + border * 2)
            .overlay {
                Image(systemName: systemImage)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.black)
            }
            .contentShape(Rectangle())
    }

    // Handles use global coordinates: they move while being dragged, which would distort local ones.
    private func startGesture(track: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if startOrigin == nil {
                    startOrigin = model.start
                    model.beginAdjusting()
                }
                let origin = startOrigin ?? model.start
                model.setStart(origin + seconds(forTranslation: value.translation.width, track: track))
            }
            .onEnded { _ in
                startOrigin = nil
                model.endAdjusting()
            }
    }

    private func endGesture(track: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if endOrigin == nil {
                    endOrigin = model.end
                    model.beginAdjusting()
                }
                let origin = endOrigin ?? model.end
                model.setEnd(origin + seconds(forTranslation: value.translation.width, track: track))
            }
            .onEnded { _ in
                endOrigin = nil
                model.endAdjusting()
            }
    }

    private func scrubGesture(track: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                model.beginAdjusting()
                model.scrub(to: seconds(forTranslation: value.location.x - handleWidth, track: track))
            }
            .onEnded { _ in
                model.endAdjusting()
            }
    }
}

/// Video picture without system controls; the editor draws its own.
private struct VideoEditPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> VideoEditPlayerLayerView {
        let view = VideoEditPlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: VideoEditPlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

private final class VideoEditPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // layerClass guarantees the type.
        layer as! AVPlayerLayer
    }
}
