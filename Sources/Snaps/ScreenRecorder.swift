import AVFoundation
import AppKit
import ScreenCaptureKit

/// What to record: part or all of a display, or a single window wherever it goes.
enum RecordingTarget: Equatable {
    /// `crop` is in the display's points, with a top-left origin, as ScreenCaptureKit expects. Nil records the whole display.
    case display(CGDirectDisplayID, crop: CGRect?)
    case window(CGWindowID)
}

struct RecordingOptions {
    var frameRate: Int
    var showsCursor: Bool
    var showsClicks: Bool
    var systemAudio: Bool
    var microphone: Bool
    /// Records at 1× rather than the display's backing scale, no wider than this many pixels. Used for GIFs.
    var maxWidth: Int?
    var pointScaleOnly = false
}

enum RecordingError: LocalizedError {
    case displayNotFound
    case windowNotFound
    case noFrames
    case cannotWrite

    var errorDescription: String? {
        switch self {
        case .displayNotFound: "That display isn’t available any more."
        case .windowNotFound: "That window isn’t available any more."
        case .noFrames: "Nothing was recorded."
        case .cannotWrite: "The recording couldn’t be written."
        }
    }
}

/// Records the screen with ScreenCaptureKit. Snaps' own windows (previews, the recording controls) never appear in it.
@MainActor
final class ScreenRecorder: NSObject, SCStreamDelegate {
    /// Called if the system ends the stream, e.g. the recorded window closed or the user stopped sharing from the menu bar.
    var onInterrupted: ((Error) -> Void)?

    private var stream: SCStream?
    private var output: StreamOutput?
    private var writer: RecordingWriter?

    /// Starts writing to `url`. Returns the pixel size of the recording.
    @discardableResult
    func start(_ target: RecordingTarget, options: RecordingOptions, to url: URL) async throws -> CGSize {
        // All windows, not just on-screen ones, so Snaps is listed (and excluded) even with nothing of its own showing.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let me = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == me }

        let filter: SCContentFilter
        var sourceRect: CGRect?
        switch target {
        case let .display(id, crop):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw RecordingError.displayNotFound
            }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            sourceRect = crop
        case let .window(id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw RecordingError.windowNotFound
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }
        let isWindow = if case .window = target { true } else { false }

        let points = sourceRect?.size ?? filter.contentRect.size
        var scale = options.pointScaleOnly ? 1 : CGFloat(filter.pointPixelScale)
        if let maxWidth = options.maxWidth, points.width * scale > CGFloat(maxWidth) {
            scale = CGFloat(maxWidth) / points.width
        }
        let size = CGSize(width: Self.even(points.width * scale), height: Self.even(points.height * scale))

        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        if let sourceRect { config.sourceRect = sourceRect }
        if isWindow {
            // A window resized mid-recording is scaled into the frame rather than cropped.
            config.scalesToFit = true
            config.preservesAspectRatio = true
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
        config.queueDepth = 6
        // Click circles are only drawn into BGRA frames.
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = options.showsCursor
        config.showMouseClicks = options.showsClicks
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = options.microphone

        let writer = try RecordingWriter(
            url: url,
            size: size,
            frameRate: options.frameRate,
            systemAudio: options.systemAudio,
            microphone: options.microphone
        )
        let output = StreamOutput(writer: writer)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: writer.queue)
            if options.systemAudio {
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: writer.queue)
            }
            if options.microphone {
                try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: writer.queue)
            }
            try await stream.startCapture()
        } catch {
            writer.cancel()
            throw error
        }

        self.stream = stream
        self.output = output
        self.writer = writer
        return size
    }

    func pause() {
        writer?.pause(at: Self.now)
    }

    func resume() {
        writer?.resume(at: Self.now)
    }

    /// Stops and finishes the file. Returns its URL.
    func stop() async throws -> URL {
        let end = Self.now
        guard let writer else { throw RecordingError.noFrames }
        await stopStream()
        let url = try await writer.finish(at: end)
        self.writer = nil
        if writer.hasSystemAudio && writer.hasMicrophone {
            // Two audio tracks play as one only in some apps, so mix them into one.
            try? await MediaExport.mixAudioTracks(url)
        }
        return url
    }

    /// Stops and throws the recording away.
    func cancel() async {
        await stopStream()
        writer?.cancel()
        writer = nil
    }

    private func stopStream() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        output = nil
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.stream = nil
            self.output = nil
            self.onInterrupted?(error)
        }
    }

    private static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded() * 2)
    }
}

private final class StreamOutput: NSObject, SCStreamOutput {
    let writer: RecordingWriter

    init(writer: RecordingWriter) {
        self.writer = writer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            // Idle frames (nothing changed on screen) carry no image.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete
            else { return }
            writer.appendVideo(buffer)
        case .audio:
            writer.appendAudio(buffer, microphone: false)
        case .microphone:
            writer.appendAudio(buffer, microphone: true)
        @unknown default:
            break
        }
    }
}

