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

    /// True when the last saved recording kept separate system and microphone tracks after a mix failure.
    private(set) var savedSeparateAudioTracks = false

    private var stream: SCStream?
    private var output: StreamOutput?
    private var writer: RecordingWriter?

    /// Starts writing to `url`. Returns the pixel size of the recording.
    @discardableResult
    func start(_ target: RecordingTarget, options: RecordingOptions, to url: URL) async throws -> CGSize {
        savedSeparateAudioTracks = false
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
        self.writer = nil
        let url = try await writer.finish(at: end)
        if writer.hasSystemAudio && writer.hasMicrophone {
            // Two audio tracks play as one only in some apps, so mix them into one.
            do {
                try await MediaExport.mixAudioTracks(url)
            } catch {
                savedSeparateAudioTracks = true
                NSLog("Snaps: couldn't mix the recording's audio tracks: \(error)")
            }
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
    private let systemAudio: AudioTrack?
    private let microphone: AudioTrack?

    private let frameDuration: CMTime

    private var sessionStart: CMTime?
    private var lastVideoTime: CMTime?
    /// The last frame written. A still screen delivers no frames, so this is what is on screen until the next one.
    private var lastFrame: CMSampleBuffer?
    /// The latest frame that arrived while paused, for the picture to pick up from when recording resumes.
    private var pausedFrame: CMSampleBuffer?
    /// Paused stretches in host time; the last one is open while paused.
    private var pauses: [(start: CMTime, end: CMTime?)] = []
    private var isFinished = false

    init(url: URL, size: CGSize, frameRate: Int, systemAudio: Bool, microphone: Bool) throws {
        self.url = url
        hasSystemAudio = systemAudio
        hasMicrophone = microphone
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
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

        self.systemAudio = systemAudio ? AudioTrack(input: try Self.addAudioInput(to: writer)) : nil
        self.microphone = microphone ? AudioTrack(input: try Self.addAudioInput(to: writer)) : nil

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
        guard let adjusted = adjusted(time) else {
            guard let pause = pauses.last, time >= pause.start else { return }
            if let end = pause.end, let resumed = adjusted(end) {
                // Delivery may trail the resume click. A later video frame already written takes precedence.
                if sessionStart != nil { show(buffer, at: resumed) }
            } else {
                pausedFrame = buffer
            }
            return
        }
        if sessionStart == nil {
            writer.startSession(atSourceTime: adjusted)
            sessionStart = adjusted
        }
        show(buffer, at: adjusted)
    }

    /// Writes `frame` at `time` on the movie's timeline, if that is after the last one written.
    private func show(_ frame: CMSampleBuffer, at time: CMTime) {
        if let lastVideoTime, time <= lastVideoTime { return }
        guard videoInput.isReadyForMoreMediaData, let retimed = retimed(frame, to: time) else { return }
        if videoInput.append(retimed) {
            lastVideoTime = time
            lastFrame = frame
        }
    }

    func appendAudio(_ buffer: CMSampleBuffer, microphone: Bool) {
        guard !isFinished, writer.status == .writing,
              let track = microphone ? self.microphone : systemAudio,
              let sessionStart
        else { return }
        guard let time = track.hostTime(of: buffer) else { return }
        let duration = CMSampleBufferGetDuration(buffer)
        if pauses.isEmpty || (duration.isNumeric && time + duration <= pauses[0].start) {
            track.append(buffer, at: time, sessionStart: sessionStart)
            return
        }

        // A buffer can straddle either edge of a pause. Retain only the samples outside it.
        let count = CMSampleBufferGetNumSamples(buffer)
        guard count > 0, let format = CMSampleBufferGetFormatDescription(buffer),
              let rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate, rate > 0
        else { return }
        func frame(at boundary: CMTime) -> Int {
            Int(min(Double(count), max(0, ((boundary - time).seconds * rate).rounded(.up))))
        }
        func append(_ interval: Range<Int>, after offset: CMTime) {
            guard !interval.isEmpty else { return }
            let start = time + CMTime(value: Int64(interval.lowerBound), timescale: CMTimeScale(rate)) - offset
            if interval.count == count {
                track.append(buffer, at: start, sessionStart: sessionStart)
            } else if let samples = audioPiece(like: buffer, from: interval.lowerBound, count: interval.count, at: start) {
                track.append(samples, at: start, sessionStart: sessionStart)
            }
        }

        var first = 0
        var offset = CMTime.zero
        for pause in pauses {
            let cut = frame(at: pause.start)
            append(first..<cut, after: offset)
            if cut == count { return }
            guard let resumed = pause.end else {
                track.isBroken = true
                return
            }
            first = frame(at: resumed)
            if first > cut { track.isBroken = true }
            offset = offset + (resumed - pause.start)
        }
        append(first..<count, after: offset)
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
            // If the screen changed while paused and stands still now, no new frame comes: show the latest one.
            if let frame = self.pausedFrame, self.sessionStart != nil, self.writer.status == .writing,
               let resumed = self.adjusted(time) {
                self.show(frame, at: resumed)
            }
            self.pausedFrame = nil
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

                // A track ends with its last frame, and a still screen delivers none: repeat the last one,
                // so the picture lasts as long as the recording in every player.
                if let frame = self.lastFrame {
                    self.show(frame, at: endTime - self.frameDuration)
                }
                self.videoInput.markAsFinished()
                self.systemAudio?.input.markAsFinished()
                self.microphone?.input.markAsFinished()
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
}

/// A copy of `buffer` that starts at `time`, or `buffer` itself if it already does.
private func retimed(_ buffer: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
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

/// One audio track of a recording, kept continuous on the movie's timeline.
///
/// AVAssetWriter places an audio track by its first buffer and then strings the samples together, whatever
/// their timestamps say. So a stretch that went missing (a pause, a buffer the encoder wasn't ready for, a
/// microphone that started late or stalled) would pull everything after it earlier, out of step with the
/// picture and with the other audio track. Here holes are filled with silence and overlaps are cut, so a
/// sample always lands where its timestamp says.
private final class AudioTrack {
    let input: AVAssetWriterInput
    /// Set when samples are known to be missing, so the next buffer is placed exactly.
    var isBroken = true

    /// Where the samples written at `rate` begin on the movie's timeline, and how many there are.
    private var origin: CMTime?
    private var frames: Int64 = 0
    private var rate: Double = 0
    /// What to add to this source's timestamps to put them on the host clock, which the picture uses.
    private var clockOffset: CMTime?
    private var previousBufferEnd: CMTime?

    /// Timestamps this close to the end of the track count as continuing it. Devices' clocks wander a little
    /// against the host clock; correcting every buffer would click, so wait until it adds up, then fix it in one go.
    private static let slack = 0.02

    init(input: AVAssetWriterInput) {
        self.input = input
    }

    private var end: CMTime? {
        origin.map { $0 + CMTime(value: frames, timescale: CMTimeScale(rate)) }
    }

    /// When `buffer` was captured, on the host clock. ScreenCaptureKit stamps what it delivers with host time;
    /// should a source ever keep a clock of its own, its buffers are lined up by when they arrive instead.
    func hostTime(of buffer: CMSampleBuffer) -> CMTime? {
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard time.isNumeric else { return nil }
        let duration = CMSampleBufferGetDuration(buffer)
        if let previousBufferEnd, abs((time - previousBufferEnd).seconds) > 0.001 {
            // A missing device buffer can be shorter than the allowance for long-term clock drift.
            isBroken = true
        }
        previousBufferEnd = duration.isNumeric ? time + duration : nil
        if clockOffset == nil {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let isHostTime = (-1...10).contains((now - time).seconds)
            clockOffset = isHostTime ? .zero : now - (duration.isNumeric ? duration : .zero) - time
        }
        return clockOffset.map { time + $0 }
    }

    func append(_ buffer: CMSampleBuffer, at start: CMTime, sessionStart: CMTime) {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate >= 1, asbd.mBytesPerFrame > 0
        else { return }
        if asbd.mSampleRate != rate {
            // The first buffer, or the microphone changed format: count from here at the new rate.
            origin = end ?? sessionStart
            frames = 0
            rate = asbd.mSampleRate
        }
        let count = CMSampleBufferGetNumSamples(buffer)
        guard let end, count > 0 else { return }

        // How far the buffer starts from the end of the track: a hole if positive, an overlap if negative.
        let distance = ((start - end).seconds * rate).rounded()
        guard abs(distance) < rate * 86_400 else { return }
        var offset = Int(distance)
        if !isBroken, abs(offset) <= Int(rate * Self.slack) { offset = 0 }
        if offset > 0 {
            guard fill(offset, like: buffer) else { return }
        }
        // Samples from before the end of the track (or before the recording began) are left out.
        let skip = max(0, -offset)
        guard skip < count, let time = self.end else {
            isBroken = true
            return
        }
        let piece = skip == 0
            ? retimed(buffer, to: time)
            : audioPiece(like: buffer, from: skip, count: count - skip, at: time)
        if write(piece, frames: count - skip) {
            isBroken = false
        }
    }

    /// Appends `count` frames of silence. False if the encoder couldn't take them all.
    private func fill(_ count: Int, like buffer: CMSampleBuffer) -> Bool {
        var left = count
        while left > 0, let time = end {
            let chunk = min(left, Int(rate))
            guard write(audioPiece(like: buffer, from: nil, count: chunk, at: time), frames: chunk) else { return false }
            left -= chunk
        }
        return left == 0
    }

    private func write(_ piece: CMSampleBuffer?, frames count: Int) -> Bool {
        guard let piece, input.isReadyForMoreMediaData, input.append(piece) else {
            // Dropped: the next buffer finds the hole and fills it.
            isBroken = true
            return false
        }
        frames += Int64(count)
        return true
    }
}

/// `count` frames in `model`'s format starting at `time`: `model`'s own frames from `first` on, or silence if `first` is nil.
private func audioPiece(like model: CMSampleBuffer, from first: Int?, count: Int, at time: CMTime) -> CMSampleBuffer? {
    guard let format = CMSampleBufferGetFormatDescription(model),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
    else { return nil }
    // Interleaved audio is one buffer of whole frames; otherwise there is a buffer per channel.
    let isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    let bufferCount = isInterleaved ? 1 : Int(asbd.mChannelsPerFrame)
    let byteCount = count * Int(asbd.mBytesPerFrame)

    let list = AudioBufferList.allocate(maximumBuffers: bufferCount)
    defer { free(list.unsafeMutablePointer) }

    guard let first else {
        guard let zeros = calloc(byteCount, 1) else { return nil }
        defer { free(zeros) }
        for index in 0..<bufferCount {
            list[index] = AudioBuffer(
                mNumberChannels: isInterleaved ? asbd.mChannelsPerFrame : 1,
                mDataByteSize: UInt32(byteCount), mData: zeros
            )
        }
        return CMSampleBuffer.pcm(format, frames: count, at: time, copying: list.unsafePointer)
    }

    let source = AudioBufferList.allocate(maximumBuffers: bufferCount)
    defer { free(source.unsafeMutablePointer) }
    var retained: CMBlockBuffer?
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        model, bufferListSizeNeededOut: nil, bufferListOut: source.unsafeMutablePointer,
        bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: bufferCount),
        blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0, blockBufferOut: &retained
    ) == noErr, source.count == bufferCount else { return nil }
    let offset = first * Int(asbd.mBytesPerFrame)
    for index in 0..<bufferCount {
        guard Int(source[index].mDataByteSize) >= offset + byteCount, let data = source[index].mData else { return nil }
        list[index] = AudioBuffer(
            mNumberChannels: source[index].mNumberChannels,
            mDataByteSize: UInt32(byteCount), mData: data + offset
        )
    }
    return withExtendedLifetime(retained) {
        CMSampleBuffer.pcm(format, frames: count, at: time, copying: list.unsafePointer)
    }
}

extension CMSampleBuffer {
    /// A buffer of `frames` PCM frames in `format` starting at `time`, holding a copy of the samples in `list`.
    static func pcm(_ format: CMAudioFormatDescription, frames: Int, at time: CMTime, copying list: UnsafePointer<AudioBufferList>) -> CMSampleBuffer? {
        guard let rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate, rate >= 1 else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer
        ) == noErr, let buffer,
            CMSampleBufferSetDataBufferFromAudioBufferList(
                buffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: list
            ) == noErr
        else { return nil }
        return buffer
    }
}
