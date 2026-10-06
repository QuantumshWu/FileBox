import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// Errors of the image editor, worded for the user.
enum ImageEditError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unreadable: return "无法读取原图，文件可能已被移动、删除或损坏。"
        }
    }
}

/// One filter from Core Image's auto-enhance analysis, kept as plain values so the same
/// correction can be applied again to the full-size image.
struct ImageEditAutoFilter: @unchecked Sendable {
    let name: String
    let values: [String: Any]

    init(_ filter: CIFilter) {
        name = filter.name
        var values: [String: Any] = [:]
        for key in filter.inputKeys where key != kCIInputImageKey {
            if let value = filter.value(forKey: key) { values[key] = value }
        }
        self.values = values
    }

    /// `radiusScale` converts pixel radii measured on the preview to the image being rendered.
    func apply(to image: CIImage, radiusScale: CGFloat) -> CIImage {
        guard let filter = CIFilter(name: name) else { return image }
        for (key, value) in values {
            if key == kCIInputRadiusKey, let radius = value as? NSNumber {
                filter.setValue(radius.doubleValue * Double(radiusScale), forKey: key)
            } else {
                filter.setValue(value, forKey: key)
            }
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage ?? image
    }
}

/// The editor's Core Image pipeline, shared by the live preview and the full-size export so both
/// show exactly the same result. Everything here is safe on any thread.
enum ImageEditRenderer {
    /// Reused for every render: contexts are expensive to create and safe to share between threads.
    static let context = CIContext(options: [.cacheIntermediates: false])
    /// CPU renderer for exports that ran while the app was in the background, where iOS refuses GPU work.
    private static let softwareContext = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    /// Longest side of the preview the editor works on.
    static let previewMaxPixels = 2048

    /// Most pixels a full-size export may have right now. Core Image holds the decoded original, its
    /// GPU copy and the rendered result at once (about 16 bytes per pixel with the encoder), and iOS
    /// ends an app that goes past its own memory limit, which is well below the phone's memory.
    private static func exportPixelBudget() -> CGFloat {
        var available = CGFloat(os_proc_available_memory())
        if available <= 0 { available = CGFloat(ProcessInfo.processInfo.physicalMemory) * 0.4 }
        return max(available * 0.6 / 16, 12_000_000)
    }

    private static let previewSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Downsampled upright original plus the upright pixel size of the full image.
    struct Preview: @unchecked Sendable {
        let image: CGImage
        let fullSize: CGSize
    }

    /// A finished edit in a temporary file.
    struct Output: Sendable {
        let url: URL
        let pathExtension: String
        /// Upright size the original was read at when it was too big to edit at full size.
        let reducedSize: CGSize?
    }

    private enum Format {
        case jpeg, heif, png
    }

    // MARK: - Loading

    /// Reads a downsampled copy with ImageIO, with the EXIF orientation applied.
    static func loadPreview(_ url: URL) -> Preview? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = uprightImage(from: source, maxPixels: previewMaxPixels)
        else { return nil }
        let fullSize = uprightSize(of: source) ?? CGSize(width: image.width, height: image.height)
        return Preview(image: image, fullSize: fullSize)
    }

    /// The primary image with its EXIF orientation applied, at most `maxPixels` on the longest side.
    /// ImageIO decodes JPEG and HEIC straight at the reduced size, so this stays cheap for big files.
    private static func uprightImage(from source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
              image.width > 0, image.height > 0
        else { return nil }
        return image
    }

    /// Pixel size of the primary image once its EXIF orientation is applied.
    private static func uprightSize(of source: CGImageSource) -> CGSize? {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }
        // Orientations 5...8 turn the stored pixels by 90°.
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    /// Core Image's suggested auto-enhance filters for the preview (red-eye removal left out).
    static func autoFilters(for base: CGImage) -> [ImageEditAutoFilter] {
        autoreleasepool { () -> [ImageEditAutoFilter] in
            CIImage(cgImage: base)
                .autoAdjustmentFilters(options: [.redEye: false])
                .map(ImageEditAutoFilter.init)
        }
    }

    // MARK: - Rendering

