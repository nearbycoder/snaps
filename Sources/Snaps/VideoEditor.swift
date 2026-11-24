import AVKit
import AppKit
import Combine
import SwiftUI

/// Opens recordings for trimming, muting and converting between video and GIF.
@MainActor
final class VideoEditor {
    static let shared = VideoEditor()

    struct Update {
        let url: URL
        let poster: NSImage
        let duration: Double
        let source: URL?
    }

    /// Fires when a recording file is rewritten in place.
    let didUpdate = PassthroughSubject<Update, Never>()
    /// Called with recordings made from the editor (Save as GIF / Save as Video), so they get a preview.
    var onNewRecording: ((_ url: URL, _ poster: NSImage, _ info: RecordingInfo) -> Void)?

    private var windows: [VideoEditorWindowController] = []

    /// Opens `url`; a GIF is edited through `source`, the video it was made from.
    /// - Parameters:
    ///   - pointSize: the recording's size in points, which caps how wide GIFs made from it get.
    ///   - target: where the recording lives when the editor writes to it, in case it moved meanwhile.
    ///   - onClose: called when the window closes; `copied` is true if Done put the result on the clipboard.
    @discardableResult
    func open(
        _ url: URL,
        source: URL?,
        pointSize: CGSize,
        target: (() -> URL?)? = nil,
        onClose: ((_ copied: Bool) -> Void)? = nil
    ) -> Bool {
        if let existing = windows.first(where: { $0.url == url || $0.currentURL == url }) {
            if let onClose { existing.closeObservers.append(onClose) }
            existing.focus()
            return true
        }
        let video = CaptureKind(url) == .gif ? source : url
        guard let video, FileManager.default.fileExists(atPath: video.path) else {
            NSSound.beep()
            return false
        }
        let controller = VideoEditorWindowController(url: url, video: video, pointSize: pointSize, target: target)
        if let onClose { controller.closeObservers.append(onClose) }
        controller.closeObservers.append { [weak self, weak controller] _ in
            self?.windows.removeAll { $0 === controller }
        }
        windows.append(controller)
        controller.show()
        return true
    }
}

@MainActor
final class VideoEditorModel: ObservableObject {
    /// What Done writes: the video itself, or a GIF made from the source video.
    let output: CaptureKind
    @Published var duration: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var isMuted = false
    @Published var hasAudio = false
    @Published var isReady = false
    @Published var busy: String?
    @Published var toast: String?
    private var toastTask: Task<Void, Never>?

    init(output: CaptureKind) {
        self.output = output
    }

    var isTrimmed: Bool { trimStart > 0.01 || trimEnd < duration - 0.01 }
    var hasChanges: Bool { output == .gif ? isTrimmed : isTrimmed || (isMuted && hasAudio) }

    var range: CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            end: CMTime(seconds: trimEnd, preferredTimescale: 600)
        )
    }

    var rangeLabel: String {
        "\(Self.clock(trimStart)) – \(Self.clock(trimEnd))  ·  \(String(format: "%.1f", trimEnd - trimStart)) s"
    }

    private static func clock(_ seconds: Double) -> String {
        let tenths = Int((seconds * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(.snappy) { toast = message }
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.toast = nil }
        }
    }
}

@MainActor
final class VideoEditorWindowController: NSObject, NSWindowDelegate {
    let url: URL
    var closeObservers: [(Bool) -> Void] = []
    var currentURL: URL { target?() ?? lastKnownURL }
    private var lastKnownURL: URL
    private var saveObservation: AnyCancellable?

    private var gifSource: URL?
    private var video: URL { gifSource ?? currentURL }
    private let pointSize: CGSize
    private let target: (() -> URL?)?
    private let model: VideoEditorModel
    private let playerView = EditorPlayerView()
    private var window: NSWindow?
    private var previousApp: NSRunningApplication?
    private var copiedOnClose = false
    private var statusObservation: NSKeyValueObservation?
    private let settings = AppSettings.shared

