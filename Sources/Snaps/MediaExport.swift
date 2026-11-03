import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

enum MediaExportError: LocalizedError {
    case noVideo
    case cannotRead
    case cannotWrite

    var errorDescription: String? {
        switch self {
        case .noVideo: "The recording has no video."
        case .cannotRead: "The recording couldn’t be read."
        case .cannotWrite: "The file couldn’t be written."
        }
    }
}

/// Poster frames and basic facts about video files.
enum VideoFrames {
    struct Info {
        /// In pixels.
        let size: CGSize
        let duration: Double
        let hasAudio: Bool
    }

    static func info(_ url: URL) async -> Info? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let duration = try? await asset.load(.duration)
        else { return nil }
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        return Info(size: size, duration: duration.seconds, hasAudio: !audio.isEmpty)
    }

    /// The first frame, sized so `maxPixelSize` fits; its point size is half its pixels, like the screenshots' thumbnails.
    static func poster(_ url: URL, maxPixelSize: Int? = nil) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        if let maxPixelSize {
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        }
        guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }
}

enum MediaExport {
    /// Writes `range` of a video to an MP4, optionally without its sound.
    static func exportVideo(from source: URL, to output: URL, range: CMTimeRange?, includeAudio: Bool) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let range = range ?? CMTimeRange(start: .zero, duration: duration)
        let composition = AVMutableComposition()

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw MediaExportError.noVideo }
        let audioTracks = includeAudio ? try await asset.loadTracks(withMediaType: .audio) : []
        for track in videoTracks + audioTracks {
            guard let copy = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try copy.insertTimeRange(range, of: track, at: .zero)
            copy.preferredTransform = try await track.load(.preferredTransform)
        }

        // Recordings bigger than 4K are HEVC, which H.264 can't re-encode at that size.
        let isHEVC = try await videoTracks[0].load(.formatDescriptions).contains {
            CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC
        }
        let preset = isHEVC ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw MediaExportError.cannotWrite
        }
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: output)
        try await session.export(to: output, as: .mp4)
    }

    /// Turns `range` of a video into a looping GIF no wider than `maxWidth` pixels.
    /// Frames that don't change are merged into one longer frame, which keeps screen recordings small.
    static func makeGIF(
        from source: URL,
        to output: URL,
        range: CMTimeRange? = nil,
        frameRate: Int,
        maxWidth: Int?,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaExportError.noVideo }
        let duration = try await asset.load(.duration)
        let natural = try await track.load(.naturalSize)
        let range = range ?? CMTimeRange(start: .zero, duration: duration)

        let scale = maxWidth.map { min(1, CGFloat($0) / max(natural.width, 1)) } ?? 1
        let width = max(2, Int((natural.width * scale).rounded()))
        let height = max(2, Int((natural.height * scale).rounded()))

        try await Task.detached(priority: .userInitiated) {
            try GIFWriter.write(
                asset: asset, track: track, range: range,
                frameRate: frameRate, width: width, height: height,
                to: output, progress: progress
            )
        }.value
    }

    /// Mixes a recording's separate system audio and microphone tracks into one, copying the video as is.
    static func mixAudioTracks(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count > 1, let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { return }
        let formatHint = try await videoTrack.load(.formatDescriptions).first
        let temp = CaptureStorage.temporaryURL(pathExtension: "mp4", replacing: url)

        try await Task.detached(priority: .userInitiated) {
            let reader = try AVAssetReader(asset: asset)
            let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            guard reader.canAdd(videoOutput), reader.canAdd(audioOutput) else { throw MediaExportError.cannotRead }
            reader.add(videoOutput)
            reader.add(audioOutput)

            let writer = try AVAssetWriter(outputURL: temp, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw MediaExportError.cannotWrite }
            writer.add(videoInput)
            writer.add(audioInput)

            guard reader.startReading(), writer.startWriting() else { throw MediaExportError.cannotWrite }
            writer.startSession(atSourceTime: .zero)
            async let video: Void = pump(videoOutput, into: videoInput, label: "video")
            async let audio: Void = pump(audioOutput, into: audioInput, label: "audio")
            _ = await (video, audio)
            await writer.finishWriting()
            guard reader.status == .completed, writer.status == .completed else {
                throw writer.error ?? reader.error ?? MediaExportError.cannotWrite
            }
        }.value

        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String) async {
        let queue = DispatchQueue(label: "dev.nearby.Snaps.mix.\(label)")
        nonisolated(unsafe) let output = output
        nonisolated(unsafe) let input = input
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer(), input.append(buffer) else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}

