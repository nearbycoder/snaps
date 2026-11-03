import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// What the user chose to record.
struct RecordingSelection {
    var target: RecordingTarget
    /// The recorded region in global AppKit coordinates (bottom-left origin).
    var frame: CGRect
    var screen: NSScreen
    var format: RecordingFormat
    var isArea: Bool
}

/// Dims every display and lets the user drag out an area, click a screen, or press Space and click a window.
/// A glass bar under the selection holds the format, audio switches and the Record button.
@MainActor
final class RecordingPicker {
    /// Shows the picker; returns nil if it was cancelled.
    /// - Parameter returnTo: where focus goes afterwards if Snaps is frontmost now.
    static func pick(format: RecordingFormat, returnTo: NSRunningApplication? = nil) async -> RecordingSelection? {
        await withCheckedContinuation { continuation in
            let picker = RecordingPicker(format: format) { continuation.resume(returning: $0) }
            picker.previousApp = returnTo
            picker.show()
        }
    }

    private let session: PickerSession
    private var windows: [PickerWindow] = []
    private var previousApp: NSRunningApplication?
    private var completion: ((RecordingSelection?) -> Void)?
    /// Keeps the picker alive while it's on screen.
    private var retainSelf: RecordingPicker?

    private init(format: RecordingFormat, completion: @escaping (RecordingSelection?) -> Void) {
        session = PickerSession(format: format)
        self.completion = completion
    }

    private func show() {
        retainSelf = self
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let frontmost, frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }
        session.windowsOnScreen = PickableWindow.onScreen()
        session.onFinish = { [weak self] confirmed in self?.finish(confirmed: confirmed) }

        for screen in NSScreen.screens {
            let window = PickerWindow(screen: screen, session: session)
            windows.append(window)
            window.orderFrontRegardless()
        }
        NSApp.activate()
        let home = windows.first { $0.screen?.displayID == NSScreen.underMouse?.displayID } ?? windows.first
        home?.makeKeyAndOrderFront(nil)
        home?.makeFirstResponder(home?.contentView)
        session.mouse = NSEvent.mouseLocation
        session.changed()
    }

    private func finish(confirmed: Bool) {
        let result = confirmed ? session.result() : nil
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = []
        // Hand focus back, so the app being recorded is the active one.
        previousApp?.activate()
        completion?(result)
        completion = nil
        retainSelf = nil
    }
}

struct PickableWindow {
    let id: CGWindowID
    /// Global AppKit coordinates.
    let frame: CGRect

    /// Other apps' normal windows, front to back.
    static func onScreen() -> [PickableWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first
        else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? pid_t) != me,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 40, bounds.height >= 40
            else { return nil }
            let frame = CGRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
            return PickableWindow(id: id, frame: frame)
        }
    }
}

/// Shared state for the picker windows on every display.
@MainActor
final class PickerSession: ObservableObject {
    enum Selection: Equatable {
        case area(CGRect, screen: NSScreen)
        case window(CGWindowID, CGRect)
        case screen(NSScreen)

        var frame: CGRect {
            switch self {
            case let .area(rect, _): rect
            case let .window(_, rect): rect
            case let .screen(screen): screen.frame
            }
        }

        var screen: NSScreen {
            switch self {
            case let .area(_, screen): screen
            case let .window(_, rect): NSScreen.containing(rect)
            case let .screen(screen): screen
            }
        }
    }

    @Published var format: RecordingFormat
    @Published var selection: Selection?
    @Published var windowMode = false
    @Published var isDragging = false

    var windowsOnScreen: [PickableWindow] = []
    /// Global mouse location, for the crosshair and window highlight.
    var mouse: CGPoint = .zero
    var onFinish: ((Bool) -> Void)?
    var onChange: [() -> Void] = []

    init(format: RecordingFormat) {
        self.format = format
    }

    var hoveredWindow: PickableWindow? {
        guard windowMode else { return nil }
        return windowsOnScreen.first { $0.frame.contains(mouse) }
    }

    func changed() {
        onChange.forEach { $0() }
    }

    func toggleWindowMode() {
        windowMode.toggle()
        selection = nil
        changed()
    }

    func confirm() {
        guard selection != nil else { return }
        onFinish?(true)
    }

    func cancel() {
        onFinish?(false)
    }

