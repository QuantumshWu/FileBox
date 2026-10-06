import AVFoundation
import Foundation
import ReplayKit

/// Broadcast Upload Extension: records the whole screen into the App Group "Recordings" folder, where
/// the app picks the finished file up the next time it becomes active (or at once if it is open).
///
/// Video is H.264 at the screen's native size, which plays everywhere (Windows included, without
/// extra codecs). App audio and, when the microphone is switched on in the picker, the microphone are
/// two separate AAC tracks: mixing them would need an audio engine in an extension limited to 50 MB.
/// AVPlayer (FileBox, Photos, QuickTime) plays both tracks together; some desktop players only play
/// the first one, the app audio. Samples arriving while an input is busy are dropped, never queued.
@objc(SampleHandler)
final class SampleHandler: RPBroadcastSampleHandler {
    /// Serializes all writer state; ReplayKit may deliver video and audio on different threads.
    private let queue = DispatchQueue(label: "io.github.quantumshwu.filebox.record.writer")
    private var folder: URL?
    private var partialURL: URL?
    private var startDate = Date()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var appAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?
    /// Format of the first buffer each audio input encoded; buffers in another format are dropped.
    private var appAudioFormat: AudioStreamBasicDescription?
    private var micAudioFormat: AudioStreamBasicDescription?
    /// Set once the recording is stopping or has failed; later samples are ignored.
    private var isClosed = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let folder = SharedConfig.sharedRecordingsURL else {
            queue.sync { isClosed = true }
            stop(with: "无法访问 FileBox 的共享文件夹，录屏无法保存。请在 SideStore 里刷新或重新安装 FileBox 后再试。")
            return
        }
        queue.sync {
            self.folder = folder
            partialURL = folder.appendingPathComponent(".partial-\(UUID().uuidString).mp4")
            startDate = Date()
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        let failure: String? = queue.sync {
            guard !isClosed, partialURL != nil, CMSampleBufferDataIsReady(sampleBuffer) else { return nil }
            switch sampleBufferType {
            case .video:
                if writer == nil, let message = startWriting(with: sampleBuffer) { return message }
                append(sampleBuffer, to: videoInput)
            case .audioApp:
                appendAudio(sampleBuffer, to: appAudioInput, format: &appAudioFormat)
            case .audioMic:
                appendAudio(sampleBuffer, to: micAudioInput, format: &micAudioFormat)
            @unknown default:
                break
            }
            guard let writer, writer.status == .failed else { return nil }
            return abandon(writer.error)
        }
        // Outside the queue: ending the broadcast may call broadcastFinished() right away.
        if let failure { stop(with: failure) }
    }

