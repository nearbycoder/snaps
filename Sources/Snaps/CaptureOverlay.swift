import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

/// Full-screen picker for Area and Window captures, modeled on Monosnap's. The pointer becomes a crosshair
/// that spans the display, with a loupe beside it (magnified pixels, position or selection size, and the
/// color under the cursor) and a short list of what a click or drag does. The window under the cursor gets
/// a thin outline and a click captures that window on its own; in Area mode, dragging selects a region.
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
    private var hidesCursor = false

    private init(allowsArea: Bool) {
        self.allowsArea = allowsArea
        // Snapshot before the panels exist, so they never show up as a window to pick.
        windows = Self.pickableWindows()
    }

    private func begin(_ continuation: CheckedContinuation<CaptureTarget?, Never>) {
        self.continuation = continuation

        let hint = allowsArea
            ? ["Click a window to capture it", "Drag to select an area", "Esc to cancel"]
            : ["Click a window to capture it", "Esc to cancel"]
        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen, owner: self, hint: hint, reduceMotion: reduceMotion)
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

        // The drawn crosshair is the pointer. Where macOS won't hide the system one for an app in the
        // background, the crosshair cursor at least lines up with it.
        NSCursor.crosshair.set()
        NSCursor.hide()
        hidesCursor = true

        hover(at: NSEvent.mouseLocation)
        loadSnapshots()
    }

    func cancel() {
        finish(nil)
    }

    // MARK: Input from the panels

    fileprivate func hover(at point: CGPoint) {
        guard drag == nil else { return }
        for panel in panels { panel.view.movePointer(to: point, readout: .position, showsHint: true) }

        let window = window(at: point)
        guard window?.id != hoveredID else { return }
        hoveredID = window?.id
        for panel in panels { panel.view.showOutline(window?.frame) }
    }

    fileprivate func press(at point: CGPoint, on bounds: CGRect) {
        drag = Drag(start: point, bounds: bounds)
    }

    fileprivate func dragged(to point: CGPoint) {
        guard allowsArea, var drag else {
            for panel in panels { panel.view.movePointer(to: point, readout: .position, showsHint: true) }
            return
        }
        if !drag.isSelecting {
            guard hypot(point.x - drag.start.x, point.y - drag.start.y) >= Self.dragThreshold else { return }
            drag.isSelecting = true
            self.drag = drag
            hoveredID = nil
            for panel in panels { panel.view.showOutline(nil) }
        }

        // Whole points, so the outline, the size readout and the capture all agree.
        let start = drag.start.clamped(to: drag.bounds).rounded
        let end = point.clamped(to: drag.bounds).rounded
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        selection = rect
        for panel in panels {
            let isHere = panel.view.screenFrame == drag.bounds
            panel.view.showSelection(isHere ? rect : nil)
            panel.view.movePointer(to: end, readout: .size(rect.size), showsHint: false)
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
                hoveredID = nil
                hover(at: point)
            }
        } else if let window = window(at: point) {
            finish(.window(window.id))
        }
        // A click on the bare desktop does nothing; Escape is the way out.
    }

    // MARK: Loupe pixels

    /// A still of each display for the loupe, taken without the panels. The loupe shows an empty grid for
    /// the moment this takes.
    private func loadSnapshots() {
        let overlayIDs = Set(panels.map { CGWindowID($0.windowNumber) })
        Task { @MainActor [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            else { return }
            let overlays = content.windows.filter { overlayIDs.contains($0.windowID) }

            for panel in self?.panels ?? [] {
                guard let display = content.displays.first(where: { $0.displayID == panel.view.displayID }) else { continue }
                let filter = SCContentFilter(display: display, excludingWindows: overlays)
                let configuration = SCStreamConfiguration()
                configuration.width = Int((CGFloat(display.width) * panel.view.scale).rounded())
                configuration.height = Int((CGFloat(display.height) * panel.view.scale).rounded())
                configuration.showsCursor = false
                configuration.captureResolution = .best
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                else { continue }
                // The pick may have finished while this was running.
                guard let self, self.continuation != nil else { return }
                panel.view.snapshot = image
            }
        }
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
        if hidesCursor {
            NSCursor.unhide()
            hidesCursor = false
        }
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
                    for panel in panels {
                        panel.view.snapshot = nil
                        panel.orderOut(nil)
                        panel.close()
                    }
                }
            })
        } else {
            for panel in panels {
                panel.view.clear()
                panel.view.snapshot = nil
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
            // Above normal windows, skip anything as big as a display (dimmers, focus overlays).
            if layer > 0, NSScreen.screens.contains(where: { $0.frame.width <= bounds.width + 1 && $0.frame.height <= bounds.height + 1 }) {
                return nil
            }
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

    init(screen: NSScreen, owner: CaptureOverlay, hint: [String], reduceMotion: Bool) {
        view = OverlayView(screen: screen, hint: hint, reduceMotion: reduceMotion)
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
    enum Readout {
        /// Where the pointer is, in the display's pixels from its top left.
        case position
        /// The selection's size, in pixels.
        case size(CGSize)
    }

    weak var owner: CaptureOverlay?
    let screenFrame: CGRect
    let scale: CGFloat
    let displayID: CGDirectDisplayID?
    /// The display as it was when the pick began, for the loupe.
    var snapshot: CGImage? {
        didSet { if snapshot != nil { refreshLoupe() } }
    }

    private let reduceMotion: Bool
    private let outline = CALayer()
    private let dim = CAShapeLayer()
    private let border = CAShapeLayer()
    private let crosshairShade = CAShapeLayer()
    private let crosshair = CAShapeLayer()
    private let loupe = CALayer()
    private let loupePixels = CALayer()
    private let loupeGridShade = CAShapeLayer()
    private let loupeGrid = CAShapeLayer()
    private let loupeReadout = CATextLayer()
    private let loupeColor = CATextLayer()
    private let hintBox = CALayer()
    private let hintText = CATextLayer()
    private var trackingArea: NSTrackingArea?
    private var pointer: CGPoint?
    private var readout: Readout = .position

    private static let outlineRadius: CGFloat = 16
    /// Pixels across the loupe, and how big each one is drawn.
    private static let loupeSpan = 17
    private static let loupeZoom: CGFloat = 8
    private static let loupeInset: CGFloat = 4
    private static let loupeStrip: CGFloat = 20
    private static let pointerGap: CGFloat = 18
    private static let readoutFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    private static let hintFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private static let panelColor = NSColor(white: 0.08, alpha: 0.82).cgColor

    init(screen: NSScreen, hint: [String], reduceMotion: Bool) {
        screenFrame = screen.frame
        scale = screen.backingScaleFactor
        displayID = screen.displayID
        self.reduceMotion = reduceMotion
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        setUpLayers(hint: hint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUpLayers(hint: [String]) {
        guard let root = layer else { return }
        root.masksToBounds = true
        // Barely there, but enough for the window server to send every click here.
        root.backgroundColor = NSColor(white: 0, alpha: 0.002).cgColor

        // The window under the cursor: an outline only, so its pixels stay exactly as they'll be captured.
        outline.borderColor = NSColor.controlAccentColor.cgColor
        outline.borderWidth = 2
        outline.cornerRadius = Self.outlineRadius
        outline.cornerCurve = .continuous
        outline.opacity = 0
        root.addSublayer(outline)

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

        // A light hairline over a soft dark one reads on any background.
        crosshairShade.strokeColor = NSColor.black.withAlphaComponent(0.28).cgColor
        crosshairShade.lineWidth = 3 / scale
        crosshairShade.fillColor = nil
        crosshair.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        crosshair.lineWidth = 1 / scale
        crosshair.fillColor = nil
        root.addSublayer(crosshairShade)
        root.addSublayer(crosshair)

        let pixels = CGFloat(Self.loupeSpan) * Self.loupeZoom
        loupe.frame = CGRect(
            x: 0, y: 0,
            width: pixels + Self.loupeInset * 2,
            height: pixels + Self.loupeInset * 2 + Self.loupeStrip
        )
        loupe.backgroundColor = Self.panelColor
        loupe.cornerRadius = 10
        loupe.cornerCurve = .continuous
        loupe.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        loupe.borderWidth = 0.5
        loupe.shadowColor = NSColor.black.cgColor
        loupe.shadowOpacity = 0.35
        loupe.shadowRadius = 8
        loupe.shadowOffset = CGSize(width: 0, height: -2)

        loupePixels.frame = CGRect(x: Self.loupeInset, y: Self.loupeInset + Self.loupeStrip, width: pixels, height: pixels)
        loupePixels.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        loupePixels.magnificationFilter = .nearest
        loupePixels.contentsGravity = .resize
        loupePixels.cornerRadius = 6
        loupePixels.cornerCurve = .continuous
        loupePixels.masksToBounds = true
        loupe.addSublayer(loupePixels)

        // Same two-tone trick as the crosshair, so the center pixel stays findable on white and on black.
        let gridPath = Self.loupeGridPath(side: pixels)
        for (grid, color, width) in [
            (loupeGridShade, NSColor.black.withAlphaComponent(0.45), 2.5 as CGFloat),
            (loupeGrid, NSColor.white.withAlphaComponent(0.95), 1 as CGFloat),
        ] {
            grid.frame = loupePixels.frame
            grid.path = gridPath
            grid.strokeColor = color.cgColor
            grid.fillColor = nil
            grid.lineWidth = width
            loupe.addSublayer(grid)
        }

        for (text, alignment) in [(loupeReadout, CATextLayerAlignmentMode.left), (loupeColor, .right)] {
            text.font = Self.readoutFont
            text.fontSize = Self.readoutFont.pointSize
            text.foregroundColor = NSColor.white.cgColor
            text.alignmentMode = alignment
            text.contentsScale = scale
            text.frame = CGRect(
                x: Self.loupeInset + 4,
                y: Self.loupeInset + 3,
                width: pixels - 8,
                height: Self.loupeStrip - 4
            )
            loupe.addSublayer(text)
        }
        loupe.isHidden = true
        root.addSublayer(loupe)

        let lines = hint.joined(separator: "\n")
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.hintFont]
        let textSize = (lines as NSString).boundingRect(
            with: CGSize(width: 400, height: 400),
            options: [.usesLineFragmentOrigin],
            attributes: attributes
        ).size
        hintText.string = lines
        hintText.font = Self.hintFont
        hintText.fontSize = Self.hintFont.pointSize
        hintText.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        hintText.contentsScale = scale
        hintText.frame = CGRect(x: 10, y: 7, width: ceil(textSize.width) + 2, height: ceil(textSize.height) + 2)
        hintBox.frame = CGRect(x: 0, y: 0, width: ceil(textSize.width) + 22, height: ceil(textSize.height) + 16)
        hintBox.backgroundColor = Self.panelColor
        hintBox.cornerRadius = 8
        hintBox.cornerCurve = .continuous
        hintBox.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        hintBox.borderWidth = 0.5
        hintBox.addSublayer(hintText)
        hintBox.isHidden = true
        root.addSublayer(hintBox)
    }

    /// The center pixel boxed, with a line from each edge of the loupe toward it.
    private static func loupeGridPath(side: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let low = CGFloat(loupeSpan / 2) * loupeZoom
        let high = low + loupeZoom
        path.addRect(CGRect(x: low, y: low, width: loupeZoom, height: loupeZoom).insetBy(dx: 0.5, dy: 0.5))
        let mid = low + loupeZoom / 2
        path.move(to: CGPoint(x: mid, y: 0)); path.addLine(to: CGPoint(x: mid, y: low))
        path.move(to: CGPoint(x: mid, y: high)); path.addLine(to: CGPoint(x: mid, y: side))
        path.move(to: CGPoint(x: 0, y: mid)); path.addLine(to: CGPoint(x: low, y: mid))
        path.move(to: CGPoint(x: high, y: mid)); path.addLine(to: CGPoint(x: side, y: mid))
        return path
    }

    // MARK: Pointer

    /// Draws the crosshair, loupe and hint at a global point, or hides them when it's on another display.
    func movePointer(to global: CGPoint, readout: Readout, showsHint: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard screenFrame.contains(global) || screenFrame.contains(CGPoint(x: global.x - 0.5, y: global.y - 0.5)) else {
            pointer = nil
            crosshair.path = nil
            crosshairShade.path = nil
            loupe.isHidden = true
            hintBox.isHidden = true
            return
        }

        let point = local(global)
        pointer = point
        self.readout = readout

        // Snap the hairlines to device pixels so they stay one pixel wide.
        let x = (floor(point.x * scale) + 0.5) / scale
        let y = (floor(point.y * scale) + 0.5) / scale
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: bounds.minY)); path.addLine(to: CGPoint(x: x, y: bounds.maxY))
        path.move(to: CGPoint(x: bounds.minX, y: y)); path.addLine(to: CGPoint(x: bounds.maxX, y: y))
        crosshair.path = path
        crosshairShade.path = path

        // Loupe below and to the right; hint above and to the left. Each flips at the display's edges.
        let gap = Self.pointerGap
        var loupeOrigin = CGPoint(x: point.x + gap, y: point.y - gap - loupe.bounds.height)
        if loupeOrigin.x + loupe.bounds.width > bounds.maxX { loupeOrigin.x = point.x - gap - loupe.bounds.width }
        if loupeOrigin.y < bounds.minY { loupeOrigin.y = point.y + gap }
        loupe.frame.origin = loupeOrigin
        loupe.isHidden = false
        refreshLoupe()

        hintBox.isHidden = !showsHint
        if showsHint {
            var hintOrigin = CGPoint(x: point.x - gap - hintBox.bounds.width, y: point.y + gap)
            if hintOrigin.x < bounds.minX { hintOrigin.x = point.x + gap }
            if hintOrigin.y + hintBox.bounds.height > bounds.maxY { hintOrigin.y = point.y - gap - hintBox.bounds.height }
            // Keep clear of the loupe when both had to flip to the same side.
            if CGRect(origin: hintOrigin, size: hintBox.bounds.size).intersects(loupe.frame) {
                hintOrigin.y = loupe.frame.maxY + 6
            }
            hintBox.frame.origin = hintOrigin
        }
    }

    private func refreshLoupe() {
        guard let pointer else { return }
        let px = Int(floor(pointer.x * scale))
        let py = Int(floor((bounds.height - pointer.y) * scale))

        switch readout {
        case .position:
            loupeReadout.string = "\(px), \(py)"
        case .size(let size):
            loupeReadout.string = "\(Int((size.width * scale).rounded())) × \(Int((size.height * scale).rounded()))"
        }

        guard let snapshot else {
            loupePixels.contents = nil
            loupeColor.string = nil
            return
        }
        let half = Self.loupeSpan / 2
        let cx = min(max(px, half), snapshot.width - half - 1)
        let cy = min(max(py, half), snapshot.height - half - 1)
        let region = CGRect(x: cx - half, y: cy - half, width: Self.loupeSpan, height: Self.loupeSpan)
        loupePixels.contents = snapshot.cropping(to: region)
        loupeColor.string = Self.hexColor(of: snapshot, x: min(max(px, 0), snapshot.width - 1), y: min(max(py, 0), snapshot.height - 1))
    }

    private static func hexColor(of image: CGImage, x: Int, y: Int) -> String? {
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return String(format: "#%02X%02X%02X", rgba[0], rgba[1], rgba[2])
    }

    // MARK: Window and selection

    /// Outlines a window (global frame), sliding over from the previous one. Nil fades the outline out.
    func showOutline(_ globalFrame: CGRect?) {
        // A window on another display is that display's to mark.
        guard let globalFrame, globalFrame.intersects(screenFrame) else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Motion.quick)
            outline.opacity = 0
            CATransaction.commit()
            return
        }

        let frame = local(globalFrame).insetBy(dx: -1, dy: -1)
        let isVisible = outline.opacity > 0

        CATransaction.begin()
        if isVisible && !reduceMotion {
            CATransaction.setAnimationDuration(Motion.fast)
            CATransaction.setAnimationTimingFunction(Motion.smoothOutCurve)
            outline.frame = frame
        } else {
            // Appearing (or Reduce Motion): jump into place and only fade.
            CATransaction.setDisableActions(true)
            outline.frame = frame
        }
        CATransaction.commit()

        if !isVisible {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Motion.quick)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            outline.opacity = 1
            CATransaction.commit()
        }
    }

    /// Dims everything outside the selection (global rect). Nil clears it.
    func showSelection(_ globalRect: CGRect?) {
        guard let globalRect else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Motion.quick)
            dim.opacity = 0
            border.opacity = 0
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
        outline.opacity = 0
        dim.opacity = 0
        border.opacity = 0
        crosshair.path = nil
        crosshairShade.path = nil
        loupe.isHidden = true
        hintBox.isHidden = true
        CATransaction.commit()
        CATransaction.flush()
    }

    private func local(_ global: CGRect) -> CGRect {
        global.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    private func local(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - screenFrame.minX, y: global.y - screenFrame.minY)
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

private extension CGPoint {
    var rounded: CGPoint { CGPoint(x: x.rounded(), y: y.rounded()) }
}