    func result() -> RecordingSelection? {
        guard let selection else { return nil }
        let screen = selection.screen
        switch selection {
        case let .area(rect, screen):
            guard let id = screen.displayID else { return nil }
            // ScreenCaptureKit wants the crop in the display's points, measured from its top-left corner.
            let crop = CGRect(
                x: rect.minX - screen.frame.minX,
                y: screen.frame.maxY - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            return RecordingSelection(target: .display(id, crop: crop), frame: rect, screen: screen, format: format, isArea: true)
        case let .window(id, rect):
            return RecordingSelection(target: .window(id), frame: rect, screen: screen, format: format, isArea: false)
        case let .screen(screen):
            guard let id = screen.displayID else { return nil }
            return RecordingSelection(target: .display(id, crop: nil), frame: screen.frame, screen: screen, format: format, isArea: false)
        }
    }

    var sizeLabel: String {
        switch selection {
        case let .area(rect, _), let .window(_, rect):
            "\(Int(rect.width)) × \(Int(rect.height))"
        case let .screen(screen):
            "\(Int(screen.frame.width)) × \(Int(screen.frame.height))"
        case nil:
            ""
        }
    }
}

private final class PickerWindow: NSWindow {
    init(screen: NSScreen, session: PickerSession) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        sharingType = .none
        let view = PickerView(screen: screen, session: session)
        contentView = view
        initialFirstResponder = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class PickerView: NSView {
    private let screenRef: NSScreen
    private let session: PickerSession
    private let bar: NSHostingView<PickerBar>
    private let hint: NSHostingView<PickerHint>

    private enum Drag {
        case drawing(start: CGPoint)
        case moving(offset: CGVector, original: CGRect)
        case resizing(Handle, original: CGRect)
    }

    private enum Handle: CaseIterable {
        case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left
    }

    private var drag: Drag?
    private var trackingArea: NSTrackingArea?
    private var cancellable: AnyCancellable?

    init(screen: NSScreen, session: PickerSession) {
        screenRef = screen
        self.session = session
        bar = NSHostingView(rootView: PickerBar(session: session))
        hint = NSHostingView(rootView: PickerHint(session: session))
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        for view in [bar, hint] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        session.onChange.append { [weak self] in self?.refresh() }
        // The bar changes size when the format flips; @Published fires before the change lands.
        cancellable = session.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    private func refresh() {
        needsDisplay = true
        needsLayout = true
        updateCursor()
    }

    // MARK: Geometry

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -screenRef.frame.minX, dy: -screenRef.frame.minY)
    }

    private func global(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x + screenRef.frame.minX, y: point.y + screenRef.frame.minY)
    }

    private var selectionOnThisScreen: CGRect? {
        guard let selection = session.selection, selection.screen.displayID == screenRef.displayID else { return nil }
        return local(selection.frame).intersection(bounds)
    }

    private var areaSelection: CGRect? {
        if case let .area(rect, screen) = session.selection, screen.displayID == screenRef.displayID { return rect }
        return nil
    }