    /// The preview with colours, rotation and flip applied but not cropped (the editor crops on screen).
    static func renderPreview(_ base: CGImage, state: ImageEditState, auto: [ImageEditAutoFilter]) -> CGImage? {
        guard state.quarterTurns != 0 || state.flipped || state.hasAdjustments else { return base }
        return autoreleasepool { () -> CGImage? in
            let output = apply(state, auto: auto, radiusScale: 1, to: CIImage(cgImage: base), crop: false)
            return context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: previewSpace)
        }
    }

    /// Applies the edits in their fixed order: colours, rotation and flip, crop.
    /// `input` must have its extent at the origin.
    static func apply(_ state: ImageEditState, auto: [ImageEditAutoFilter], radiusScale: CGFloat,
                      to input: CIImage, crop: Bool) -> CIImage {
        let extent = input.extent
        var image = input
        if state.autoEnhance && !auto.isEmpty {
            // Some of these filters blur internally; clamping keeps the borders from going dark.
            image = image.clampedToExtent()
            for filter in auto {
                image = filter.apply(to: image, radiusScale: radiusScale)
            }
        }
        if state.brightness != 0 || state.contrast != 0 || state.saturation != 0 {
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            controls.brightness = Float(state.brightness * 0.25)
            controls.contrast = Float(1 + state.contrast * 0.5)
            controls.saturation = Float(1 + state.saturation)
            image = controls.outputImage ?? image
        }
        image = image.cropped(to: extent)
        image = oriented(image, quarterTurns: state.quarterTurns, flipped: state.flipped)
        if crop && state.isCropped {
            image = cropped(image, to: state.crop)
        }
        return image
    }

    /// Whole-pixel rectangle (top-left origin) of a unit-space crop of an image of this size.
    static func pixelRect(_ unit: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        let minX = min(max((unit.minX * width).rounded(), 0), max(width - 1, 0))
        let minY = min(max((unit.minY * height).rounded(), 0), max(height - 1, 0))
        let maxX = min(max((unit.maxX * width).rounded(), minX + 1), width)
        let maxY = min(max((unit.maxY * height).rounded(), minY + 1), height)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Clockwise quarter turns first, then a left-right mirror. Exact 90° steps, so no resampling.
    private static func oriented(_ image: CIImage, quarterTurns: Int, flipped: Bool) -> CIImage {
        var result = image
        let width = image.extent.width
        let height = image.extent.height
        // Core Image's y axis points up, so a clockwise turn maps (x, y) to (y, width - x).
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: result = result.transformed(by: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width))
        case 2: result = result.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height))
        case 3: result = result.transformed(by: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0))
        default: break
        }
        if flipped {
            result = result.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: result.extent.width, ty: 0))
        }
        return result
    }

    private static func cropped(_ image: CIImage, to unit: CGRect) -> CIImage {
        let extent = image.extent
        let pixels = pixelRect(unit, width: extent.width, height: extent.height)
        // Core Image counts y from the bottom.
        let rect = CGRect(
            x: extent.minX + pixels.minX,
            y: extent.minY + extent.height - pixels.maxY,
            width: pixels.width,
            height: pixels.height
        )
        return image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    // MARK: - Export

    /// Renders the edit at full resolution straight into a temporary file, in the original's
    /// format when it is JPEG, HEIC or PNG and as JPEG otherwise (or if that encoder fails).
    /// `software` renders on the CPU, for when the app may be in the background.
    static func export(_ source: URL, state: ImageEditState, auto: [ImageEditAutoFilter],
                       previewWidth: CGFloat, software: Bool) throws -> Output {
        let renderer = software ? softwareContext : context
        // A full-size render leaves large buffers in the context's cache; give that memory back.
        defer { renderer.clearCaches() }
        return try autoreleasepool { () throws -> Output in
            let (original, reducedSize) = try readForExport(source)
            var edited = original.transformed(
                by: CGAffineTransform(translationX: -original.extent.minX, y: -original.extent.minY)
            )
            let radiusScale = previewWidth > 0 ? edited.extent.width / previewWidth : 1
            edited = apply(state, auto: auto, radiusScale: radiusScale, to: edited, crop: true)

            var colorSpace = sRGB
            if let space = original.colorSpace, space.model == .rgb { colorSpace = space }
            let properties = metadata(of: source)
            let sourceFormat = format(of: source)
            var attempts: [Format] = [sourceFormat ?? .jpeg]
            if sourceFormat != nil && sourceFormat != .jpeg { attempts.append(.jpeg) }

            var lastError: Error = ImageEditError.unreadable
            for format in attempts {
                let pathExtension = format == sourceFormat ? source.pathExtension : "jpg"
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("FileBox-edit-\(UUID().uuidString).\(pathExtension)")
                var image = edited
                if format == .jpeg && sourceFormat != .jpeg {
                    // JPEG has no transparency: see-through parts become white instead of black.
                    image = image.composited(over: CIImage(color: .white).cropped(to: image.extent))
                }
                image = image.settingProperties(properties)
                do {
                    try write(image, as: format, to: url, colorSpace: colorSpace, context: renderer)
                    return Output(url: url, pathExtension: pathExtension, reducedSize: reducedSize)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    lastError = error
                }
            }
            throw lastError
        }
    }

    /// The upright original, at full size unless that would not fit in memory. Then it is read at
    /// the largest size that does, and the second value is that size.
    private static func readForExport(_ url: URL) throws -> (CIImage, CGSize?) {
        let budget = exportPixelBudget()
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let size = uprightSize(of: source), size.width * size.height > budget {
            let scale = (budget / (size.width * size.height)).squareRoot()
            let longest = Int((max(size.width, size.height) * scale).rounded(.down))
            guard let image = uprightImage(from: source, maxPixels: longest) else { throw ImageEditError.unreadable }
            return (CIImage(cgImage: image), CGSize(width: image.width, height: image.height))
        }
        guard let original = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
              !original.extent.isInfinite, original.extent.width >= 1, original.extent.height >= 1
        else { throw ImageEditError.unreadable }
        return (original, nil)
    }

    private static func write(_ image: CIImage, as format: Format, to url: URL, colorSpace: CGColorSpace,
                              context: CIContext) throws {
        let quality: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92,
        ]
        switch format {
        case .jpeg:
            try context.writeJPEGRepresentation(of: image, to: url, colorSpace: colorSpace, options: quality)
        case .heif:
            try context.writeHEIFRepresentation(of: image, to: url, format: .RGBA8, colorSpace: colorSpace, options: quality)
        case .png:
            try context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: colorSpace, options: [:])
        }
    }

    private static func format(of url: URL) -> Format? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heif }
        if type.conforms(to: .png) { return .png }
        return nil
    }

    /// The original's EXIF, TIFF and GPS data (capture date, camera...) for the copy. The pixels are
    /// already upright and resized, so orientation and pixel sizes are reset.
    private static func metadata(of url: URL) -> [AnyHashable: Any] {
        var result: [AnyHashable: Any] = [kCGImagePropertyOrientation as String: 1]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)
                as? [String: Any]
        else { return result }
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            result[kCGImagePropertyExifDictionary as String] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            result[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            result[kCGImagePropertyGPSDictionary as String] = gps
        }
        return result
    }
}
