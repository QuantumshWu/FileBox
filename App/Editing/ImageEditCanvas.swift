import SwiftUI

/// The editor's image area: the whole image under the crop frame while cropping, otherwise the
/// cropped result.
struct ImageEditCanvas: View {
    @ObservedObject var model: ImageEditModel

    var body: some View {
        GeometryReader { geo in
            content(in: CGRect(origin: .zero, size: geo.size))
        }
        .overlay(alignment: .top) { notice }
    }

    @ViewBuilder
    private func content(in bounds: CGRect) -> some View {
        if let error = model.loadError {
            ContentUnavailableView("无法编辑这张图片", systemImage: "exclamationmark.triangle", description: Text(error))
                .frame(width: bounds.width, height: bounds.height)
        } else if let preview = model.preview {
            if model.tool == .crop {
                let frame = Self.fit(preview, in: bounds, inset: 24)
                ZStack {
                    picture(preview, in: frame)
                    // The crop is in the new orientation, so it would sit wrong on the old preview.
                    if model.isPreviewOriented {
                        ImageEditCropOverlay(rect: $model.state.crop, ratio: model.cropRatio, imageFrame: frame)
                    }
                }
            } else {
                let shown = model.croppedPreview(preview)
                picture(shown, in: Self.fit(shown, in: bounds, inset: 12))
            }
        } else {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .frame(width: bounds.width, height: bounds.height)
        }
    }

    private func picture(_ image: CGImage, in frame: CGRect) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }

    @ViewBuilder
    private var notice: some View {
        if let text = model.notice {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 12)
        }
    }

    /// The largest frame with the image's shape inside `bounds` minus a margin.
    private static func fit(_ image: CGImage, in bounds: CGRect, inset: CGFloat) -> CGRect {
        let margin = min(inset, bounds.width / 4, bounds.height / 4)
        let area = bounds.insetBy(dx: margin, dy: margin)
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0, area.width > 0, area.height > 0 else { return .zero }
        let scale = min(area.width / width, area.height / height)
        let size = CGSize(width: width * scale, height: height * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }
}

/// Crop frame over the image: drag a corner or an edge to resize, drag inside to move.
/// `rect` is in unit coordinates of the image; `ratio` (width / height) locks the shape.
struct ImageEditCropOverlay: View {
    @Binding var rect: CGRect
    let ratio: CGFloat?
    /// Where the image is drawn, in this view's coordinates.
    let imageFrame: CGRect

    @State private var dragStart: CGRect?
    @State private var handle: Handle?

    private enum Handle {
        case move
        /// -1 / 1 for the left / right (top / bottom) side that follows the finger, 0 if that axis stays.
        case resize(x: Int, y: Int)
    }

    /// Smallest crop side in points, so the frame stays easy to grab.
    private static let minSide: CGFloat = 36
    private static let grabDistance: CGFloat = 24

    /// The crop in points, relative to the image's top-left corner.
    private var box: CGRect {
        CGRect(
            x: rect.minX * imageFrame.width,
            y: rect.minY * imageFrame.height,
            width: rect.width * imageFrame.width,
            height: rect.height * imageFrame.height
        )
    }

