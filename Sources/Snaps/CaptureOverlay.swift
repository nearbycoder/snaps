import AppKit
import Carbon.HIToolbox

/// Full-screen picker for Area and Window captures. Hovering highlights the window under the cursor and a
/// click captures that window on its own; in Area mode, dragging selects a region instead.
///
/// The panels never become key and never activate Snaps, so the app being captured keeps its active look
/// (colored window buttons, focused title bar). Escape is a temporary global hot key for the same reason.
@MainActor
final class CaptureOverlay {
    private static var current: CaptureOverlay?
    private static let escapeHotKeyID: UInt32 = 900
    /// How far the mouse must travel before a press becomes an area drag instead of a window click.
    private static let dragThreshold: CGFloat = 4

    /// Shows the picker on every display and waits for a choice. Returns nil when cancelled.
    static func pick(allowsArea: Bool) async -> CaptureTarget? {
        current?.cancel()
        let overlay = CaptureOverlay(allowsArea: allowsArea)
        current = overlay
        return await withCheckedContinuation { continuation in
            overlay.begin(continuation)
        }
    }

    fileprivate struct WindowInfo {
        let id: CGWindowID
        /// AppKit global coordinates (bottom-left origin), in points.
        let frame: CGRect
    }

    private struct Drag {
        let start: CGPoint
        /// The display the drag started on; the selection stays inside it.
        let bounds: CGRect
        var isSelecting = false
    }

    private let allowsArea: Bool
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private let windows: [WindowInfo]
    private var panels: [OverlayPanel] = []
    private var continuation: CheckedContinuation<CaptureTarget?, Never>?
    private var hoveredID: CGWindowID?
    private var drag: Drag?
    private var selection: CGRect?
    private var screenObserver: NSObjectProtocol?

    private init(allowsArea: Bool) {
        self.allowsArea = allowsArea
        // Snapshot before the panels exist, so they never show up as a window to pick.
        windows = Self.pickableWindows()
    }

    private func begin(_ continuation: CheckedContinuation<CaptureTarget?, Never>) {
        self.continuation = continuation

        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen, owner: self, reduceMotion: reduceMotion)
            panels.append(panel)
            panel.orderFrontRegardless()
        }

        let escape = Shortcut(keyCode: UInt32(kVK_Escape), modifiers: [])
        HotKeyCenter.shared.register(id: Self.escapeHotKeyID, shortcut: escape) { [weak self] in
            self?.cancel()
        }
        // A display plugged in or removed mid-pick would leave a panel in the wrong place.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }

        NSCursor.crosshair.set()
        hover(at: NSEvent.mouseLocation)
    }

    func cancel() {
        finish(nil)
    }

    // MARK: Input from the panels

    fileprivate func hover(at point: CGPoint) {
        guard drag == nil else { return }
        let window = window(at: point)
        guard window?.id != hoveredID else { return }
        hoveredID = window?.id
        for panel in panels { panel.view.showHighlight(window?.frame) }
    }

    fileprivate func press(at point: CGPoint, on bounds: CGRect) {
        drag = Drag(start: point, bounds: bounds)
    }

    fileprivate func dragged(to point: CGPoint) {
        guard allowsArea, var drag else { return }
        if !drag.isSelecting {
            guard hypot(point.x - drag.start.x, point.y - drag.start.y) >= Self.dragThreshold else { return }
            drag.isSelecting = true
            self.drag = drag
            hoveredID = nil
            for panel in panels { panel.view.showHighlight(nil) }
        }

        let start = drag.start.clamped(to: drag.bounds)
        let end = point.clamped(to: drag.bounds)
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        selection = rect
        for panel in panels {
            panel.view.showSelection(panel.view.screenFrame == drag.bounds ? rect : nil)
        }
    }

    fileprivate func released(at point: CGPoint) {
        guard let drag else { return }
        self.drag = nil

        if drag.isSelecting {
            if let rect = selection?.integral, rect.width >= 4, rect.height >= 4 {
                finish(.area(rect))
            } else {
                // Too small to mean anything: back to picking.
                selection = nil
                for panel in panels { panel.view.showSelection(nil) }
                hover(at: point)
            }
        } else if let window = window(at: point) {
            finish(.window(window.id))
        }
        // A click on the bare desktop does nothing; Escape is the way out.
    }

    // MARK: Finishing

    private func finish(_ target: CaptureTarget?) {
        guard let continuation else { return }
        self.continuation = nil

        HotKeyCenter.shared.unregister(id: Self.escapeHotKeyID)
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        if Self.current === self { Self.current = nil }
        NSCursor.arrow.set()

        let panels = self.panels
        self.panels = []
        if target == nil {
            // Cancelling fades the marks away (a fade, so Reduce Motion keeps it); a capture needs the
            // screen clear right now. Clicks go back to the apps below at once either way.
            for panel in panels { panel.ignoresMouseEvents = true }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Motion.quick
                for panel in panels { panel.animator().alphaValue = 0 }
            }, completionHandler: {
                Task { @MainActor in
                    for panel in panels { panel.orderOut(nil); panel.close() }
                }
            })
        } else {
            for panel in panels {
                panel.view.clear()
                panel.orderOut(nil)
                panel.close()
            }
        }
        continuation.resume(returning: target)
    }

    // MARK: Windows

    private func window(at point: CGPoint) -> WindowInfo? {
        windows.first { $0.frame.contains(point) }
    }

    /// Regular app windows on screen, front to back. Leaves out the desktop, the Dock, the menu bar and
    /// anything above them, plus invisible or tiny windows.
    private static func pickableWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]],
            let primary = NSScreen.screens.first
        else { return [] }

        let topLayer = Int(CGWindowLevelForKey(.dockWindow))
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer >= 0, layer < topLayer,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40
            else { return nil }
            // Quartz window bounds have a top-left origin on the primary display.
            let frame = CGRect(
                x: bounds.minX,
                y: primary.frame.maxY - bounds.maxY,
                width: bounds.width,
                height: bounds.height
            )
            return WindowInfo(id: CGWindowID(number.uint32Value), frame: frame)
        }
    }
}

