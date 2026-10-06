import SwiftUI

/// Crop / rotate / adjust an image and save the result as a new file next to the original.
/// Edits show live on a downsampled preview; saving renders the full-size image in the original's
/// format (JPEG, HEIC or PNG, anything else becomes JPEG). The original is never changed.
struct ImageEditorView: View {
    let item: FileItem

    @EnvironmentObject private var store: FileStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ImageEditModel
    @State private var confirmDiscard = false
    @State private var confirmReset = false

    init(item: FileItem) {
        self.item = item
        _model = StateObject(wrappedValue: ImageEditModel(item: item))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ImageEditCanvas(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                if model.preview != nil {
                    toolPanel
                        .frame(maxWidth: .infinity)
                        .frame(height: 142)
                    tabBar
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("编辑图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { toolbarContent }
            .confirmationDialog("放弃对这张图片的编辑？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("放弃编辑", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            }
            .alert("保存失败", isPresented: saveErrorBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(model.saveError ?? "")
            }
        }
        .environment(\.colorScheme, .dark)
        .interactiveDismissDisabled()
        .overlay {
            if model.isSaving { savingOverlay }
        }
        .task { await model.load() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("取消") {
                if model.state.hasEdits {
                    confirmDiscard = true
                } else {
                    dismiss()
                }
            }
            .disabled(model.isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("保存") { save() }
                .fontWeight(.semibold)
                .disabled(!model.state.hasEdits || model.isSaving || model.preview == nil)
        }
    }

    // MARK: - Tool panels

    @ViewBuilder
    private var toolPanel: some View {
        switch model.tool {
        case .crop: cropPanel
        case .rotate: rotatePanel
        case .adjust: adjustPanel
        }
    }

    private var cropPanel: some View {
        VStack(spacing: 16) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(ImageEditAspect.allCases) { aspect in
                        chip(aspect.title, isOn: model.state.aspect == aspect) {
                            model.setAspect(aspect)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            HStack {
                Text("拖动四角或边缘调整，拖动中间移动")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 12)
                Button {
                    model.resetCrop()
                } label: {
                    Label("还原", systemImage: "arrow.uturn.backward")
                        .font(.subheadline)
                }
                .disabled(!model.state.isCropped && model.state.aspect == .free)
            }
            .padding(.horizontal, 16)
        }
    }

    private var rotatePanel: some View {
        HStack(spacing: 12) {
            panelButton("向左旋转", systemImage: "rotate.left") { model.rotate(clockwise: false) }
            panelButton("向右旋转", systemImage: "rotate.right") { model.rotate(clockwise: true) }
            panelButton("水平翻转", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                model.flip()
            }
        }
        .padding(.horizontal, 16)
    }

    private var adjustPanel: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                chip("自动增强", systemImage: "wand.and.stars", isOn: model.state.autoEnhance) {
                    Task { await model.toggleAutoEnhance() }
                }
                if model.isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
                Spacer()
                Button("还原") { model.resetAdjustments() }
                    .font(.subheadline)
                    .disabled(!model.state.hasAdjustments)
            }
            .frame(height: 36)
            sliderRow("亮度", value: $model.state.brightness)
            sliderRow("对比度", value: $model.state.contrast)
            sliderRow("饱和度", value: $model.state.saturation)
        }
        .padding(.horizontal, 16)
    }

    /// A labelled -100...100 slider; double-tap the label to set it back to 0.
    private func sliderRow(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.subheadline)
                .frame(width: 52, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { value.wrappedValue = 0 }
            Slider(value: value, in: -1...1)
            Text(verbatim: "\(Int((value.wrappedValue * 100).rounded()))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .frame(height: 30)
    }

    private func chip(_ title: String, systemImage: String? = nil, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.subheadline.weight(isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isOn ? Color.yellow : Color.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func panelButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title2)
                Text(title)
                    .font(.footnote)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("裁剪", systemImage: "crop", tool: .crop)
            tabButton("旋转", systemImage: "rotate.right", tool: .rotate)
            tabButton("调整", systemImage: "slider.horizontal.3", tool: .adjust)
            Button {
                confirmReset = true
            } label: {
                tabLabel("重置", systemImage: "arrow.counterclockwise", isOn: false)
            }
            .buttonStyle(.plain)
            .disabled(!model.state.hasEdits)
            .opacity(model.state.hasEdits ? 1 : 0.4)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .confirmationDialog("重置所有编辑？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("重置", role: .destructive) { model.resetAll() }
            Button("取消", role: .cancel) {}
        }
    }

    private func tabButton(_ title: String, systemImage: String, tool: ImageEditTool) -> some View {
        Button {
            model.tool = tool
        } label: {
            tabLabel(title, systemImage: systemImage, isOn: model.tool == tool)
        }
        .buttonStyle(.plain)
    }

    private func tabLabel(_ title: String, systemImage: String, isOn: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .frame(height: 24)
            Text(title)
                .font(.caption)
        }
        .foregroundStyle(isOn ? Color.yellow : Color.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: - Saving

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("正在保存…")
                    .foregroundStyle(.white)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(get: { model.saveError != nil }, set: { if !$0 { model.saveError = nil } })
    }

    private func save() {
        Task {
            if await model.save(into: store) { dismiss() }
        }
    }
}