    var body: some View {
        let shown = box.offsetBy(dx: imageFrame.minX, dy: imageFrame.minY)
        ZStack {
            Path { path in
                path.addRect(imageFrame)
                path.addRect(shown)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            gridPath(shown)
                .stroke(Color.white.opacity(handle == nil ? 0.3 : 0.7), lineWidth: 0.5)
            Path { path in path.addRect(shown) }
                .stroke(Color.white, lineWidth: 1)
            cornersPath(shown)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .square))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(drag)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard imageFrame.width > 0, imageFrame.height > 0 else { return }
                let start: CGRect
                let grabbed: Handle?
                // A new touch (or one after a cancelled gesture) starts with no translation.
                if let dragStart, value.translation != .zero {
                    start = dragStart
                    grabbed = handle
                } else {
                    start = box
                    let point = CGPoint(x: value.startLocation.x - imageFrame.minX, y: value.startLocation.y - imageFrame.minY)
                    grabbed = hit(point, in: start)
                    dragStart = start
                    handle = grabbed
                }
                guard let grabbed else { return }
                let moved = adjusted(start, handle: grabbed, by: value.translation)
                rect = ImageEditState.clampedUnit(CGRect(
                    x: moved.minX / imageFrame.width,
                    y: moved.minY / imageFrame.height,
                    width: moved.width / imageFrame.width,
                    height: moved.height / imageFrame.height
                ))
            }
            .onEnded { _ in
                dragStart = nil
                handle = nil
            }
    }

    /// Which part of the frame a touch at `point` grabs: corners first, then edges, then the inside.
    private func hit(_ point: CGPoint, in box: CGRect) -> Handle? {
        let outer = Self.grabDistance
        let inner = min(Self.grabDistance, min(box.width, box.height) / 3)
        guard point.x >= box.minX - outer, point.x <= box.maxX + outer,
              point.y >= box.minY - outer, point.y <= box.maxY + outer
        else { return nil }
        // Distance from each side, positive inside the frame.
        let left = point.x - box.minX
        let right = box.maxX - point.x
        let top = point.y - box.minY
        let bottom = box.maxY - point.y
        func near(_ distance: CGFloat) -> Bool { distance >= -outer && distance <= inner }
        var x = 0
        var y = 0
        if near(left) && (!near(right) || abs(left) <= abs(right)) {
            x = -1
        } else if near(right) {
            x = 1
        }
        if near(top) && (!near(bottom) || abs(top) <= abs(bottom)) {
            y = -1
        } else if near(bottom) {
            y = 1
        }
        if x == 0 && y == 0 { return box.contains(point) ? .move : nil }
        return .resize(x: x, y: y)
    }

    /// The crop after dragging `handle` by `translation`, kept inside the image, at least
    /// `minSide` big and in the locked shape.
    private func adjusted(_ start: CGRect, handle: Handle, by translation: CGSize) -> CGRect {
        let boundsWidth = imageFrame.width
        let boundsHeight = imageFrame.height
        let minSide = min(Self.minSide, boundsWidth, boundsHeight)
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(value, low), high) }

        switch handle {
        case .move:
            return CGRect(
                x: clamp(start.minX + translation.width, 0, boundsWidth - start.width),
                y: clamp(start.minY + translation.height, 0, boundsHeight - start.height),
                width: start.width,
                height: start.height
            )
        case .resize(let sx, let sy):
            // The opposite side stays where it is.
            let anchorX = sx < 0 ? start.maxX : start.minX
            let anchorY = sy < 0 ? start.maxY : start.minY
            let maxWidth = sx < 0 ? anchorX : boundsWidth - anchorX
            let maxHeight = sy < 0 ? anchorY : boundsHeight - anchorY
            var width = start.width + CGFloat(sx) * translation.width
            var height = start.height + CGFloat(sy) * translation.height
            if let ratio, ratio > 0 {
                if sx != 0 && sy != 0 {
                    // Corner: the nearest size with the locked shape.
                    var fitted = (width * ratio + height) / (ratio * ratio + 1)
                    fitted = clamp(fitted, max(minSide, minSide / ratio), min(maxWidth / ratio, maxHeight))
                    height = fitted
                    width = fitted * ratio
                } else if sx != 0 {
                    width = clamp(width, max(minSide, minSide * ratio), min(maxWidth, boundsHeight * ratio))
                    height = width / ratio
                } else {
                    height = clamp(height, max(minSide, minSide / ratio), min(maxHeight, boundsWidth / ratio))
                    width = height * ratio
                }
            } else {
                if sx != 0 { width = clamp(width, minSide, maxWidth) }
                if sy != 0 { height = clamp(height, minSide, maxHeight) }
            }
            let x: CGFloat
            if sx < 0 {
                x = anchorX - width
            } else if sx > 0 {
                x = anchorX
            } else {
                x = clamp(start.midX - width / 2, 0, boundsWidth - width)
            }
            let y: CGFloat
            if sy < 0 {
                y = anchorY - height
            } else if sy > 0 {
                y = anchorY
            } else {
                y = clamp(start.midY - height / 2, 0, boundsHeight - height)
            }
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    private func gridPath(_ box: CGRect) -> Path {
        Path { path in
            for step in 1...2 {
                let x = box.minX + box.width * CGFloat(step) / 3
                let y = box.minY + box.height * CGFloat(step) / 3
                path.move(to: CGPoint(x: x, y: box.minY))
                path.addLine(to: CGPoint(x: x, y: box.maxY))
                path.move(to: CGPoint(x: box.minX, y: y))
                path.addLine(to: CGPoint(x: box.maxX, y: y))
            }
        }
    }

    /// Thick L-shaped marks just outside the frame's corners.
    private func cornersPath(_ box: CGRect) -> Path {
        let outline = box.insetBy(dx: -1.5, dy: -1.5)
        let length = min(22, outline.width / 2, outline.height / 2)
        let corners: [(point: CGPoint, dx: CGFloat, dy: CGFloat)] = [
            (CGPoint(x: outline.minX, y: outline.minY), 1, 1),
            (CGPoint(x: outline.maxX, y: outline.minY), -1, 1),
            (CGPoint(x: outline.minX, y: outline.maxY), 1, -1),
            (CGPoint(x: outline.maxX, y: outline.maxY), -1, -1),
        ]
        return Path { path in
            for corner in corners {
                let p = corner.point
                path.move(to: CGPoint(x: p.x, y: p.y + corner.dy * length))
                path.addLine(to: p)
                path.addLine(to: CGPoint(x: p.x + corner.dx * length, y: p.y))
            }
        }
    }
}
