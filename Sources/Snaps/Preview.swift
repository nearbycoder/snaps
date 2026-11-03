import AppKit
import Combine
import SwiftUI

/// Stacks floating previews in the configured corner of whichever display the cursor is on.
@MainActor
final class PreviewManager {
    private var items: [PreviewController] = [] // oldest first
    private var screen: NSScreen?
    private var isHidden = false
    private let maxVisible = 4
    private let margin: CGFloat = 18
    private let spacing: CGFloat = 12

    private lazy var follower = ScreenFollower { [weak self] screen in
        self?.follow(to: screen)
    }

    /// Called with a preview's file once the preview is gone.
    var onRelease: ((URL) -> Void)?
    /// Files opened in or dropped onto another app, which may still be reading them.
    private var handedOut: Set<URL> = []
    /// Shown while previews were hidden (mid-capture); they appear when previews come back.
    private var pending: [PreviewController] = []

    @discardableResult
    func show(image: NSImage, fileURL: URL, recording: RecordingInfo? = nil) -> PreviewController {
        screen = NSScreen.underMouse
        follower.start(on: screen)

        let controller = PreviewController(image: image, fileURL: fileURL, recording: recording)
        controller.onHandOut = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.handedOut.insert(controller.model.fileURL)
        }
        controller.onDismiss = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.items.removeAll { $0 === controller }
            if self.items.isEmpty { self.follower.stop() }
            self.layout(animated: true)
            self.onRelease?(controller.model.fileURL)
        }
        items.append(controller)

        while items.count > maxVisible {
            let oldest = items.removeFirst()
            oldest.onDismiss = nil
            oldest.dismiss()
            onRelease?(oldest.model.fileURL)
        }
        layout(animated: true, presenting: controller)
        return controller
    }

    func wasHandedOut(_ url: URL) -> Bool {
        handedOut.contains(url)
    }

    func isShowing(_ url: URL) -> Bool {
        items.contains { $0.model.fileURL == url }
    }

    func setHidden(_ hidden: Bool) {
        isHidden = hidden
        let fresh = hidden ? [] : pending
        if !hidden { pending = [] }
        for item in items where !fresh.contains(where: { $0 === item }) {
            item.setHidden(hidden)
        }
        for item in fresh where items.contains(where: { $0 === item }) {
            layout(animated: false, presenting: item)
        }
    }

    private func follow(to newScreen: NSScreen) {
        guard !items.isEmpty else { return }
        screen = newScreen
        layout(animated: true, transferring: true)
    }

    func layout(animated: Bool, presenting newcomer: PreviewController? = nil, transferring: Bool = false) {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let corner = AppSettings.shared.corner

        // Newest sits in the corner; older ones stack away from it.
        var offset: CGFloat = 0
        for controller in items.reversed() {
            let size = controller.size
            let x = corner.isLeft ? visible.minX + margin : visible.maxX - margin - size.width
            let y = corner.isTop
                ? visible.maxY - margin - offset - size.height
                : visible.minY + margin + offset
            let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            offset += size.height + spacing

            if controller === newcomer {
                if isHidden {
                    // Don't slide into a screenshot that's being taken.
                    controller.move(to: frame, animated: false)
                    pending.append(controller)
                } else {
                    controller.present(at: frame, fromLeft: corner.isLeft)
                }
            } else if transferring && !isHidden {
                controller.transfer(to: frame, fromLeft: corner.isLeft)
            } else {
                controller.move(to: frame, animated: animated && !isHidden)
            }
        }
    }
}

@MainActor
final class PreviewModel: ObservableObject {
    @Published var image: NSImage
    @Published var fileURL: URL
    @Published var isHovering = false
    @Published var isPinned = false
    @Published var toast: String?
    @Published var recording: RecordingInfo?
    /// Bumped when the file's contents change in place, so an animated GIF reloads.
    @Published var revision = 0

    init(image: NSImage, fileURL: URL, recording: RecordingInfo?) {
        self.image = image
        self.fileURL = fileURL
        self.recording = recording
    }

