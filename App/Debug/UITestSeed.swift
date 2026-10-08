#if DEBUG
import AVFoundation
import ImageIO
import UIKit

/// Debug builds only: launched with `-FileBoxUITestSeed` (the viewer UI test does this), the app
/// unlocks itself and puts a folder of test media into the vault, so the test can go straight to
/// the file list. The pictures are made for measuring positions on screen recordings: a thick red
/// border, a green centre cross and a white 1-px line every 50 px on dark grey.
///
/// Folders: UITest (portrait and landscape pictures and videos, plus a photo and a video stored the
/// way a camera stores them: sideways, with an orientation that turns them upright), and
/// UITestLongImages and UITestLongVideos (enough landscape files that the list runs on under the
/// tab bar).
enum UITestSeed {
    static let argument = "-FileBoxUITestSeed"
    static let folderName = "UITest"
    static let longImagesFolder = "UITestLongImages"
    static let longVideosFolder = "UITestLongVideos"

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    /// Called once at launch. Does nothing unless the test asked for it.
    @MainActor
    static func launchIfRequested() {
        guard isActive else { return }
        LockManager.shared.unlockForUITests()
        ViewerProbe.shared.start()
        ViewerProbe.shared.event("launch seed")
        Task.detached(priority: .userInitiated) {
            let ok = makeFolder()
            await MainActor.run {
                ViewerProbe.shared.event("seed ready ok=\(ok)")
                NotificationCenter.default.post(name: Notification.Name("FileBoxVaultChanged"), object: nil)
            }
        }
    }

    private static func makeFolder() -> Bool {
        let main = folder(folderName, files: [
            "a_portrait.png", "b_landscape.png", "c_portrait.mp4", "d_landscape.mp4", "e_camera.jpg", "f_camera.mov",
        ]) { scratch in
            try png(width: 1200, height: 2400, label: "a portrait image").write(to: scratch.appendingPathComponent("a_portrait.png"))
            try png(width: 1200, height: 600, label: "b landscape image").write(to: scratch.appendingPathComponent("b_landscape.png"))
            try video(to: scratch.appendingPathComponent("c_portrait.mp4"), width: 720, height: 1280, label: "c portrait video")
            try video(to: scratch.appendingPathComponent("d_landscape.mp4"), width: 1280, height: 720, label: "d landscape video")
            // As a camera stores them: the photo sideways with EXIF orientation 6, the video
            // landscape with a quarter-turn transform. Both show upright, in portrait.
            try cameraJPEG(width: 1200, height: 1600, label: "e camera photo").write(to: scratch.appendingPathComponent("e_camera.jpg"))
            try video(to: scratch.appendingPathComponent("f_camera.mov"), width: 720, height: 1280, label: "f camera video",
                      storedSideways: true, fileType: .mov)
        }
        let images = folder(longImagesFolder, files: (1...24).map { String(format: "img_%02d.png", $0) }) { scratch in
            for index in 1...24 {
                try png(width: 1200, height: 600, label: String(format: "long image %02d", index))
                    .write(to: scratch.appendingPathComponent(String(format: "img_%02d.png", index)))
            }
        }
        let videos = folder(longVideosFolder, files: (1...16).map { String(format: "vid_%02d.mp4", $0) }) { scratch in
            for index in 1...16 {
                try video(to: scratch.appendingPathComponent(String(format: "vid_%02d.mp4", index)), width: 640, height: 360,
                          label: String(format: "long video %02d", index), seconds: 6)
            }
        }
        return main && images && videos
    }

    /// Writes one folder's media into a scratch folder and moves it into the vault in one step, so
    /// the list never shows a half-written file. A folder that is already complete (the test's
    /// second launch) is left as it is, so nothing changes under a file that is open.
    private static func folder(_ name: String, files: [String], fill: (URL) throws -> Void) -> Bool {
        let fm = FileManager.default
        let target = Vault.root.appendingPathComponent(name, isDirectory: true)
        if files.allSatisfy({ fm.fileExists(atPath: target.appendingPathComponent($0).path) }) { return true }
        let scratch = fm.temporaryDirectory.appendingPathComponent("uitest-seed-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            try fill(scratch)
            // Fixed dates, so the thumbnail and poster caches always see the same files.
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let names = try fm.contentsOfDirectory(atPath: scratch.path).sorted()
            for (offset, file) in names.enumerated() {
                try fm.setAttributes(
                    [.modificationDate: base.addingTimeInterval(TimeInterval(-offset * 60))],
                    ofItemAtPath: scratch.appendingPathComponent(file).path
                )
            }
            try fm.createDirectory(at: Vault.root, withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: scratch, to: target)
            return true
        } catch {
            NSLog("UITestSeed failed for \(name): \(error)")
            try? fm.removeItem(at: scratch)
            return false
        }
    }