/// Writes sample buffers to an MP4, leaving out paused stretches. Everything after `init` happens on `queue`.
final class RecordingWriter: @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.nearby.Snaps.recording", qos: .userInitiated)
    let url: URL
    let hasSystemAudio: Bool
    let hasMicrophone: Bool

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?

    private var sessionStart: CMTime?
    private var lastVideoTime: CMTime?
    /// Where each audio track's written samples end; anything starting earlier would overlap.
    private var audioEnd: [Bool: CMTime] = [:]
    /// Paused stretches in host time; the last one is open while paused.
    private var pauses: [(start: CMTime, end: CMTime?)] = []
    private var isFinished = false

    init(url: URL, size: CGSize, frameRate: Int, systemAudio: Bool, microphone: Bool) throws {
        self.url = url
        hasSystemAudio = systemAudio
        hasMicrophone = microphone
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let pixels = size.width * size.height
        // Hardware H.264 tops out around 4K; bigger displays (5K, 6K) need HEVC.
        let useHEVC = max(size.width, size.height) > 4096 || pixels > 4096 * 2304
        let bitRate = min(max(pixels * Double(frameRate) * (useHEVC ? 0.04 : 0.06), 1_500_000), 60_000_000)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(bitRate),
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if !useHEVC {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: useHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecordingError.cannotWrite }
        writer.add(videoInput)

        systemAudioInput = systemAudio ? try Self.addAudioInput(to: writer) : nil
        microphoneInput = microphone ? try Self.addAudioInput(to: writer) : nil

        guard writer.startWriting() else { throw writer.error ?? RecordingError.cannotWrite }
    }

    /// AAC at 48 kHz stereo; the writer converts whatever the source delivers (mono microphones, 44.1 kHz).
    private static func addAudioInput(to writer: AVAssetWriter) throws -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000,
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.cannotWrite }
        writer.add(input)
        return input
    }

    // MARK: Appending (on `queue`)

    func appendVideo(_ buffer: CMSampleBuffer) {
        guard !isFinished, writer.status == .writing else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard let adjusted = adjusted(time) else { return }
        if sessionStart == nil {
            writer.startSession(atSourceTime: adjusted)
            sessionStart = adjusted
        }
        if let lastVideoTime, adjusted <= lastVideoTime { return }
        guard videoInput.isReadyForMoreMediaData, let retimed = retime(buffer, to: adjusted) else { return }
        if videoInput.append(retimed) {
            lastVideoTime = adjusted
        }
    }

    func appendAudio(_ buffer: CMSampleBuffer, microphone: Bool) {
        guard !isFinished, writer.status == .writing,
              let input = microphone ? microphoneInput : systemAudioInput,
              let sessionStart
        else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        // Around a pause, buffers can straddle the cut; overlapping audio would fail the whole file.
        guard let adjusted = adjusted(time), adjusted >= sessionStart,
              adjusted >= audioEnd[microphone] ?? sessionStart,
              input.isReadyForMoreMediaData,
              let retimed = retime(buffer, to: adjusted)
        else { return }
        if input.append(retimed) {
            let duration = CMSampleBufferGetDuration(buffer)
            audioEnd[microphone] = duration.isValid ? adjusted + duration : adjusted
        }
    }

    // MARK: Control

    func pause(at time: CMTime) {
        queue.async {
            guard self.pauses.last.map({ $0.end != nil }) ?? true else { return }
            self.pauses.append((time, nil))
        }
    }

    func resume(at time: CMTime) {
        queue.async {
            guard let last = self.pauses.indices.last, self.pauses[last].end == nil else { return }
            self.pauses[last].end = time
        }
    }

    func finish(at end: CMTime) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            queue.async {
                self.isFinished = true
                guard let sessionStart = self.sessionStart, self.writer.status == .writing else {
                    self.writer.cancelWriting()
                    try? FileManager.default.removeItem(at: self.url)
                    continuation.resume(throwing: self.writer.error ?? RecordingError.noFrames)
                    return
                }
                // Stopping while paused ends the movie where the pause began.
                let stop = self.pauses.last.flatMap { $0.end == nil ? $0.start : nil } ?? end
                var endTime = self.adjusted(stop, includingOpenPause: false) ?? stop
                if let last = self.lastVideoTime { endTime = max(endTime, last) }
                endTime = max(endTime, sessionStart)

                self.videoInput.markAsFinished()
                self.systemAudioInput?.markAsFinished()
                self.microphoneInput?.markAsFinished()
                self.writer.endSession(atSourceTime: endTime)
                self.writer.finishWriting {
                    if self.writer.status == .completed {
                        continuation.resume(returning: self.url)
                    } else {
                        try? FileManager.default.removeItem(at: self.url)
                        continuation.resume(throwing: self.writer.error ?? RecordingError.cannotWrite)
                    }
                }
            }
        }
    }

    func cancel() {
        queue.async {
            self.isFinished = true
            if self.writer.status == .writing { self.writer.cancelWriting() }
            try? FileManager.default.removeItem(at: self.url)
        }
    }

    // MARK: Timing

    /// Maps a capture time onto the movie's timeline with the pauses cut out. Nil if it falls inside a pause.
    private func adjusted(_ time: CMTime, includingOpenPause: Bool = true) -> CMTime? {
        var offset = CMTime.zero
        for pause in pauses {
            guard time >= pause.start else { break }
            guard let end = pause.end else { return includingOpenPause ? nil : time - offset }
            if time < end { return nil }
            offset = offset + (end - pause.start)
        }
        return time - offset
    }

    private func retime(_ buffer: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        let original = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard original != time else { return buffer }
        let shift = time - original

        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp + shift
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = timing[index].decodeTimeStamp + shift
            }
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        return copy
    }
}