    private func handlePoint(_ handle: Handle, in r: CGRect) -> CGPoint {
        switch handle {
        case .bottomLeft: CGPoint(x: r.minX, y: r.minY)
        case .bottom: CGPoint(x: r.midX, y: r.minY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .topRight: CGPoint(x: r.maxX, y: r.maxY)
        case .top: CGPoint(x: r.midX, y: r.maxY)
        case .topLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        Handle.allCases.first { hypot(handlePoint($0, in: rect).x - point.x, handlePoint($0, in: rect).y - point.y) <= 9 }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let visible = local(screenRef.visibleFrame)

        let hintSize = hint.fittingSize
        hint.frame = CGRect(
            x: (bounds.midX - hintSize.width / 2).rounded(),
            y: visible.minY + 40,
            width: hintSize.width,
            height: hintSize.height
        )
        hint.isHidden = session.selection != nil || session.isDragging

        guard let selection = selectionOnThisScreen, !session.isDragging else {
            bar.isHidden = true
            return
        }
        bar.isHidden = false
        let size = bar.fittingSize
        var x = selection.midX - size.width / 2
        x = min(max(x, visible.minX + 12), visible.maxX - size.width - 12)
        // Below the selection, else above it, else inside along its bottom.
        var y = selection.minY - size.height - 14
        if y < visible.minY + 12 {
            y = selection.maxY + 14
            if y + size.height > visible.maxY - 12 {
                y = max(selection.minY, visible.minY) + 28
            }
        }
        bar.frame = CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let hole: CGRect? = selectionOnThisScreen ?? session.hoveredWindow.flatMap { window in
            screenRef.frame.intersects(window.frame) ? local(window.frame) : nil
        }

        let dim = NSBezierPath(rect: bounds)
        if let hole {
            dim.append(NSBezierPath(rect: hole))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.38).setFill()
        dim.fill()

        if session.windowMode, session.selection == nil, let hole {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            hole.fill()
            let border = NSBezierPath(rect: hole.insetBy(dx: 1.5, dy: 1.5))
            border.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            border.stroke()
        }

        if let selection = selectionOnThisScreen {
            if areaSelection != nil {
                drawAreaBorder(selection)
            } else {
                let border = NSBezierPath(rect: selection.insetBy(dx: 1.5, dy: 1.5))
                border.lineWidth = 3
                NSColor.controlAccentColor.setStroke()
                border.stroke()
            }
        }

        if session.isDragging, let rect = areaSelection.map(local) {
            drawSizeLabel(for: rect)
        } else if session.selection == nil, !session.windowMode, screenRef.frame.contains(session.mouse) {
            drawCrosshair(at: CGPoint(x: session.mouse.x - screenRef.frame.minX, y: session.mouse.y - screenRef.frame.minY))
        }
    }

    private func drawAreaBorder(_ rect: CGRect) {
        let outline = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        NSColor.white.withAlphaComponent(0.95).setStroke()
        outline.stroke()

        guard !session.isDragging else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 3
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.set()
        for handle in Handle.allCases {
            let p = handlePoint(handle, in: rect)
            let dot = NSBezierPath(ovalIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
            NSColor.white.setFill()
            dot.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCrosshair(at point: CGPoint) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: bounds.minX, y: point.y.rounded() + 0.5))
        path.line(to: CGPoint(x: bounds.maxX, y: point.y.rounded() + 0.5))
        path.move(to: CGPoint(x: point.x.rounded() + 0.5, y: bounds.minY))
        path.line(to: CGPoint(x: point.x.rounded() + 0.5, y: bounds.maxY))
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.35).setStroke()
        path.stroke()
    }

    private func drawSizeLabel(for rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        var box = CGRect(x: rect.maxX - size.width - 16, y: rect.minY - size.height - 14, width: size.width + 16, height: size.height + 8)
        if box.minY < bounds.minY + 4 { box.origin.y = rect.minY + 6 }
        box.origin.x = max(box.origin.x, bounds.minX + 4)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        text.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4), withAttributes: attributes)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        session.mouse = global(event)
        session.changed()
    }

    override func mouseEntered(with event: NSEvent) {
        session.mouse = global(event)
        session.changed()
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking another display's overlay makes it key; keep Esc, Return and Space working there.
        window?.makeFirstResponder(self)
        let point = global(event)
        session.mouse = point

        if session.windowMode {
            if let window = session.hoveredWindow {
                session.selection = .window(window.id, window.frame)
            } else {
                session.selection = .screen(screenRef)
            }
            session.windowMode = false
            session.changed()
            return
        }

        if let rect = areaSelection {
            let localPoint = CGPoint(x: point.x - screenRef.frame.minX, y: point.y - screenRef.frame.minY)
            if let handle = handle(at: localPoint, in: local(rect)) {
                drag = .resizing(handle, original: rect)
                return
            }
            if rect.contains(point) {
                drag = .moving(offset: CGVector(dx: point.x - rect.minX, dy: point.y - rect.minY), original: rect)
                NSCursor.closedHand.set()
                return
            }
        }
        drag = .drawing(start: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = clamp(global(event))
        session.mouse = point
        switch drag {
        case let .drawing(start):
            let rect = CGRect(
                x: min(start.x, point.x), y: min(start.y, point.y),
                width: abs(point.x - start.x), height: abs(point.y - start.y)
            )
            guard rect.width >= 3 || rect.height >= 3 || session.isDragging else { return }
            session.isDragging = true
            session.selection = .area(rect, screen: screenRef)
        case let .moving(offset, original):
            var rect = original
            rect.origin = CGPoint(x: point.x - offset.dx, y: point.y - offset.dy)
            rect.origin.x = min(max(rect.minX, screenRef.frame.minX), screenRef.frame.maxX - rect.width)
            rect.origin.y = min(max(rect.minY, screenRef.frame.minY), screenRef.frame.maxY - rect.height)
            session.selection = .area(rect, screen: screenRef)
        case let .resizing(handle, original):
            session.selection = .area(resize(original, handle: handle, to: point), screen: screenRef)
        }
        session.changed()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            session.isDragging = false
            session.changed()
        }
        guard let drag else { return }
        if case .drawing = drag, !session.isDragging {
            // A click without a drag records the whole display.
            session.selection = .screen(screenRef)
            return
        }
        guard case let .area(rect, screen) = session.selection else { return }
        var final = rect.integral
        final.size.width = max(final.width, 16)
        final.size.height = max(final.height, 16)
        session.selection = .area(final.intersection(screen.frame), screen: screen)
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        let frame = screenRef.frame
        return CGPoint(x: min(max(point.x, frame.minX), frame.maxX), y: min(max(point.y, frame.minY), frame.maxY))
    }

    private func resize(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .bottomLeft: minX = point.x; minY = point.y
        case .bottom: minY = point.y
        case .bottomRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .topRight: maxX = point.x; maxY = point.y
        case .top: maxY = point.y
        case .topLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    private func updateCursor() {
        // Every display's view refreshes together; only the one under the mouse picks the cursor.
        guard screenRef.frame.contains(session.mouse) else { return }
        if session.windowMode {
            NSCursor.pointingHand.set()
        } else if case .moving = drag {
            NSCursor.closedHand.set()
        } else if let rect = areaSelection, rect.contains(session.mouse), !session.isDragging {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            session.cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            session.confirm()
        case kVK_Space:
            session.toggleWindowMode()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        session.cancel()
    }
}

/// The glass bar under a selection: size, format, audio and Record.
struct PickerBar: View {
    @ObservedObject var session: PickerSession
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 10) {
            Text(session.sizeLabel)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 8)

            FormatSwitch(format: $session.format)

            if session.format == .video {
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        GlassToggleButton(
                            isOn: $settings.recordMicrophone,
                            on: "mic.fill", off: "mic.slash.fill",
                            help: settings.recordMicrophone ? "Microphone on" : "Microphone off"
                        )
                        GlassToggleButton(
                            isOn: $settings.recordSystemAudio,
                            on: "speaker.wave.2.fill", off: "speaker.slash.fill",
                            help: settings.recordSystemAudio ? "Computer audio on" : "Computer audio off"
                        )
                    }
                }
            }

            GlassIconButton(symbol: "xmark", help: "Cancel (Esc)", size: 30, action: session.cancel)

            Button(action: session.confirm) {
                Label("Record", systemImage: "record.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .controlSize(.large)
            .help("Start recording (Return)")
        }
        .padding(6)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
        .animation(.snappy(duration: 0.2), value: session.format)
    }
}