    override func broadcastFinished() {
        var finishing: AVAssetWriter?
        var source: URL?
        var destination: URL?
        var started = Date()
        queue.sync {
            guard !isClosed else { return }
            isClosed = true
            finishing = writer
            source = partialURL
            destination = folder
            started = startDate
        }
        guard let source, let destination else { return }
        let fm = FileManager.default
        guard let finishing, finishing.status == .writing else {
            try? fm.removeItem(at: source)
            return
        }
        // The extension is ended soon after this returns, so wait here until the file is complete.
        // After a timeout the hidden partial file stays behind and the app deletes it later.
        let done = DispatchSemaphore(value: 0)
        finishing.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 10) == .success else { return }
        guard finishing.status == .completed else {
            try? fm.removeItem(at: source)
            return
        }
        let name = "录屏 \(Self.timestamp(started)).mp4"
        if (try? fm.moveItem(at: source, to: fm.uniqueURL(for: name, in: destination))) != nil {
            Self.notifyApp()
        }
    }

    /// Lets FileBox, if it is open (the user stopped while in it), move the recording in right away.
    /// The name must match `CaptureRecordingWatcher.notificationName` in the app.
    private static func notifyApp() {
        let name = CFNotificationName("io.github.quantumshwu.filebox.recording-finished" as CFString)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, nil, nil, true)
    }

    // MARK: - Writing (on `queue`)

    /// Creates the writer from the first video frame, which gives the size, orientation and start
    /// time. Returns an error message if writing could not start.
    private func startWriting(with sampleBuffer: CMSampleBuffer) -> String? {
        guard let partialURL, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer) & ~1
        let height = CVPixelBufferGetHeight(pixelBuffer) & ~1
        guard width > 0, height > 0 else { return nil }
        do {
            let writer = try AVAssetWriter(outputURL: partialURL, fileType: .mp4)
            self.writer = writer
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(width: width, height: height))
            video.expectsMediaDataInRealTime = true
            video.transform = Self.transform(for: sampleBuffer, width: CGFloat(width), height: CGFloat(height))
            let appAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(channels: 2, bitRate: 128_000))
            appAudio.expectsMediaDataInRealTime = true
            let micAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(channels: 1, bitRate: 64_000))
            micAudio.expectsMediaDataInRealTime = true
            for input in [video, appAudio, micAudio] where writer.canAdd(input) {
                writer.add(input)
            }
            guard writer.inputs.contains(video), writer.startWriting() else { return abandon(writer.error) }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            videoInput = video
            appAudioInput = writer.inputs.contains(appAudio) ? appAudio : nil
            micAudioInput = writer.inputs.contains(micAudio) ? micAudio : nil
            return nil
        } catch {
            return abandon(error)
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    /// Appends audio only in the format the input started with. The microphone's format can change
    /// mid-recording (headphones connected), and feeding the encoder another format would fail the
    /// writer and lose the whole recording; losing that track's audio from then on is the lesser harm.
    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?, format: inout AudioStreamBasicDescription?) {
        guard let input, input.isReadyForMoreMediaData,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let incoming = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return }
        if let expected = format, !Self.sameFormat(expected, incoming) { return }
        format = incoming
        input.append(sampleBuffer)
    }

    private static func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
            && a.mChannelsPerFrame == b.mChannelsPerFrame && a.mBitsPerChannel == b.mBitsPerChannel
            && a.mBytesPerFrame == b.mBytesPerFrame
    }

    /// Gives up after a writer error, deletes the unusable file and returns the message to show.
    private func abandon(_ error: Error?) -> String {
        isClosed = true
        if let writer, writer.status == .writing { writer.cancelWriting() }
        writer = nil
        videoInput = nil
        appAudioInput = nil
        micAudioInput = nil
        if let partialURL { try? FileManager.default.removeItem(at: partialURL) }
        let detail = error?.localizedDescription ?? "未知错误"
        return "录屏写入失败（\(detail)）。请检查手机的可用空间后再试。"
    }

    /// Ends the broadcast; ReplayKit shows `message` in its alert.
    private func stop(with message: String) {
        let error = NSError(
            domain: "io.github.quantumshwu.filebox.record",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        finishBroadcastWithError(error)
    }

    // MARK: - Settings

    private static func videoSettings(width: Int, height: Int) -> [String: Any] {
        // Scales with the screen size: about 9-11 Mbps on current iPhones.
        let bitRate = min(12_000_000, max(8_000_000, width * height * 3))
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoExpectedSourceFrameRateKey: 60,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    private static func audioSettings(channels: Int, bitRate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ]
    }

    /// ReplayKit frames always have the screen's portrait layout; the orientation it attaches to the
    /// first frame becomes the track's rotation, so a recording started in landscape plays upright.
    private static func transform(for sampleBuffer: CMSampleBuffer, width: CGFloat, height: CGFloat) -> CGAffineTransform {
        let attachment = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil)
        // CGImagePropertyOrientation raw values: 3/4 down, 5/8 left, 6/7 right (plain/mirrored).
        switch (attachment as? NSNumber)?.uint32Value ?? 1 {
        case 8, 5: // left: turn 90° clockwise
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case 6, 7: // right: turn 90° counterclockwise
            return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        case 3, 4: // upside down
            return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        default:
            return .identity
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }
}
