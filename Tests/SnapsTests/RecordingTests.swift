import AVFoundation
import CoreMedia
import XCTest
@testable import Snaps

/// Runs made-up screen, system audio and microphone streams through the recording pipeline and checks the
/// file that comes out: that sound stays in step with the picture, that nothing goes missing, and that
/// the two audio sources come through together.
///
/// Every signal is tied to capture time: each source plays a steady tone with a short, higher burst at every
/// whole second, so where a burst lands in the file says how far that source has slipped.
final class RecordingTests: XCTestCase {
    // MARK: The recorder

    func testOddlySizedMicrophoneBuffersAreAllKept() async throws {
        // 512 frames at 48 kHz is 10.666… ms, which no timestamp holds exactly. That used to lose every third buffer.
        let recording = try await capture(seconds: 3, microphone: .microphone(frames: 512))
        let microphone = try await recording.audio(1)
        XCTAssertEqual(microphone.duration, 3, accuracy: 0.05)
        XCTAssertEqual(microphone.dropouts(of: Tone.microphone), 0)
        XCTAssertLessThan(microphone.worstSlip(of: Tone.microphone, at: [1, 2]), 0.002)
    }

    func testWobblingTimestampsDoNotLoseSystemAudio() async throws {
        // ScreenCaptureKit's system audio timestamps wobble by a few dozen nanoseconds around a steady beat.
        let recording = try await capture(seconds: 3, system: .system(jitter: 0.000_000_05), microphone: nil)
        let system = try await recording.audio(0)
        XCTAssertEqual(system.duration, 3, accuracy: 0.05)
        XCTAssertEqual(system.dropouts(of: Tone.system), 0)
        XCTAssertLessThan(system.worstSlip(of: Tone.system, at: [1, 2]), 0.002)
    }

    func testSoundStaysInStepAfterPauses() async throws {
        let pauses = [1.31...1.97, 2.6...3.05]
        let recording = try await capture(seconds: 5, microphone: .microphone(frames: 512), pauses: pauses)
        let duration = try await recording.duration
        XCTAssertEqual(duration, 5 - 0.66 - 0.45, accuracy: 0.05)
        // Seconds 1 and 4 of capture time fall outside the pauses; they land 0 and 1.11 s earlier in the movie.
        let system = try await recording.audio(0), microphone = try await recording.audio(1)
        XCTAssertLessThan(system.worstSlip(of: Tone.system, at: [1, 4 - 1.11]), 0.002)
        XCTAssertLessThan(microphone.worstSlip(of: Tone.microphone, at: [1, 4 - 1.11]), 0.002)
    }

    func testPauseRemovesSamplesFromInsideABuffer() async throws {
        // The 6 kHz marker at 1 s is inside the pause, but the buffer containing it starts before the pause.
        let recording = try await capture(seconds: 2.5, microphone: nil, pauses: [0.9995...1.31])
        let system = try await recording.audio(0)
        XCTAssertLessThan(system.level(of: Tone.system.burst, from: 0.9995, to: 1.0045), 0.01)
        XCTAssertLessThan(system.worstSlip(of: Tone.system, at: [2 - 0.3105]), 0.002)
    }

    func testMicrophoneThatStartsLateAndStallsStaysInStep() async throws {
        // Nothing from the microphone until 0.6 s, and nothing between 1.4 s and 2.5 s.
        let recording = try await capture(seconds: 4, microphone: .microphone(frames: 480, silentDuring: [0...0.6, 1.4...2.5]))
        let microphone = try await recording.audio(1)
        XCTAssertEqual(microphone.duration, 4, accuracy: 0.05)
        XCTAssertLessThan(microphone.worstSlip(of: Tone.microphone, at: [1, 3]), 0.002)
        XCTAssertLessThan(microphone.level(of: Tone.microphone.frequency, from: 1.6, to: 2.3), 0.001, "the stall should be silence")
    }

    func testMicrophoneOnItsOwnClockIsLinedUpByArrival() async throws {
        let recording = try await capture(seconds: 3, microphone: .microphone(frames: 512, clockShift: 5000))
        let microphone = try await recording.audio(1)
        XCTAssertEqual(microphone.duration, 3, accuracy: 0.1)
        // A source with an independent clock is anchored to the arrival of its first complete buffer.
        let offset = try XCTUnwrap(recording.microphoneArrivalOffset)
        XCTAssertLessThan(microphone.worstSlip(of: Tone.microphone, at: [1 + offset, 2 + offset]), 0.02)
    }