    init(url: URL, video: URL, pointSize: CGSize, target: (() -> URL?)?) {
        self.url = url
        lastKnownURL = url
        gifSource = CaptureKind(url) == .gif ? video : nil
        self.pointSize = pointSize
        self.target = target
        model = VideoEditorModel(output: CaptureKind(url) == .gif ? .gif : .video)
        super.init()
        saveObservation = CaptureHistory.shared.didSave.sink { [weak self] move in
            guard let self, lastKnownURL == move.old else { return }
            lastKnownURL = move.new
        }
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        playerView.showsSharingServiceButton = false
        playerView.onCopy = { [weak self] in self?.copy() }
        load()
    }

    func show() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = url.deletingPathExtension().lastPathComponent
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // An empty toolbar makes the title bar tall enough to hold the controls beside the window buttons.
        window.toolbar = NSToolbar(identifier: "VideoEditor")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 760, height: 440)
        window.delegate = self
        window.setFrame(initialFrame(), display: false)

        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        let hosting = NSHostingView(rootView: VideoEditorView(
            model: model,
            playerView: playerView,
            titlebarHeight: titlebarHeight,
            onTrim: { [weak self] in self?.trim() },
            onResetTrim: { [weak self] in self?.resetTrim() },
            onMute: { [weak self] in self?.toggleMute() },
            onConvert: { [weak self] in self?.convert() },
            onCopy: { [weak self] in self?.copy() },
            onDone: { [weak self] in self?.done() }
        ))
        hosting.sizingOptions = []
        window.contentView = hosting
        self.window = window

        focus()
        window.makeFirstResponder(playerView)
    }

    func focus() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// Centered on the display under the cursor, showing the recording at up to its own size.
    private func initialFrame() -> NSRect {
        let visible = NSScreen.underMouse?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let chrome = NSSize(width: 0, height: 52)
        let room = NSSize(width: visible.width * 0.8, height: visible.height * 0.8 - chrome.height)
        let size = CGSize(width: max(pointSize.width, 1), height: max(pointSize.height, 1))
        let scale = min(room.width / size.width, room.height / size.height, 1)
        let width = min(max((size.width * scale).rounded(), 760), visible.width)
        let height = min(max((size.height * scale).rounded() + chrome.height, 440), visible.height)
        return NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height).integral
    }

    // MARK: Player

    private func load() {
        let item = AVPlayerItem(url: video)
        let player = AVPlayer(playerItem: item)
        player.isMuted = model.isMuted || model.output == .gif
        playerView.player = player
        model.isReady = false
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, item.status == .readyToPlay else { return }
                self.statusObservation = nil
                await self.itemReady(item)
            }
        }
    }

    private func itemReady(_ item: AVPlayerItem) async {
        let duration = (try? await item.asset.load(.duration))?.seconds ?? 0
        let audio = (try? await item.asset.loadTracks(withMediaType: .audio)) ?? []
        guard duration.isFinite, duration > 0 else { return }
        model.duration = duration
        model.trimStart = 0
        model.trimEnd = duration
        model.hasAudio = !audio.isEmpty
        model.isReady = true
    }

    private func trim() {
        guard model.isReady, model.busy == nil, playerView.canBeginTrimming else { return }
        playerView.beginTrimming { [weak self] result in
            Task { @MainActor in
                guard let self, result == .okButton, let item = self.playerView.player?.currentItem else { return }
                let start = item.reversePlaybackEndTime
                let end = item.forwardPlaybackEndTime
                self.model.trimStart = start.isValid ? max(0, start.seconds) : 0
                self.model.trimEnd = end.isValid ? min(self.model.duration, end.seconds) : self.model.duration
            }
        }
    }

    private func resetTrim() {
        guard let item = playerView.player?.currentItem else { return }
        item.reversePlaybackEndTime = .invalid
        item.forwardPlaybackEndTime = .invalid
        model.trimStart = 0
        model.trimEnd = model.duration
    }

    private func toggleMute() {
        model.isMuted.toggle()
        playerView.player?.isMuted = model.isMuted
    }

    // MARK: Actions

    private var gifMaxWidth: Int {
        min(settings.gifSize.maxWidth ?? Int.max, max(Int(pointSize.width), 2))
    }

    /// Writes the trim (and mute) into the recording. Returns false if that failed.
    private func apply() async -> Bool {
        guard model.hasChanges else { return true }
        let url = currentURL
        let temp = CaptureStorage.temporaryURL(pathExtension: model.output.pathExtension, replacing: url)
        model.busy = model.output == .gif ? "Making GIF…" : "Saving…"
        defer { model.busy = nil }
        var editedSource: URL?
        do {
            switch model.output {
            case .gif:
                let source = CaptureStorage.newRecordingSourceURL()
                editedSource = source
                try await MediaExport.exportVideo(from: video, to: source, range: model.range, includeAudio: false)
                try await MediaExport.makeGIF(
                    from: source, to: temp,
                    frameRate: settings.gifFrameRate.rawValue, maxWidth: gifMaxWidth
                )
            default:
                try await MediaExport.exportVideo(from: video, to: temp, range: model.range, includeAudio: !model.isMuted)
            }
            // A folder save can relocate this capture while the export is running.
            guard currentURL == url else { throw CocoaError(.fileWriteFileExists) }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            NSLog("Snaps: failed to save recording edits: \(error)")
            if let editedSource { try? FileManager.default.removeItem(at: editedSource) }
            try? FileManager.default.removeItem(at: temp)
            model.showToast("Couldn’t save")
            return false
        }

        let duration = model.trimEnd - model.trimStart
        let poster = model.output == .gif ? NSImage(contentsOf: url) : await VideoFrames.poster(url)
        Thumbnails.evict(url)
        gifSource = editedSource
        CaptureHistory.shared.updateRecording(at: url, duration: duration, source: editedSource)
        VideoEditor.shared.didUpdate.send(.init(url: url, poster: poster ?? NSImage(size: pointSize), duration: duration, source: editedSource))
        model.isMuted = false
        load()
        return true
    }

    private func copy() {
        guard model.busy == nil, model.isReady else { return }
        Task { @MainActor in
            guard model.busy == nil, model.isReady else { return }
            guard await apply() else { return }
            Clipboard.copy(fileAt: currentURL)
            model.showToast("Copied")
        }
    }

    private func done() {
        guard model.busy == nil, model.isReady else { return }
        Task { @MainActor in
            guard model.busy == nil, model.isReady else { return }
            let changed = model.hasChanges
            guard await apply() else { return }
            if changed, settings.copyToClipboard {
                Clipboard.copy(fileAt: currentURL)
                copiedOnClose = true
            }
            window?.close()
        }
    }

    /// Saves the current trim as a new recording in the other format: a GIF from a video, or a video from a GIF.
    private func convert() {
        guard model.busy == nil, model.isReady else { return }
        let makingGIF = model.output == .video
        model.busy = makingGIF ? "Making GIF…" : "Saving video…"
        Task { @MainActor in
            defer { model.busy = nil }
            var url = CaptureStorage.newCaptureURL(makingGIF ? .gif : .video)
            var source: URL?
            do {
                if makingGIF {
                    let copy = CaptureStorage.newRecordingSourceURL()
                    source = copy
                    if model.isTrimmed || model.hasAudio {
                        try await MediaExport.exportVideo(from: video, to: copy, range: model.range, includeAudio: false)
                    } else {
                        try FileManager.default.copyItem(at: video, to: copy)
                    }
                    try await MediaExport.makeGIF(
                        from: copy, to: url, frameRate: settings.gifFrameRate.rawValue, maxWidth: gifMaxWidth
                    )
                } else {
                    try await MediaExport.exportVideo(from: video, to: url, range: model.range, includeAudio: false)
                }
            } catch {
                if let source { try? FileManager.default.removeItem(at: source) }
                NSLog("Snaps: failed to convert recording: \(error)")
                try? FileManager.default.removeItem(at: url)
                model.showToast("Couldn’t save")
                return
            }

            let duration = model.trimEnd - model.trimStart
            let poster = makingGIF ? NSImage(contentsOf: url) : await VideoFrames.poster(url)
            if settings.saveToFolder, let saved = try? CaptureStorage.save(url, into: settings.saveFolder) {
                url = saved
            }
            if settings.copyToClipboard {
                Clipboard.copy(fileAt: url)
            }
            if settings.keepInGallery {
                CaptureHistory.shared.add(url: url, size: pointSize, duration: duration, source: source)
            }
            VideoEditor.shared.onNewRecording?(
                url,
                poster ?? NSImage(size: pointSize),
                RecordingInfo(duration: duration, source: source, pointSize: pointSize)
            )
            model.showToast(makingGIF ? "Saved as GIF" : "Saved as video")
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        let closing = window
        let othersVisible = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
        closeObservers.forEach { $0(copiedOnClose) }
        closeObservers.removeAll()
        if !othersVisible {
            previousApp?.activate()
        }
    }
}