    var isSaved: Bool { !CaptureStorage.isInCache(fileURL) }
    var kind: CaptureKind { CaptureKind(fileURL) }
    /// Screenshots open in the annotation editor, recordings in the video editor; a GIF needs its source video.
    var canEdit: Bool { kind != .gif || recording?.source != nil }
}

@MainActor
final class PreviewController {
    static let cornerRadius: CGFloat = 20
    static let padding: CGFloat = 6

    let model: PreviewModel
    let size: NSSize
    var onDismiss: (() -> Void)?
    /// Called when the file is opened in or dropped onto another app.
    var onHandOut: (() -> Void)?

    private let panel: GlassPanel
    private var timer: Timer?
    private var isDismissing = false
    private var isDragging = false
    private var isEditing = false
    private var transferGeneration = 0
    private var toastTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(image: NSImage, fileURL: URL, recording: RecordingInfo? = nil) {
        model = PreviewModel(image: image, fileURL: fileURL, recording: recording)
        let layout = Self.layout(for: recording?.pointSize ?? image.size)
        size = layout.card
        panel = GlassPanel(contentSize: layout.card)

        let card = PreviewCardView(
            model: model,
            imageArea: layout.imageArea,
            imageSize: layout.image,
            actions: PreviewActions(
                close: { [weak self] in self?.dismiss() },
                togglePin: { [weak self] in self?.togglePin() },
                copy: { [weak self] in self?.copyAgain() },
                save: { [weak self] in self?.saveAndReveal() },
                open: { [weak self] in self?.open() },
                annotate: { [weak self] in self?.annotate() },
                hover: { [weak self] hovering in self?.model.isHovering = hovering },
                dragStarted: { [weak self] in self?.dragStarted() },
                dragEnded: { [weak self] dropped in self?.dragEnded(dropped: dropped) }
            )
        )
        panel.setContent(card, cornerRadius: Self.cornerRadius)

        model.$isHovering
            .removeDuplicates()
            .sink { [weak self] hovering in
                if hovering { self?.cancelTimer() } else { self?.scheduleTimer() }
            }
            .store(in: &cancellables)

        AnnotationEditor.shared.didUpdate
            .sink { [weak self] update in
                guard let self, update.url == self.model.fileURL else { return }
                self.model.image = update.image
            }
            .store(in: &cancellables)

        VideoEditor.shared.didUpdate
            .sink { [weak self] update in
                guard let self, update.url == self.model.fileURL else { return }
                self.model.image = update.poster
                self.model.recording?.duration = update.duration
                self.model.revision += 1
            }
            .store(in: &cancellables)
    }

    // MARK: Presentation

    func present(at frame: NSRect, fromLeft: Bool) {
        var start = frame
        start.origin.x += fromLeft ? -48 : 48
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.38
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.async { [panel] in panel.invalidateShadow() }
        scheduleTimer()
    }