// MARK: - Panel

/// One per display. Borderless, transparent and above everything, including full-screen apps.
private final class OverlayPanel: NSPanel {
    let view: OverlayView

    init(screen: NSScreen, owner: CaptureOverlay, reduceMotion: Bool) {
        view = OverlayView(screen: screen, reduceMotion: reduceMotion)
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        view.owner = owner
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Take clicks over the transparent parts too, instead of letting them through to the app below.
        ignoresMouseEvents = false
        contentView = view
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Allow the panel to cover the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - View

private final class OverlayView: NSView {
    weak var owner: CaptureOverlay?
    let screenFrame: CGRect

    private let reduceMotion: Bool
    private let scale: CGFloat
    private let highlight = CALayer()
    private let dim = CAShapeLayer()
    private let border = CAShapeLayer()
    private let sizePill = CALayer()
    private let sizeText = CATextLayer()
    private var trackingArea: NSTrackingArea?

    private static let highlightRadius: CGFloat = 16
    private static let pillFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    init(screen: NSScreen, reduceMotion: Bool) {
        screenFrame = screen.frame
        scale = screen.backingScaleFactor
        self.reduceMotion = reduceMotion
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        setUpLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUpLayers() {
        guard let root = layer else { return }
        root.masksToBounds = true
        // Barely there, but enough for the window server to send every click here.
        root.backgroundColor = NSColor(white: 0, alpha: 0.002).cgColor

        let accent = NSColor.controlAccentColor
        highlight.backgroundColor = accent.withAlphaComponent(0.18).cgColor
        highlight.borderColor = accent.withAlphaComponent(0.95).cgColor
        highlight.borderWidth = 2
        highlight.cornerRadius = Self.highlightRadius
        highlight.cornerCurve = .continuous
        highlight.opacity = 0
        root.addSublayer(highlight)

        dim.fillColor = NSColor.black.withAlphaComponent(0.32).cgColor
        dim.fillRule = .evenOdd
        dim.opacity = 0
        root.addSublayer(dim)

        border.fillColor = nil
        border.strokeColor = NSColor.white.cgColor
        border.lineWidth = 1
        border.shadowColor = NSColor.black.cgColor
        border.shadowOpacity = 0.55
        border.shadowRadius = 1.5
        border.shadowOffset = .zero
        border.opacity = 0
        root.addSublayer(border)

        sizePill.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        sizePill.cornerCurve = .continuous
        sizePill.opacity = 0
        sizeText.font = Self.pillFont
        sizeText.fontSize = Self.pillFont.pointSize
        sizeText.foregroundColor = NSColor.white.cgColor
        sizeText.alignmentMode = .center
        sizeText.contentsScale = scale
        sizePill.addSublayer(sizeText)
        root.addSublayer(sizePill)
    }

    // MARK: Drawing

    /// Marks a window (global frame), sliding over from the previous one. Nil fades the mark out.
    func showHighlight(_ globalFrame: CGRect?) {
        // A window on another display is that display's to mark.
        guard let globalFrame, globalFrame.intersects(screenFrame) else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Motion.quick)
            highlight.opacity = 0
            CATransaction.commit()
            return
        }

        let frame = local(globalFrame).insetBy(dx: -1, dy: -1)
        let isVisible = highlight.opacity > 0

        CATransaction.begin()
        if isVisible && !reduceMotion {
            CATransaction.setAnimationDuration(Motion.fast)
            CATransaction.setAnimationTimingFunction(Motion.smoothOutCurve)
            highlight.frame = frame
        } else {
            // Appearing (or Reduce Motion): jump into place and only fade.
            CATransaction.setDisableActions(true)
            highlight.frame = frame
        }
        CATransaction.commit()

        if !isVisible {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Motion.quick)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            highlight.opacity = 1
            CATransaction.commit()
        }
    }

