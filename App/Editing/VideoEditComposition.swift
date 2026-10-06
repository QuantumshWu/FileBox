import AVFoundation
import CoreMedia
import UIKit

/// What the merger needs to know about one source video.
struct VideoEditClip {
    /// Kept alive here because tracks only reference their asset weakly.
    let asset: AVURLAsset
    let duration: CMTime
    let videoTrack: AVAssetTrack
    let videoRange: CMTimeRange
    let audioTrack: AVAssetTrack?
    let audioRange: CMTimeRange
    let naturalSize: CGSize
    let transform: CGAffineTransform
    let frameRate: Float
    /// "h264", "hevc", or the raw codec code for anything else.
    let codecFamily: String
    /// `AVVideoTransferFunction_ITU_R_2100_HLG` or `..._SMPTE_ST_2084_PQ` for HDR video, nil for SDR.
    let hdrTransferFunction: String?

    /// Picture size as displayed, after rotation.
    var orientedSize: CGSize {
        CGRect(origin: .zero, size: naturalSize).applying(transform).size
    }

    static func load(_ url: URL) async throws -> VideoEditClip {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (duration, playable) = try await asset.load(.duration, .isPlayable)
        guard playable else { throw VideoEditError.unplayable }
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw VideoEditError.unreadableDuration }
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoEditError.noVideoTrack
        }
        let (size, transform, rate, range) = try await video.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .timeRange
        )
        let formats = try await video.load(.formatDescriptions)
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        var audioRange = CMTimeRange(start: CMTime.zero, duration: CMTime.zero)
        if let audio {
            audioRange = try await audio.load(.timeRange)
        }
        return VideoEditClip(
            asset: asset,
            duration: duration,
            videoTrack: video,
            videoRange: range,
            audioTrack: audio,
            audioRange: audioRange,
            naturalSize: size,
            transform: transform,
            frameRate: rate,
            codecFamily: formats.first.map { Self.family(of: $0) } ?? "?",
            hdrTransferFunction: formats.first.flatMap { Self.hdrTransferFunction(of: $0) }
        )
    }

    private static func hdrTransferFunction(of format: CMFormatDescription) -> String? {
        guard let value = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_TransferFunction
        ) as? String else { return nil }
        if value == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
            return AVVideoTransferFunction_ITU_R_2100_HLG
        }
        if value == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
            return AVVideoTransferFunction_SMPTE_ST_2084_PQ
        }
        return nil
    }

    private static func family(of format: CMFormatDescription) -> String {
        let code = CMFormatDescriptionGetMediaSubType(format)
        let shifts: [UInt32] = [24, 16, 8, 0]
        let characters = shifts.map { Character(Unicode.Scalar(UInt8((code >> $0) & 0xFF))) }
        let text = String(characters)
        switch text {
        case "avc1", "avc3": return "h264"
        case "hvc1", "hev1", "dvh1", "dvhe": return "hevc"
        default: return text
        }
    }
}

/// Builds the composition that plays the clips one after another.
enum VideoEditMerger {
    /// Same picture size, rotation and codec: the samples can be copied without re-encoding.
    static func canPassthrough(_ clips: [VideoEditClip]) -> Bool {
        guard let first = clips.first else { return false }
        return clips.allSatisfy { clip in
            abs(clip.orientedSize.width - first.orientedSize.width) < 1
                && abs(clip.orientedSize.height - first.orientedSize.height) < 1
                && clip.transform == first.transform
                && clip.codecFamily == first.codecFamily
        }
    }

    /// One video track (and one audio track if any clip has sound) with the clips back to back.
    /// A clip without sound gets silence, so picture and sound stay in sync.
    /// For passthrough the video track keeps the clips' rotation; for re-encoding the video
    /// composition applies it instead.
    static func composition(
        of clips: [VideoEditClip],
        passthrough: Bool
    ) throws -> (AVMutableComposition, AVMutableCompositionTrack) {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw VideoEditError.exportFailed }
        let audio = clips.contains { $0.audioTrack != nil }
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil
        var cursor = CMTime.zero
        for clip in clips {
            try append(clip.videoTrack, range: clip.videoRange, length: clip.duration, to: video, at: cursor)
            if let audio {
                try append(clip.audioTrack, range: clip.audioRange, length: clip.duration, to: audio, at: cursor)
            }
            cursor = cursor + clip.duration
        }
        if passthrough, let first = clips.first {
            video.preferredTransform = first.transform
        }
        return (composition, video)
    }

    /// Re-encoding instructions: every clip is turned upright and aspect-fit (letterboxed) into the
    /// first clip's picture size, at the highest frame rate of the clips (at most 60 fps).
    /// With `keepsHDR` (an HEVC export) the result stays HDR when a clip is HDR; otherwise the
    /// compositor renders SDR and tone-maps HDR clips.
    static func videoComposition(
        for clips: [VideoEditClip],
        in composition: AVMutableComposition,
        track: AVMutableCompositionTrack,
        keepsHDR: Bool
    ) -> AVMutableVideoComposition {
        let firstSize = clips.first?.orientedSize ?? CGSize(width: 1920, height: 1080)
        let renderSize = CGSize(
            width: max(2, (firstSize.width / 2).rounded() * 2),
            height: max(2, (firstSize.height / 2).rounded() * 2)
        )
        let fastest = clips.map(\.frameRate).max() ?? 0
        let fps = fastest > 0 ? min(60, max(1, fastest.rounded())) : 30

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero
        for clip in clips {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: clip.duration)
            instruction.backgroundColor = UIColor.black.cgColor
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(fitTransform(for: clip, into: renderSize), at: cursor)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            cursor = cursor + clip.duration
        }
        // The instructions must cover the composition exactly, without a gap or overhang at the end.
        let total = composition.duration
        if let last = instructions.last, total.isNumeric, total > last.timeRange.start {
            last.timeRange = CMTimeRange(start: last.timeRange.start, end: total)
        }
        videoComposition.instructions = instructions
        if keepsHDR, let transfer = clips.compactMap(\.hdrTransferFunction).first {
            videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
            videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
            videoComposition.colorTransferFunction = transfer
        }
        return videoComposition
    }

    /// Copies `range` of `source` (limited to the clip's length) to `cursor`, padding with empty time
    /// so the segment is exactly `length` long.
    private static func append(
        _ source: AVAssetTrack?,
        range: CMTimeRange,
        length: CMTime,
        to track: AVMutableCompositionTrack,
        at cursor: CMTime
    ) throws {
        let segment = CMTimeRange(start: CMTime.zero, duration: length)
        let part = range.intersection(segment)
        guard let source, part.isValid, part.duration > CMTime.zero else {
            track.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: length))
            return
        }
        if part.start > CMTime.zero {
            track.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: part.start))
        }
        try track.insertTimeRange(part, of: source, at: cursor + part.start)
        let tail = length - part.end
        if tail > CMTime.zero {
            track.insertEmptyTimeRange(CMTimeRange(start: cursor + part.end, duration: tail))
        }
    }

    /// Rotates a clip upright, then scales and centers it inside `renderSize`.
    private static func fitTransform(for clip: VideoEditClip, into renderSize: CGSize) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: clip.naturalSize).applying(clip.transform)
        let upright = clip.transform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        guard rect.width > 0, rect.height > 0 else { return upright }
        let scale = min(renderSize.width / rect.width, renderSize.height / rect.height)
        let x = (renderSize.width - rect.width * scale) / 2
        let y = (renderSize.height - rect.height * scale) / 2
        return upright
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: x, y: y))
    }
}