/// AVPlayerView that answers ⌘C.
final class EditorPlayerView: AVPlayerView {
    var onCopy: (() -> Void)?

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }
}

struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorModel
    let playerView: EditorPlayerView
    let titlebarHeight: CGFloat
    let onTrim: () -> Void
    let onResetTrim: () -> Void
    let onMute: () -> Void
    let onConvert: () -> Void
    let onCopy: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.leading, 84) // clear of the window buttons
                .padding(.trailing, 14)
                .frame(height: titlebarHeight)

            ZStack(alignment: .bottom) {
                PlayerHost(view: playerView)
                    .background(.black)

                if let busy = model.busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
                } else if let toast = model.toast {
                    Label(toast, systemImage: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 80)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
        .background {
            VisualEffectBackground(material: .underPageBackground).ignoresSafeArea()
        }
        .animation(.easeOut(duration: Motion.quick), value: model.busy)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: onTrim) {
                Label("Trim", systemImage: "scissors")
            }
            .buttonStyle(.glass)
            .keyboardShortcut("t", modifiers: [])
            .help("Drag the yellow handles to trim (T)")

            if model.isTrimmed {
                HStack(spacing: 4) {
                    Text(model.rangeLabel)
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button(action: onResetTrim) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Undo the trim")
                }
                .transition(.opacity)
            }

            if model.output == .video && model.hasAudio {
                GlassToggleButton(
                    isOn: Binding(get: { !model.isMuted }, set: { _ in onMute() }),
                    on: "speaker.wave.2.fill",
                    off: "speaker.slash.fill",
                    help: model.isMuted ? "Sound will be removed" : "Remove the sound",
                    size: 30
                )
            }

            Spacer(minLength: 8)

            Button(action: onConvert) {
                Label(model.output == .video ? "Save as GIF" : "Save as Video",
                      systemImage: model.output == .video ? RecordingFormat.gif.symbol : "film")
            }
            .buttonStyle(.glass)
            .help(model.output == .video ? "Make a GIF from this (trimmed) recording" : "Save this (trimmed) GIF as an MP4")

            Button(action: onCopy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.glass)
            .help("Copy the recording (⌘C)")

            Button(action: onDone) {
                Text("Done").frame(minWidth: 40)
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Save the changes and close (⌘↩)")
        }
        .controlSize(.large)
        .disabled(!model.isReady || model.busy != nil)
        .animation(.easeInOut(duration: Motion.quick), value: model.isTrimmed)
    }
}

struct PlayerHost: NSViewRepresentable {
    let view: AVPlayerView

    func makeNSView(context: Context) -> AVPlayerView { view }
    func updateNSView(_ view: AVPlayerView, context: Context) {}
}