/// Instructions shown before anything's selected.
struct PickerHint: View {
    @ObservedObject var session: PickerSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.format == .gif ? RecordingFormat.gif.symbol : RecordingFormat.video.symbol)
                .foregroundStyle(.red)
            Text(session.windowMode
                 ? "Click a window to record it  ·  Space for an area  ·  Esc to cancel"
                 : "Drag to record an area  ·  Click for the whole screen  ·  Space for a window  ·  Esc to cancel")
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
    }
}

struct FormatSwitch: View {
    @Binding var format: RecordingFormat

    var body: some View {
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(RecordingFormat.allCases) { option in
                    let selected = option == format
                    Button {
                        format = option
                    } label: {
                        Text(option.shortTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(minWidth: 44)
                            .padding(.vertical, 7)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .glassEffect(selected ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}

struct GlassToggleButton: View {
    @Binding var isOn: Bool
    let on: String
    let off: String
    let help: String
    var size: CGFloat = 30

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: isOn ? on : off)
                .font(.system(size: 12, weight: .bold))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .glassEffect(isOn ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .circle)
        .help(help)
        .accessibilityLabel(help)
    }
}

extension NSScreen {
    /// The display holding most of `rect`.
    static func containing(_ rect: CGRect) -> NSScreen {
        screens.max { a, b in
            let ia = a.frame.intersection(rect), ib = b.frame.intersection(rect)
            return ia.width * ia.height < ib.width * ib.height
        } ?? main ?? screens[0]
    }
}