/// Encodes decoded video frames as an animated GIF.
private enum GIFWriter {
    static func write(
        asset: AVAsset,
        track: AVAssetTrack,
        range: CMTimeRange,
        frameRate: Int,
        width: Int,
        height: Int,
        to output: URL,
        progress: (@Sendable (Double) -> Void)?
    ) throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else { throw MediaExportError.cannotRead }
        reader.add(trackOutput)
        guard reader.startReading() else { throw reader.error ?? MediaExportError.cannotRead }

        let fps = Double(frameRate)
        let total = range.duration.seconds
        let tickCount = max(1, Int((total * fps).rounded(.up)))

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw MediaExportError.cannotWrite }
        context.interpolationQuality = .high

        let gif = try GIFStream(url: output, width: width, height: height)
        var finished = false
        defer { if !finished { gif.abandon() } }

        // Each frame shows from the first tick at or after its time until the next kept frame's tick.
        var held: (image: CGImage, tick: Int)?
        func add(_ image: CGImage, from start: Int, to end: Int) throws {
            let centiseconds = Int((Double(end) * 100 / fps).rounded()) - Int((Double(start) * 100 / fps).rounded())
            try gif.add(image, delay: max(centiseconds, 2))
        }

        while let sample = trackOutput.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = (CMSampleBufferGetPresentationTimeStamp(sample) - range.start).seconds
            let tick = max(0, Int((time * fps - 0.001).rounded(.up)))
            if tick >= tickCount { break }
            // A later frame landing on the same tick replaces the held one.
            if let current = held, current.tick < tick {
                try add(current.image, from: current.tick, to: tick)
            }
            guard let image = render(pixelBuffer, into: context) else { continue }
            held = (image, tick)
            progress?(min(1, time / max(total, 0.001)))
        }
        reader.cancelReading()
        guard let last = held else { throw MediaExportError.noVideo }
        try add(last.image, from: last.tick, to: max(tickCount, last.tick + 1))
        try gif.finish()
        finished = true
        progress?(1)
    }

    private static func render(_ pixelBuffer: CVPixelBuffer, into context: CGContext) -> CGImage? {
        var frame: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &frame)
        guard let frame else { return nil }
        context.draw(frame, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return context.makeImage()
    }
}

/// Writes an animated GIF one frame at a time. ImageIO's animated GIF encoder keeps every frame in memory
/// until it finishes, so each frame is encoded on its own by ImageIO (for its palette and compression)
/// and its image data is copied into this file, with the frame's colors as a local color table.
/// Only the part of a frame that changed is stored, and unchanged frames just extend the previous one,
/// which keeps screen recordings, where little moves, small.
final class GIFStream {
    private let handle: FileHandle
    private let url: URL
    private let width: Int
    private let height: Int
    /// What the GIF shows after the last frame written.
    private var shown: Data?
    /// Held back until the next frame, in case that one is identical and only extends its delay.
    private var pending: (image: CGImage, pixels: Data, bytesPerRow: Int, delay: Int)?

    init(url: URL, width: Int, height: Int) throws {
        self.url = url
        self.width = width
        self.height = height
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw MediaExportError.cannotWrite }
        handle = try FileHandle(forWritingTo: url)