    func testStillScreenKeepsItsLength() async throws {
        // A screen that doesn't change delivers one frame. The picture still has to last as long as the recording.
        let recording = try await capture(seconds: 2, framesUntil: 0.01, system: nil, microphone: nil)
        let frames = try await recording.videoFrameTimes()
        let duration = try await recording.duration
        XCTAssertEqual(duration, 2, accuracy: 0.05)
        XCTAssertGreaterThan(frames.last ?? 0, 1.9, "the last frame is repeated at the end")
    }

    // MARK: Mixing

    func testMixKeepsBothSourcesInStepOnOneTrack() async throws {
        let recording = try await capture(seconds: 3, microphone: .microphone(frames: 512), pauses: [1.3...1.8])
        try await MediaExport.mixAudioTracks(recording.url)
        let mixed = Recording(url: recording.url)
        let tracks = try await mixed.asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        let audio = try await mixed.audio(0)
        XCTAssertEqual(audio.duration, 2.5, accuracy: 0.05)
        XCTAssertGreaterThan(audio.level(of: Tone.system.frequency, from: 0.2, to: 2.3), 0.1)
        XCTAssertGreaterThan(audio.level(of: Tone.microphone.frequency, from: 0.2, to: 2.3), 0.1)
        XCTAssertLessThan(audio.worstSlip(of: Tone.system, at: [1, 1.5]), 0.002)
        XCTAssertLessThan(audio.worstSlip(of: Tone.microphone, at: [1, 1.5]), 0.002)
    }

    func testMixOfTwoLoudSourcesStaysUnderFullScale() async throws {
        let recording = try await capture(
            seconds: 2,
            system: .system(level: 0.9, burstLevel: 0),
            microphone: .microphone(frames: 512, level: 0.9, burstLevel: 0, channels: 2)
        )
        try await MediaExport.mixAudioTracks(recording.url)
        let audio = try await Recording(url: recording.url).audio(0)
        XCTAssertLessThanOrEqual(audio.peak, 1)
        XCTAssertGreaterThan(audio.peak, 0.7, "limited, not just turned down")
        // Clipping would put energy at the sum and difference of the two tones.
        let tone = audio.level(of: Tone.system.frequency, from: 0.2, to: 1.8)
        for product in [560.0, 1440, 120, 1880] {
            XCTAssertLessThan(audio.level(of: product, from: 0.2, to: 1.8), tone * 0.01)
        }
    }

    // MARK: The limiter

    func testLimiterLeavesAudioThatFitsUntouched() {
        let limiter = PeakLimiter(rate: 48_000, channels: 2)
        let input = (0..<19_200).map { Float(0.8 * sin(Double($0 / 2) * 0.05)) }
        let output = limiter.process(input) + limiter.process([Float](repeating: 0, count: 480))
        XCTAssertEqual(output, input)
    }

    func testLimiterHoldsPeaksUnderTheCeilingWithoutShiftingAnything() {
        let limiter = PeakLimiter(rate: 48_000, channels: 2)
        var input = [Float](repeating: 0.1, count: 19_200)
        input[9_000] = 1.9
        input[9_001] = -1.7
        let output = limiter.process(input) + limiter.process([Float](repeating: 0, count: 480))
        XCTAssertEqual(output.count, input.count)
        XCTAssertLessThanOrEqual(output.map(abs).max() ?? 0, 0.89 + 1e-6)
        XCTAssertEqual(output.firstIndex { abs($0) > 0.5 }, 9_000, "the peak comes out where it went in")
        XCTAssertEqual(output[100], 0.1, "nothing changes far ahead of the peak")
    }
}

// MARK: - Made-up sources

private struct Tone {
    var frequency: Double
    var burst: Double

    static let system = Tone(frequency: 440, burst: 6000)
    static let microphone = Tone(frequency: 1000, burst: 3000)
}

/// A stream of PCM buffers the way ScreenCaptureKit delivers them.
private struct Source {
    var tone: Tone
    var rate = 48_000.0
    var channels = 2
    var frames = 960
    /// System audio comes as 32-bit float, a buffer per channel; microphones as whatever the device has.
    var isFloat = true
    var level = 0.25
    var burstLevel = 0.25
    /// Capture time of the first sample.
    var start = 0.017
    var jitter = 0.0
    var clockShift = 0.0
    var silentDuring: [ClosedRange<Double>] = []

