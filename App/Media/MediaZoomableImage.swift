import SwiftUI
import UIKit

/// An image that fits the page and can be pinched or double-tapped to zoom and panned while zoomed.
/// At the zoomed image's edge a swipe carries on to the next page of the viewer.
struct MediaZoomableImage: UIViewRepresentable {
    let image: UIImage
    let onSingleTap: () -> Void

    func makeUIView(context: Context) -> MediaZoomScrollView {
        let view = MediaZoomScrollView()
        view.onSingleTap = onSingleTap
        view.display(image)
        return view
    }

    func updateUIView(_ view: MediaZoomScrollView, context: Context) {
        view.onSingleTap = onSingleTap
        if view.image !== image { view.display(image) }
    }
}

final class MediaZoomScrollView: UIScrollView, UIScrollViewDelegate {
    var onSingleTap: (() -> Void)?
    private(set) var image: UIImage?

    private let imageView = UIImageView()
    private var laidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .black
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        decelerationRate = .fast
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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ newImage: UIImage) {
        image = newImage
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

    private func fitImage() {
        guard let image, image.size.width > 0, image.size.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        minimumZoomScale = 1
        zoomScale = 1
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fitted = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        // Enough to see the pixels of a big photo, and at least 4× for small ones.
        let pixelZoom = (image.size.width * image.scale) / max(1, fitted.width * max(1, traitCollection.displayScale))
        maximumZoomScale = min(12, max(4, pixelZoom * 2))
        contentOffset = .zero
    }

    private func centerImage() {
        let width = max(contentSize.width, bounds.width)
        let height = max(contentSize.height, bounds.height)
        imageView.center = CGPoint(x: width / 2, y: height / 2)
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let scale = min(maximumZoomScale, 2.5)
        let point = gesture.location(in: imageView)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        zoom(to: rect, animated: true)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }
}