    // MARK: - Pattern

    /// Draws the measuring pattern into `context`, whose origin is at the top left.
    static func drawPattern(_ context: CGContext, width: Int, height: Int, label: String, frame: Int?) {
        let w = CGFloat(width)
        let h = CGFloat(height)
        let border: CGFloat = 24
        context.setFillColor(UIColor(red: 32 / 255, green: 32 / 255, blue: 32 / 255, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // A white line every 50 px.
        context.setFillColor(UIColor.white.cgColor)
        var y: CGFloat = 50
        while y < h {
            context.fill(CGRect(x: border, y: y, width: w - 2 * border, height: 1))
            y += 50
        }
        // Green centre cross.
        context.setFillColor(UIColor(red: 0, green: 1, blue: 0, alpha: 1).cgColor)
        context.fill(CGRect(x: border, y: h / 2 - 3, width: w - 2 * border, height: 6))
        context.fill(CGRect(x: w / 2 - 3, y: border, width: 6, height: h - 2 * border))
        // Thick red border.
        context.setFillColor(UIColor(red: 1, green: 0, blue: 0, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: w, height: border))
        context.fill(CGRect(x: 0, y: h - border, width: w, height: border))
        context.fill(CGRect(x: 0, y: 0, width: border, height: h))
        context.fill(CGRect(x: w - border, y: 0, width: border, height: h))
        // A label in grey (never red or green, so it never confuses the measurement).
        UIGraphicsPushContext(context)
        let text = frame.map { "\(label)  #\($0)" } ?? label
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: max(20, w / 24), weight: .bold),
            .foregroundColor: UIColor(white: 0.75, alpha: 1),
        ]
        (text as NSString).draw(at: CGPoint(x: w * 0.30, y: h * 0.5 + 40), withAttributes: attributes)
        UIGraphicsPopContext()
    }

    private static func png(width: Int, height: Int, label: String) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let data = renderer.pngData { context in
            drawPattern(context.cgContext, width: width, height: height, label: label, frame: nil)
        }
        return data
    }

    /// A JPEG of the pattern, `width` x `height` as shown, stored a quarter turn anticlockwise
    /// (`height` x `width` pixels) with EXIF orientation 6, as an iPhone stores a portrait photo.
    private static func cameraJPEG(width: Int, height: Int, label: String) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let stored = CGSize(width: height, height: width)
        let image = UIGraphicsImageRenderer(size: stored, format: format).image { context in
            context.cgContext.concatenate(sidewaysTransform(shownWidth: CGFloat(width)))
            drawPattern(context.cgContext, width: width, height: height, label: label, frame: nil)
        }
        guard let cgImage = image.cgImage else { throw SeedError.writer }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw SeedError.writer
        }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImagePropertyOrientation: 6,
            kCGImageDestinationLossyCompressionQuality: 0.95,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SeedError.writer }
        return data as Data
    }

    /// Draws the upright picture (top-left origin, `shownWidth` wide) into a frame stored a quarter
    /// turn anticlockwise; turned a quarter turn clockwise (EXIF orientation 6, or the video track's
    /// transform below) it is upright again.
    private static func sidewaysTransform(shownWidth: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: shownWidth)
    }

    /// `seconds` at 10 fps, H.264, the frame number drawn on each frame; twenty seconds unless said
    /// otherwise, long enough that a video never ends in the middle of a test step. `shownWidth` x
    /// `shownHeight` is the picture as shown; `storedSideways` stores it a quarter turn
    /// anticlockwise with a transform that turns it back, as an iPhone records a portrait video.
    private static func video(
        to url: URL,
        width shownWidth: Int,
        height shownHeight: Int,
        label: String,
        seconds: Int = 20,
        storedSideways: Bool = false,
        fileType: AVFileType = .mp4
    ) throws {
        let width = storedSideways ? shownHeight : shownWidth
        let height = storedSideways ? shownWidth : shownHeight
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        if storedSideways {
            // The iPhone camera's portrait transform: a quarter turn clockwise.
            input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0)
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw SeedError.writer }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SeedError.writer }
        writer.startSession(atSourceTime: .zero)
        let fps: Int32 = 10
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for index in 0..<(seconds * Int(fps)) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            guard let pool = adaptor.pixelBufferPool else { throw SeedError.writer }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { throw SeedError.writer }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                // Top-left origin, like the image renderer.
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
                if storedSideways { context.concatenate(sidewaysTransform(shownWidth: CGFloat(shownWidth))) }
                drawPattern(context, width: shownWidth, height: shownHeight, label: label, frame: index)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)) else {
                throw writer.error ?? SeedError.writer
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? SeedError.writer }
    }

    private enum SeedError: Error {
        case writer
    }
}
#endif