    static func system(level: Double = 0.25, burstLevel: Double = 0.25, jitter: Double = 0) -> Source {
        Source(tone: .system, level: level, burstLevel: burstLevel, jitter: jitter)
    }

    /// 16-bit and mono, like a USB microphone.
    static func microphone(
        frames: Int, level: Double = 0.25, burstLevel: Double = 0.25, channels: Int = 1,
        clockShift: Double = 0, silentDuring: [ClosedRange<Double>] = []
    ) -> Source {
        Source(
            tone: .microphone, channels: channels, frames: frames, isFloat: false, level: level, burstLevel: burstLevel,
            start: -0.011, clockShift: clockShift, silentDuring: silentDuring
        )
    }

    var format: AVAudioFormat {
        AVAudioFormat(commonFormat: isFloat ? .pcmFormatFloat32 : .pcmFormatInt16, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: !isFloat)!
    }

    private func value(at time: Double) -> Double {
        var value = level * sin(2 * .pi * tone.frequency * time)
        let sinceSecond = time - time.rounded(.down)
        if time >= 0.999, sinceSecond < 0.005 { value += burstLevel * sin(2 * .pi * tone.burst * sinceSecond) }
        return value
    }

    /// The buffer whose first sample is number `first`, stamped against `base` on the host clock.
    func buffer(from first: Int, base: CMTime) -> CMSampleBuffer {
        let format = format
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            let sample = value(at: start + Double(first + frame) / rate)
            for channel in 0..<channels {
                if isFloat {
                    pcm.floatChannelData![channel][frame] = Float(sample)
                } else {
                    pcm.int16ChannelData![0][frame * channels + channel] = Int16(sample * 32767)
                }
            }
        }
        let stamp = start + Double(first) / rate + clockShift + ((first / frames).isMultiple(of: 2) ? jitter : -jitter)
        let time = base + CMTime(value: Int64((stamp * 1e9).rounded()), timescale: 1_000_000_000)
        return CMSampleBuffer.pcm(format.formatDescription, frames: frames, at: time, copying: pcm.audioBufferList)!
    }
}

private func videoFrame(at time: CMTime) -> CMSampleBuffer {
    var pixels: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixels)
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels!, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var buffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels!, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &buffer)
    return buffer!
}

/// Feeds the streams to a `RecordingWriter` in real time, each buffer a little after it was "captured",
/// and returns the finished file. Frames stop coming after `framesUntil`, as they do on a still screen.
private extension RecordingTests {
    func capture(
        seconds: Double,
        framesUntil: Double = .infinity,
        system: Source? = .system(),
        microphone: Source?,
        pauses: [ClosedRange<Double>] = []
    ) async throws -> Recording {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SnapsTests-\(UUID().uuidString).mp4")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(url: url, size: CGSize(width: 320, height: 180), frameRate: 30, systemAudio: system != nil, microphone: microphone != nil)
        let base = CMClockGetTime(CMClockGetHostTimeClock())
        func hostTime(_ seconds: Double) -> CMTime { base + CMTime(seconds: seconds, preferredTimescale: 1_000_000_000) }

        // What happens when, in capture time.
        var events: [(due: Double, run: () -> Void)] = []
        var microphoneArrivalOffset: Double?
        for frame in 0..<Int(min(seconds, framesUntil) * 30) + 1 where Double(frame) / 30 < seconds {
            let time = Double(frame) / 30
            events.append((time + 0.005, { writer.queue.sync { writer.appendVideo(videoFrame(at: hostTime(time))) } }))
        }
        for (source, isMicrophone) in [(system, false), (microphone, true)] {
            guard let source else { continue }
            let length = Double(source.frames) / source.rate
            for index in 0..<Int((seconds - source.start) / length) {
                let time = source.start + Double(index) * length
                if source.silentDuring.contains(where: { $0.contains(time) }) { continue }
                events.append((time + length + 0.03, {
                    let buffer = source.buffer(from: index * source.frames, base: base)
                    writer.queue.sync {
                        if isMicrophone, microphoneArrivalOffset == nil {
                            let arrival = CMClockGetTime(CMClockGetHostTimeClock()) - base
                            microphoneArrivalOffset = arrival.seconds - time - length
                        }
                        writer.appendAudio(buffer, microphone: isMicrophone)
                    }
                }))
            }
        }
        for pause in pauses {
            events.append((pause.lowerBound, { writer.pause(at: hostTime(pause.lowerBound)) }))
            events.append((pause.upperBound, { writer.resume(at: hostTime(pause.upperBound)) }))
        }

        let began = Date()
        for event in events.sorted(by: { $0.due < $1.due }) {
            let wait = event.due - Date().timeIntervalSince(began)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            event.run()
        }
        _ = try await writer.finish(at: hostTime(seconds))
        return Recording(url: url, microphoneArrivalOffset: microphoneArrivalOffset)
    }
}

