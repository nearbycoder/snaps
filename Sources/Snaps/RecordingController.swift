import AVFoundation
import AppKit
import SwiftUI

/// Runs a recording from picking what to record to the finished preview.
@MainActor
final class RecordingController {
    enum Phase {
        case idle, picking, countdown, recording, finishing
    }

    /// Called when the phase or the elapsed time changes, for the menu bar item.
    var onStatusChange: ((RecordingStatus) -> Void)?

    private(set) var phase: Phase = .idle {
        didSet { publishStatus() }
    }

    private let settings = AppSettings.shared
    private let previews: PreviewManager
    private let recorder = ScreenRecorder()
    private let hudModel = RecordingHUDModel()
    private var selection: RecordingSelection?
    private var options: RecordingOptions?
    private var pointSize: CGSize = .zero

    private var hud: GlassPanel?
    private var outline: NSWindow?
    private var countdown: CountdownController?
    private var ticker: Timer?
    /// Recorded time before the current stretch, and when the current stretch began.
    private var banked: TimeInterval = 0
    private var stretchStart: Date?

    init(previews: PreviewManager) {
        self.previews = previews
        recorder.onInterrupted = { [weak self] error in
            NSLog("Snaps: recording stopped by the system: \(error)")
            self?.stop()
        }
    }

    var isActive: Bool { phase != .idle }

    /// The shortcut and menu bar entry point: starts a recording, or stops the one in progress.
    /// - Parameter returnTo: the app to hand focus back to after picking, when Snaps itself is frontmost (e.g. from the popover).
    func toggle(_ format: RecordingFormat, returnTo: NSRunningApplication? = nil) {
        switch phase {
        case .idle: start(format, returnTo: returnTo)
        case .countdown: countdown?.skip()
        case .recording: stop()
        case .picking, .finishing: break
        }
    }

    func start(_ format: RecordingFormat, returnTo: NSRunningApplication? = nil) {
        guard phase == .idle else { return }
        guard ScreenPermission.isGranted else {
            PermissionGuide.shared.start()
            return
        }
        phase = .picking
        Task { @MainActor in
            guard let selection = await RecordingPicker.pick(format: format, returnTo: returnTo) else {
                phase = .idle
                return
            }
            self.selection = selection
            pointSize = selection.frame.size
            let options = await makeOptions(for: selection.format)
            self.options = options
            await begin(countdown: settings.recordCountdown)
        }
    }

    // MARK: Recording

    private func makeOptions(for format: RecordingFormat) async -> RecordingOptions {
        var microphone = format == .video && settings.recordMicrophone
        if microphone {
            microphone = await Self.microphoneAllowed()
        }
        return RecordingOptions(
            frameRate: format == .gif ? settings.gifFrameRate.rawValue : settings.videoFrameRate.rawValue,
            showsCursor: settings.recordShowsCursor,
            showsClicks: settings.recordHighlightsClicks,
            systemAudio: format == .video && settings.recordSystemAudio,
            microphone: microphone,
            maxWidth: format == .gif ? settings.gifSize.maxWidth : nil,
            pointScaleOnly: format == .gif
        )
    }

    private func begin(countdown useCountdown: Bool) async {
        guard let selection, let options else { return finishCleanup() }
        showOutline(for: selection)

        if useCountdown {
            phase = .countdown
            let countdown = CountdownController(frame: selection.frame, screen: selection.screen)
            self.countdown = countdown
            let proceed = await countdown.run()
            self.countdown = nil
            guard proceed else { return finishCleanup() }
        }

        // Stays in .countdown until the stream is running, so a stop can't arrive before there's anything to stop.
        phase = .countdown
        let url = selection.format == .video ? CaptureStorage.newCaptureURL(.video) : CaptureStorage.newRecordingSourceURL()
        do {
            try await recorder.start(selection.target, options: options, to: url)
        } catch {
            finishCleanup()
            Self.showError("Couldn’t start recording", error)
            return
        }
        banked = 0
        stretchStart = Date()
        hudModel.state = .recording
        hudModel.isPaused = false
        hudModel.elapsed = 0
        phase = .recording
        showHUD(for: selection)
        startTicker()
    }

    func stop() {
        guard phase == .recording, let selection else { return }
        phase = .finishing
        stopTicker()
        hudModel.state = selection.format == .gif ? .making("Making GIF…") : .making("Saving…")
        publishStatus()

        Task { @MainActor in
            defer { finishCleanup() }
            do {
                let recorded = try await recorder.stop()
                try await deliver(recorded, format: selection.format)
            } catch {
                Self.showError("Couldn’t save the recording", error)
            }
        }
    }

    func togglePause() {
        guard phase == .recording else { return }
        if hudModel.isPaused {
            recorder.resume()
            stretchStart = Date()
            hudModel.isPaused = false
        } else {
            recorder.pause()
            banked += stretchStart.map { Date().timeIntervalSince($0) } ?? 0
            stretchStart = nil
            hudModel.isPaused = true
        }
        hudModel.elapsed = elapsed
        publishStatus()
    }

