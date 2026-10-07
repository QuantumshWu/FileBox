import ImageIO
import SwiftUI
import UIKit

/// An image that fits the page and can be pinched or double-tapped to zoom and panned while zoomed.
/// At the zoomed image's edge a swipe carries on to the next page of the viewer. At the fitted size
/// a swipe up or down drags the image to close the viewer. Zoomed in past the decoded size, a
/// sharper version is read from `sourceURL`.
struct MediaZoomableImage: UIViewRepresentable {
    let image: UIImage
    /// The file, for reading more detail when zoomed in.
    let sourceURL: URL?
    let onSingleTap: () -> Void
    let onDismissEvent: (ViewerDismissEvent) -> Void

    func makeUIView(context: Context) -> MediaZoomScrollView {
        let view = MediaZoomScrollView()
        configure(view)
        view.display(image)
        return view
    }

    func updateUIView(_ view: MediaZoomScrollView, context: Context) {
        configure(view)
        if view.image !== image { view.display(image) }
    }

    private func configure(_ view: MediaZoomScrollView) {
        view.onSingleTap = onSingleTap
        view.dismiss.onEvent = onDismissEvent
        view.sourceURL = sourceURL
    }
}

final class MediaZoomScrollView: UIScrollView, UIScrollViewDelegate {
    var onSingleTap: (() -> Void)?
    let dismiss = ViewerDismissPan()
    /// The picture handed in (a thumbnail placeholder or the decoded image).
    private(set) var image: UIImage?
    var sourceURL: URL? {
        didSet { if sourceURL != oldValue { sourceChanged() } }
    }

    private let imageView = UIImageView()
    private var laidOutSize: CGSize = .zero
    /// The image's size on screen at the fitted zoom.
    private var fittedSize: CGSize = .zero
    /// The file's own pixel size (orientation applied), read in the background.
    private var nativePixelSize: CGSize?
    /// A sharper decode shown while zoomed in; never more than one at a time.
    private var detailImage: UIImage?
    private var detailTask: Task<Void, Never>?
    private var detailPixels: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)

        dismiss.zoomView = self
        dismiss.install(on: self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(memoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows `newImage`. A sharper version of the same picture (the thumbnail placeholder giving
    /// way to the decoded image) keeps the zoom and position; anything else starts fitted.
    func display(_ newImage: UIImage) {
        let previous = image
        image = newImage
        if let previous, laidOutSize != .zero, Self.sameAspect(previous.size, newImage.size) {
            if detailImage == nil { imageView.image = newImage }
            updateMaximumZoom()
            return
        }
        dropDetail()
        imageView.image = newImage
        laidOutSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A new image or a new page size (rotation) starts again from the fitted size.
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            fitImage()
        }
        centerImage()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { dropDetail() }
    }

    private func fitImage() {
        guard let image, image.size.width > 0, image.size.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        dropDetail()
        minimumZoomScale = 1
        zoomScale = 1
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        fittedSize = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        contentSize = fittedSize
        updateMaximumZoom()
        contentOffset = .zero
    }

    /// Enough to see the file's pixels (at least 4×), and enough for a double tap to fill the screen.
    private func updateMaximumZoom() {
        guard let image, fittedSize.width > 0, fittedSize.height > 0 else { return }
        let pixelWidth = nativePixelSize?.width ?? image.size.width * image.scale
        let pixelZoom = pixelWidth / max(1, fittedSize.width * max(1, traitCollection.displayScale))
        maximumZoomScale = max(min(12, max(4, pixelZoom * 2)), fillScale * 1.5)
    }

    /// The zoom at which the picture covers the whole page.
    private var fillScale: CGFloat {
        guard fittedSize.width > 0, fittedSize.height > 0 else { return 1 }
        return max(bounds.width / fittedSize.width, bounds.height / fittedSize.height)
    }

    private func centerImage() {
        let width = max(contentSize.width, bounds.width)
        let height = max(contentSize.height, bounds.height)
        imageView.center = CGPoint(x: width / 2, y: height / 2)
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    /// Fills the screen around the tapped point (at least 2×); a second double tap fits again.
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let scale = min(maximumZoomScale, max(2.0, fillScale))
        let point = gesture.location(in: imageView)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        zoom(to: rect, animated: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.updateDetail()
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        if zoomScale <= minimumZoomScale + 0.01 { dropDetail() }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        updateDetail()
    }

    // MARK: - Detail when zoomed in

    private static func sameAspect(_ a: CGSize, _ b: CGSize) -> Bool {
        guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return false }
        return abs((a.width / a.height) / (b.width / b.height) - 1) < 0.01
    }

    private func sourceChanged() {
        nativePixelSize = nil
        dropDetail()
        guard let url = sourceURL else { return }
        Task { [weak self] in
            let size = await Task.detached(priority: .utility) { MediaZoomScrollView.pixelSize(of: url) }.value
            guard let self, self.sourceURL == url else { return }
            self.nativePixelSize = size
            self.updateMaximumZoom()
        }
    }

    /// The picture on screen has fewer pixels than the zoom shows: decode the file again, bigger.
    private func updateDetail() {
        guard let image, let url = sourceURL, window != nil, fittedSize.width > 0 else { return }
        guard zoomScale > minimumZoomScale + 0.01 else {
            dropDetail()
            return
        }
        let shown = detailImage ?? image
        let shownWidth = shown.size.width * shown.scale
        let neededWidth = zoomScale * fittedSize.width * max(1, traitCollection.displayScale)
        guard neededWidth > shownWidth * 1.15, let native = nativePixelSize, native.width > shownWidth + 1 else { return }
        let nativeLong = max(native.width, native.height)
        let neededLong = neededWidth * nativeLong / native.width
        let target = min(nativeLong, neededLong * 1.3, 6000)
        let shownLong = max(shown.size.width, shown.size.height) * shown.scale
        guard target > shownLong * 1.05, target > detailPixels else { return }
        detailTask?.cancel()
        detailPixels = target
        detailTask = Task { [weak self] in
            let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
                MediaImageLoader.decode(url, maxPixel: .init(target)).map { UIImage(cgImage: $0) }
            }.value
            guard let self, !Task.isCancelled, let sharper = decoded, self.sourceURL == url,
                  self.zoomScale > self.minimumZoomScale + 0.01,
                  MediaZoomScrollView.sameAspect(sharper.size, self.fittedSize)
            else { return }
            self.detailImage = sharper
            self.imageView.image = sharper
            self.detailTask = nil
        }
    }

    /// Back to the decoded image (zoomed out, off screen, or low on memory).
    private func dropDetail() {
        detailTask?.cancel()
        detailTask = nil
        detailPixels = 0
        guard detailImage != nil else { return }
        detailImage = nil
        imageView.image = image
    }

    @objc private func memoryWarning() {
        dropDetail()
    }

    /// Width and height in pixels as shown (EXIF orientations 5–8 are turned sideways).
    nonisolated static func pixelSize(of url: URL) -> CGSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }
}