    /// Hops to another display: quick fade out, then slide in at the new spot.
    func transfer(to frame: NSRect, fromLeft: Bool) {
        guard !isDismissing else { return }
        transferGeneration += 1
        let generation = transferGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isDismissing, generation == self.transferGeneration else { return }
                self.present(at: frame, fromLeft: fromLeft)
            }
        })
    }

    func move(to frame: NSRect, animated: Bool) {
        guard !isDismissing else { return }
        transferGeneration += 1
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    func setHidden(_ hidden: Bool) {
        guard !isDismissing else { return }
        if hidden {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        cancelTimer()

        var end = panel.frame
        end.origin.x += AppSettings.shared.corner.isLeft ? -48 : 48
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.panel.orderOut(nil)
                self.panel.close()
                self.onDismiss?()
            }
        })
    }

    // MARK: Auto-dismiss

    private func scheduleTimer() {
        cancelTimer()
        guard !model.isPinned, !model.isHovering, !isDismissing, !isDragging, !isEditing,
              let interval = AppSettings.shared.previewDuration.interval else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Actions

    private func togglePin() {
        model.isPinned.toggle()
        if model.isPinned { cancelTimer() } else { scheduleTimer() }
    }

    private func copyAgain() {
        if model.kind.isRecording {
            Clipboard.copy(fileAt: model.fileURL)
        } else {
            Clipboard.copy(image: model.image, pngURL: model.fileURL)
        }
        showToast("Copied")
    }

    private func saveAndReveal() {
        if !model.isSaved {
            do {
                let saved = try CaptureStorage.save(model.fileURL, into: AppSettings.shared.saveFolder)
                CaptureHistory.shared.updateURL(from: model.fileURL, to: saved)
                model.fileURL = saved
            } catch {
                NSLog("Snaps: failed to save capture: \(error)")
                showToast("Couldn’t save")
                return
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([model.fileURL])
    }

    private func open() {
        onHandOut?()
        NSWorkspace.shared.open(model.fileURL)
        dismiss()
    }

    /// Opens the capture in the editor. The preview stays put meanwhile and shows the result when it closes.
    func annotate() {
        guard model.canEdit else { return }
        let onClose: (Bool) -> Void = { [weak self] copied in
            guard let self else { return }
            self.isEditing = false
            if copied { self.showToast("Copied") }
            self.scheduleTimer()
        }
        let opened: Bool
        if let recording = model.recording, model.kind.isRecording {
            opened = VideoEditor.shared.open(
                model.fileURL,
                source: recording.source,
                pointSize: recording.pointSize,
                target: { [weak model] in model?.fileURL },
                onClose: onClose
            )
        } else {
            opened = AnnotationEditor.shared.open(
                model.fileURL,
                target: { [weak model] in model?.fileURL },
                onClose: onClose
            )
        }
        if opened {
            isEditing = true
            cancelTimer()
        } else {
            showToast("Couldn’t open")
        }
    }

    private func dragStarted() {
        isDragging = true
        cancelTimer()
        panel.animator().alphaValue = 0.35
    }

    private func dragEnded(dropped: Bool) {
        isDragging = false
        if dropped {
            // A drop can be a link or a path, not just a copy, so the file has to outlive the preview.
            onHandOut?()
            dismiss()
        } else {
            panel.animator().alphaValue = 1
            scheduleTimer()
        }
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(.snappy) { model.toast = message }
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.model.toast = nil }
        }
    }

    // MARK: Sizing

    private static func layout(for imageSize: NSSize) -> (card: NSSize, imageArea: NSSize, image: NSSize) {
        let maxSize = NSSize(width: 240, height: 170)
        let minSize = NSSize(width: 150, height: 100)
        let w = max(imageSize.width, 1)
        let h = max(imageSize.height, 1)

        // Fit inside the max box, without upscaling tiny captures.
        let scale = min(maxSize.width / w, maxSize.height / h, 1)
        let image = NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let area = NSSize(width: max(image.width, minSize.width), height: max(image.height, minSize.height))
        let card = NSSize(width: area.width + padding * 2, height: area.height + padding * 2)
        return (card, area, image)
    }
}

/// Borderless, non-activating glass panel that floats above other windows (and the menu bar) on every Space.
final class GlassPanel: NSPanel {
    var onCancel: (() -> Void)?
    /// Panels that never need typing (e.g. the permission guide) shouldn't take keyboard focus from other apps.
    var allowsKeyFocus = true

    init(contentSize: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { allowsKeyFocus }
    override var canBecomeMain: Bool { false }

    // Allow the panel to sit over the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let onCancel { // Escape
            onCancel()
        } else {
            super.keyDown(with: event)
        }
    }

    func setContent<Content: View>(_ view: Content, cornerRadius: CGFloat) {
        let bounds = NSRect(origin: .zero, size: frame.size)
        let glass = NSGlassEffectView(frame: bounds)
        glass.cornerRadius = cornerRadius
        glass.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        glass.contentView = hosting

        contentView = glass
    }
}