    /// Throws away what's been recorded and starts over on the same selection.
    func restart() {
        guard phase == .recording else { return }
        // Leave .recording right away, so a stop or discard can't race the cancel below.
        phase = .countdown
        stopTicker()
        hideHUD()
        Task { @MainActor in
            await recorder.cancel()
            await begin(countdown: settings.recordCountdown)
        }
    }

    func discard() {
        guard phase == .recording || phase == .countdown else { return }
        if phase == .countdown {
            countdown?.cancel()
            return
        }
        phase = .finishing
        stopTicker()
        Task { @MainActor in
            await recorder.cancel()
            finishCleanup()
        }
    }

    // MARK: Delivering

    private func deliver(_ recorded: URL, format: RecordingFormat) async throws {
        var url: URL
        var source: URL?
        let poster: NSImage?
        switch format {
        case .video:
            url = recorded
            poster = await VideoFrames.poster(recorded)
        case .gif:
            url = CaptureStorage.newCaptureURL(.gif)
            source = recorded
            // The source was already recorded at the GIF's size and frame rate.
            try await MediaExport.makeGIF(from: recorded, to: url, frameRate: settings.gifFrameRate.rawValue, maxWidth: nil)
            poster = NSImage(contentsOf: url)
        }
        let duration = await VideoFrames.info(recorded)?.duration ?? elapsed

        if settings.saveToFolder {
            do {
                url = try CaptureStorage.save(url, into: settings.saveFolder)
            } catch {
                NSLog("Snaps: failed to save recording: \(error)")
            }
        }
        if settings.copyToClipboard {
            Clipboard.copy(fileAt: url)
        }
        if settings.keepInGallery {
            CaptureHistory.shared.add(url: url, size: pointSize, duration: duration, source: source)
        }
        if settings.showPreview {
            let image = poster ?? NSImage(size: pointSize)
            previews.show(image: image, fileURL: url, recording: RecordingInfo(duration: duration, source: source, pointSize: pointSize))
        }
    }

    // MARK: Chrome

    private var elapsed: TimeInterval {
        banked + (stretchStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func startTicker() {
        stopTicker()
        publishStatus()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hudModel.elapsed = self.elapsed
                self.publishStatus()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func publishStatus() {
        let status: RecordingStatus
        switch phase {
        case .idle, .picking: status = .idle
        case .countdown: status = .countdown
        case .recording: status = .recording(clock: elapsed.recordingClock, paused: hudModel.isPaused)
        case .finishing: status = .finishing
        }
        onStatusChange?(status)
    }

    private func showOutline(for selection: RecordingSelection) {
        hideOutline()
        guard selection.isArea else { return }
        let window = NSWindow(
            contentRect: selection.frame.insetBy(dx: -4, dy: -4),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.contentView = OutlineView()
        window.orderFrontRegardless()
        outline = window
    }

    private func hideOutline() {
        outline?.orderOut(nil)
        outline?.close()
        outline = nil
    }

    private func showHUD(for selection: RecordingSelection) {
        hideHUD()
        let view = RecordingHUDView(
            model: hudModel,
            format: selection.format,
            onPause: { [weak self] in self?.togglePause() },
            onRestart: { [weak self] in self?.restart() },
            onStop: { [weak self] in self?.stop() },
            onDiscard: { [weak self] in self?.discard() }
        )
        let size = NSHostingView(rootView: view).fittingSize
        let panel = GlassPanel(contentSize: size)
        panel.allowsKeyFocus = false
        panel.sharingType = .none
        panel.setContent(view, cornerRadius: size.height / 2)
        panel.setFrame(hudFrame(size: size, for: selection), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.async { panel.invalidateShadow() }
        hud = panel
    }

    private func hideHUD() {
        guard let hud else { return }
        self.hud = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            hud.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                hud.orderOut(nil)
                hud.close()
            }
        })
    }

    /// Under an area if there's room, else above it, else at the bottom of the display.
    private func hudFrame(size: CGSize, for selection: RecordingSelection) -> CGRect {
        let visible = selection.screen.visibleFrame
        let gap: CGFloat = 14
        var origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 24)
        if selection.isArea {
            let rect = selection.frame
            origin.x = rect.midX - size.width / 2
            if rect.minY - gap - size.height >= visible.minY + 8 {
                origin.y = rect.minY - gap - size.height
            } else if rect.maxY + gap + size.height <= visible.maxY - 8 {
                origin.y = rect.maxY + gap
            }
        }
        origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
        return CGRect(origin: origin, size: size).integral
    }

    private func finishCleanup() {
        stopTicker()
        hideHUD()
        hideOutline()
        countdown?.cancel()
        countdown = nil
        selection = nil
        options = nil
        phase = .idle
    }

    // MARK: Permissions and errors

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            let alert = NSAlert()
            alert.messageText = "Snaps can’t use the microphone"
            alert.informativeText = "This recording will be made without it. To record your voice, turn on Snaps in System Settings → Privacy & Security → Microphone."
            alert.addButton(withTitle: "Record Without")
            alert.addButton(withTitle: "Open System Settings")
            NSApp.activate()
            if alert.runModal() == .alertSecondButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            return false
        }
    }

    private static func showError(_ title: String, _ error: Error) {
        NSLog("Snaps: \(title): \(error)")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}