        var header = Data("GIF89a".utf8)
        header.append(le16(width))
        header.append(le16(height))
        header.append(contentsOf: [0x00, 0x00, 0x00]) // no global color table
        // Loop forever.
        header.append(contentsOf: [0x21, 0xFF, 0x0B])
        header.append(Data("NETSCAPE2.0".utf8))
        header.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
        try handle.write(contentsOf: header)
    }

    /// Adds a full-size frame shown for `delay` hundredths of a second.
    func add(_ image: CGImage, delay: Int) throws {
        guard image.width == width, image.height == height,
              let pixels = image.dataProvider?.data as Data?
        else { throw MediaExportError.cannotWrite }
        if let held = pending, held.pixels == pixels {
            pending?.delay += delay
            return
        }
        if let held = pending { try write(held) }
        pending = (image, pixels, image.bytesPerRow, delay)
    }

    func finish() throws {
        if let held = pending { try write(held) }
        pending = nil
        try handle.write(contentsOf: Data([0x3B]))
        try handle.close()
    }

    func abandon() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    private func write(_ frame: (image: CGImage, pixels: Data, bytesPerRow: Int, delay: Int)) throws {
        let rect = shown.flatMap { changedRect(from: $0, to: frame.pixels, bytesPerRow: frame.bytesPerRow) }
            ?? CGRect(x: 0, y: 0, width: width, height: height)
        guard let patch = frame.image.cropping(to: rect) else { throw MediaExportError.cannotWrite }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.gif.identifier as CFString, 1, nil) else {
            throw MediaExportError.cannotWrite
        }
        CGImageDestinationAddImage(destination, patch, nil)
        guard CGImageDestinationFinalize(destination),
              let parsed = Self.parseFirstFrame([UInt8](encoded as Data))
        else { throw MediaExportError.cannotWrite }

        var out = Data()
        // Graphic control extension: leave the frame in place, then wait `delay`.
        out.append(contentsOf: [0x21, 0xF9, 0x04, 0x04])
        out.append(le16(min(frame.delay, 0xFFFF)))
        out.append(contentsOf: [0x00, 0x00])
        // Image descriptor at the patch's position, with its palette as the local color table.
        out.append(0x2C)
        out.append(le16(Int(rect.minX)))
        out.append(le16(Int(rect.minY)))
        out.append(le16(patch.width))
        out.append(le16(patch.height))
        out.append(0x80 | (parsed.flags & 0x40) | parsed.tableSizeBits)
        out.append(contentsOf: parsed.colorTable)
        out.append(contentsOf: parsed.imageData)
        try handle.write(contentsOf: out)
        shown = frame.pixels
    }

    /// The smallest rectangle (top-left origin) containing every pixel that differs, or nil if none do.
    private func changedRect(from old: Data, to new: Data, bytesPerRow: Int) -> CGRect? {
        guard old.count == new.count else { return nil }
        return old.withUnsafeBytes { a -> CGRect? in
            new.withUnsafeBytes { b -> CGRect? in
                guard let pa = a.baseAddress, let pb = b.baseAddress else { return nil }
                let rowBytes = width * 4
                func rowDiffers(_ y: Int) -> Bool {
                    memcmp(pa + y * bytesPerRow, pb + y * bytesPerRow, rowBytes) != 0
                }
                guard let top = (0..<height).first(where: rowDiffers) else {
                    // Nothing changed: a single pixel keeps the frame valid.
                    return CGRect(x: 0, y: 0, width: 1, height: 1)
                }
                let bottom = (top..<height).reversed().first(where: rowDiffers) ?? top
                var left = width
                var right = 0
                for y in top...bottom {
                    let ra = (pa + y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
                    let rb = (pb + y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
                    var x = 0
                    while x < left, ra[x] == rb[x] { x += 1 }
                    if x < left { left = x }
                    x = width - 1
                    while x > right, ra[x] == rb[x] { x -= 1 }
                    if x > right { right = x }
                }
                if left > right { (left, right) = (0, width - 1) }
                return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
            }
        }
    }

    private struct Frame {
        /// The image descriptor's packed flags byte.
        var flags: UInt8
        var tableSizeBits: UInt8
        var colorTable: ArraySlice<UInt8>
        /// LZW minimum code size and the data sub-blocks, through the block terminator.
        var imageData: ArraySlice<UInt8>
    }

    private static func parseFirstFrame(_ b: [UInt8]) -> Frame? {
        guard b.count > 13 else { return nil }
        var pos = 13
        let screenFlags = b[10]
        var globalTable: ArraySlice<UInt8> = []
        var globalBits: UInt8 = 0
        if screenFlags & 0x80 != 0 {
            globalBits = screenFlags & 0x07
            let length = 3 << (Int(globalBits) + 1)
            guard pos + length <= b.count else { return nil }
            globalTable = b[pos..<pos + length]
            pos += length
        }

        func skipSubBlocks() -> Bool {
            while pos < b.count {
                let size = Int(b[pos])
                pos += 1 + size
                if size == 0 { return pos <= b.count }
            }
            return false
        }

        while pos < b.count {
            switch b[pos] {
            case 0x21: // extension
                pos += 2
                guard skipSubBlocks() else { return nil }
            case 0x2C: // image
                guard pos + 10 <= b.count else { return nil }
                let flags = b[pos + 9]
                pos += 10
                var table = globalTable
                var bits = globalBits
                if flags & 0x80 != 0 {
                    bits = flags & 0x07
                    let length = 3 << (Int(bits) + 1)
                    guard pos + length <= b.count else { return nil }
                    table = b[pos..<pos + length]
                    pos += length
                }
                guard !table.isEmpty else { return nil }
                let dataStart = pos
                pos += 1 // LZW minimum code size
                guard skipSubBlocks() else { return nil }
                return Frame(flags: flags, tableSizeBits: bits, colorTable: table, imageData: b[dataStart..<pos])
            default:
                return nil
            }
        }
        return nil
    }
}

private func le16(_ value: Int) -> Data {
    Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
}