    /// Dims everything outside the selection (global rect) and shows its size. Nil clears it.
    func showSelection(_ globalRect: CGRect?) {
        guard let globalRect else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Motion.quick)
            dim.opacity = 0
            border.opacity = 0
            sizePill.opacity = 0
            CATransaction.commit()
            return
        }

        let rect = local(globalRect)
        let wasHidden = dim.opacity == 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(rect)
        dim.path = path
        border.path = CGPath(rect: rect.insetBy(dx: -0.5, dy: -0.5), transform: nil)
        border.opacity = 1
        layoutSizePill(for: rect)
        sizePill.opacity = 1
        CATransaction.commit()

        if wasHidden {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Motion.quick)
            dim.opacity = 1
            CATransaction.commit()
        }
    }

    /// Removes every mark at once, before the screen is captured.
    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.opacity = 0
        dim.opacity = 0
        border.opacity = 0
        sizePill.opacity = 0
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Size in pixels, centered under the selection, or above it when there's no room below.
    private func layoutSizePill(for rect: CGRect) {
        let text = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))"
        sizeText.string = text
        let textSize = (text as NSString).size(withAttributes: [.font: Self.pillFont])
        let size = CGSize(width: ceil(textSize.width) + 16, height: 22)
        let gap: CGFloat = 8

        var y = rect.minY - gap - size.height
        if y < bounds.minY + 4 { y = rect.maxY + gap }
        if y + size.height > bounds.maxY - 4 { y = rect.minY + gap }
        var x = rect.midX - size.width / 2
        x = min(max(x, bounds.minX + 4), bounds.maxX - size.width - 4)

        sizePill.frame = CGRect(x: x, y: y, width: size.width, height: size.height).integral
        sizePill.cornerRadius = size.height / 2
        sizeText.frame = CGRect(
            x: 0,
            y: (size.height - ceil(textSize.height)) / 2,
            width: size.width,
            height: ceil(textSize.height)
        )
    }

    private func local(_ global: CGRect) -> CGRect {
        global.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.set()
        owner?.hover(at: NSEvent.mouseLocation)
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        owner?.hover(at: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        owner?.press(at: NSEvent.mouseLocation, on: screenFrame)
    }

    override func mouseDragged(with event: NSEvent) {
        owner?.dragged(to: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        owner?.released(at: NSEvent.mouseLocation)
    }

    /// A right click backs out, like Escape.
    override func rightMouseDown(with event: NSEvent) {
        owner?.cancel()
    }
}

private extension CGPoint {
    func clamped(to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(x, rect.minX), rect.maxX), y: min(max(y, rect.minY), rect.maxY))
    }
}