/// What the menu bar item shows.
enum RecordingStatus: Equatable {
    case idle
    case countdown
    case recording(clock: String, paused: Bool)
    case finishing
}

extension TimeInterval {
    /// 0:07, 1:05, 1:02:03.
    var recordingClock: String {
        let total = Int(self)
        let hours = total / 3600, minutes = (total / 60) % 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Controls

@MainActor
final class RecordingHUDModel: ObservableObject {
    enum State: Equatable {
        case recording
        case making(String)
    }

    @Published var state: State = .recording
    @Published var isPaused = false
    @Published var elapsed: TimeInterval = 0
}

struct RecordingHUDView: View {
    @ObservedObject var model: RecordingHUDModel
    let format: RecordingFormat
    let onPause: () -> Void
    let onRestart: () -> Void
    let onStop: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch model.state {
            case .recording:
                recordingControls
            case let .making(label):
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 6)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 276, height: 46)
    }

    @ViewBuilder
    private var recordingControls: some View {
        TimelineView(.periodic(from: .now, by: 0.6)) { context in
            let blink = Int(context.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
            Circle()
                .fill(model.isPaused ? Color.orange : Color.red)
                .frame(width: 9, height: 9)
                .opacity(model.isPaused || blink ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.3), value: blink)
        }
        .frame(width: 9, height: 9)
        .padding(.leading, 6)

        Text(model.elapsed.recordingClock)
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .frame(minWidth: 44, alignment: .leading)
        if format == .gif {
            Text("GIF")
                .font(.system(size: 9.5, weight: .heavy))
                .foregroundStyle(.secondary)
        }

        Spacer(minLength: 0)

        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                GlassIconButton(
                    symbol: model.isPaused ? "play.fill" : "pause.fill",
                    help: model.isPaused ? "Resume" : "Pause",
                    size: 30,
                    action: onPause
                )
                GlassIconButton(symbol: "arrow.counterclockwise", help: "Start over", size: 30, action: onRestart)
                GlassIconButton(symbol: "trash", help: "Discard", size: 30, action: onDiscard)
            }
        }

        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.red).interactive(), in: .circle)
        .help("Stop and save")
    }
}

/// A thin frame just outside the recorded area, so it never ends up in the recording.
private final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2.5, dy: 2.5)
        let shadow = NSBezierPath(rect: rect)
        shadow.lineWidth = 3
        NSColor.black.withAlphaComponent(0.25).setStroke()
        shadow.stroke()
        let line = NSBezierPath(rect: rect)
        line.lineWidth = 1.5
        line.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        line.stroke()
    }
}

// MARK: - Countdown

/// 3, 2, 1 over the area about to be recorded. Click it to start right away.
@MainActor
final class CountdownController {
    private let model = CountdownModel()
    private let panel: GlassPanel
    private var continuation: CheckedContinuation<Bool, Never>?
    private var task: Task<Void, Never>?

    init(frame: CGRect, screen: NSScreen) {
        let size = CGSize(width: 132, height: 132)
        panel = GlassPanel(contentSize: size)
        panel.allowsKeyFocus = false
        panel.sharingType = .none
        panel.level = .screenSaver
        let center = CGPoint(x: frame.midX, y: frame.midY)
        panel.setFrame(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height).integral, display: false)
        panel.setContent(CountdownView(model: model, onSkip: { [weak self] in self?.skip() }, onCancel: { [weak self] in self?.cancel() }), cornerRadius: size.width / 2)
    }

    /// Returns true when it's time to record, false if cancelled.
    func run() async -> Bool {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }, completionHandler: nil)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            task = Task { @MainActor [weak self] in
                for value in stride(from: 3, through: 1, by: -1) {
                    guard let self, !Task.isCancelled else { return }
                    withAnimation(.snappy(duration: 0.25)) { self.model.value = value }
                    try? await Task.sleep(for: .seconds(1))
                }
                self?.finish(true)
            }
        }
    }

    func skip() { finish(true) }
    func cancel() { finish(false) }

    private func finish(_ proceed: Bool) {
        task?.cancel()
        task = nil
        guard let continuation else { return }
        self.continuation = nil
        panel.orderOut(nil)
        panel.close()
        continuation.resume(returning: proceed)
    }
}

@MainActor
final class CountdownModel: ObservableObject {
    @Published var value = 3
}

struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    let onSkip: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Button(action: onSkip) {
                Text("\(model.value)")
                    .font(.system(size: 60, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(countsDown: true))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Click to start now")

            VStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
            }
        }
    }
}

// MARK: - Recording info shared with previews

/// What a preview knows about a recording.
struct RecordingInfo {
    var duration: Double
    /// The video a GIF was made from.
    var source: URL?
    var pointSize: CGSize
}
