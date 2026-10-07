#if DEBUG
import AVFoundation
import UIKit

/// Debug builds only: launched with `-FileBoxUITestSeed` (the viewer UI test does this), the app
/// unlocks itself and puts a folder of test media into the vault, so the test can go straight to
/// the file list. The pictures are made for measuring positions on screen recordings: a thick red
/// border, a green centre cross and a white 1-px line every 50 px on dark grey.
enum UITestSeed {
    static let argument = "-FileBoxUITestSeed"
    static let folderName = "UITest"

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

    /// Writes the media into a scratch folder and moves it into the vault in one step, so the list
    /// never shows a half-written file.
    private static func makeFolder() -> Bool {
        let fm = FileManager.default
        let target = Vault.root.appendingPathComponent(folderName, isDirectory: true)
        let scratch = fm.temporaryDirectory.appendingPathComponent("uitest-seed-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            try png(width: 1200, height: 2400, label: "a portrait image").write(to: scratch.appendingPathComponent("a_portrait.png"))
            try png(width: 1200, height: 600, label: "b landscape image").write(to: scratch.appendingPathComponent("b_landscape.png"))
            try video(to: scratch.appendingPathComponent("c_portrait.mp4"), width: 720, height: 1280, label: "c portrait video")
            try video(to: scratch.appendingPathComponent("d_landscape.mp4"), width: 1280, height: 720, label: "d landscape video")
            // Fixed dates, so the thumbnail and poster caches always see the same files.
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            for (offset, name) in ["a_portrait.png", "b_landscape.png", "c_portrait.mp4", "d_landscape.mp4"].enumerated() {
                try fm.setAttributes(
                    [.modificationDate: base.addingTimeInterval(TimeInterval(-offset * 60))],
                    ofItemAtPath: scratch.appendingPathComponent(name).path
                )
            }
            try fm.createDirectory(at: Vault.root, withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: scratch, to: target)
            return true
        } catch {
            NSLog("UITestSeed failed: \(error)")
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

    /// Four seconds at 30 fps, H.264, the frame number drawn on each frame.
    private static func video(to url: URL, width: Int, height: Int, label: String) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw SeedError.writer }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SeedError.writer }
        writer.startSession(atSourceTime: .zero)
        let fps: Int32 = 30
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for index in 0..<(4 * Int(fps)) {
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
                drawPattern(context, width: width, height: height, label: label, frame: index)
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