// MARK: - Reading the result

private struct Recording {
    let url: URL
    var microphoneArrivalOffset: Double? = nil
    var asset: AVURLAsset { AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]) }

    var duration: Double {
        get async throws { try await asset.load(.duration).seconds }
    }

    /// The audio track at `index`, decoded.
    func audio(_ index: Int) async throws -> Audio {
        let asset = asset
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.dropFirst(index).first, "missing audio track \(index)")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let data = CMSampleBufferGetDataBuffer(buffer) {
            var chunk = [Float](repeating: 0, count: CMBlockBufferGetDataLength(data) / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            samples += chunk
        }
        // Left channel for measuring; both for the peak.
        return Audio(samples: stride(from: 0, to: samples.count, by: 2).map { samples[$0] }, peak: samples.map(abs).max() ?? 0)
    }

    /// When each stored video frame starts.
    func videoFrameTimes() async throws -> [Double] {
        let asset = asset
        let reader = try AVAssetReader(asset: asset)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var times: [Double] = []
        while let buffer = output.copyNextSampleBuffer() {
            times.append(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
        }
        return times.sorted()
    }
}

/// One channel of decoded audio at 48 kHz, starting at the beginning of the movie.
private struct Audio {
    let samples: [Float]
    /// The largest sample in any channel.
    let peak: Float
    private let rate = 48_000.0

    var duration: Double { Double(samples.count) / rate }

    /// How loud `frequency` is between two times: 1 for a full-scale sine.
    func level(of frequency: Double, from: Double, to: Double) -> Double {
        level(of: frequency, start: Int(from * rate), count: Int((to - from) * rate))
    }

    private func level(of frequency: Double, start: Int, count: Int) -> Double {
        guard start >= 0, count > 0, start + count <= samples.count else { return 0 }
        // Goertzel's algorithm: one bin of a Fourier transform.
        let coefficient = 2 * cos(2 * .pi * frequency / rate)
        var previous = 0.0, beforeThat = 0.0
        for index in start..<start + count {
            let current = Double(samples[index]) + coefficient * previous - beforeThat
            beforeThat = previous
            previous = current
        }
        let power = previous * previous + beforeThat * beforeThat - coefficient * previous * beforeThat
        return 2 * max(power, 0).squareRoot() / Double(count)
    }

    /// How far the 5 ms bursts expected at `times` (in movie time) are from where they should be, at worst.
    func worstSlip(of tone: Tone, at times: [Double]) -> Double {
        times.map { expected in
            // The burst's center, by the weight of its energy in 2 ms windows around where it should be.
            var weight = 0.0, sum = 0.0, top = 0.0
            var windows: [(time: Double, level: Double)] = []
            for start in stride(from: Int((expected - 0.15) * rate), to: Int((expected + 0.15) * rate), by: 12) {
                let level = level(of: tone.burst, start: start, count: 96)
                windows.append(((Double(start) + 48) / rate, level))
                top = max(top, level)
            }
            guard top > 0.01 else { return Double.infinity }
            for window in windows where window.level > top / 2 {
                weight += window.level
                sum += window.level * window.time
            }
            return abs(sum / weight - (expected + 0.0025))
        }.max() ?? .infinity
    }

    /// How many times the steady tone goes missing, away from the edges.
    func dropouts(of tone: Tone) -> Int {
        let levels = stride(from: Int(0.3 * rate), to: samples.count - Int(0.3 * rate), by: 48).map {
            level(of: tone.frequency, start: $0, count: 240)
        }
        guard !levels.isEmpty else { return 1 }
        let typical = levels.sorted()[levels.count / 2]
        var count = 0, isOut = false
        for level in levels {
            if level < typical / 2, !isOut { count += 1 }
            isOut = level < typical / 2
        }
        return count
    }
}
