import AppKit
import Carbon.HIToolbox

/// The editing surface: shows the capture, draws annotations over it and turns mouse and keyboard input into edits.
final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    var onCopy: (() -> Void)?
    var onDone: (() -> Void)?

    private let model: EditorModel
    private let imageView = CanvasImageView()
    private let overlay = CanvasOverlayView()
    /// Lays out in image points, so text is edited at the size it will be exported at.
    private let textHost = CanvasTextHostView()
    private let insets = NSEdgeInsets(top: 8, left: 24, bottom: 24, right: 24)
    private var trackingArea: NSTrackingArea?

    private var imageRect: CGRect = .zero
    private var scale: CGFloat = 1

    private enum Handle {
        case arrowStart, arrowEnd
        /// A blur corner; `anchor` is the opposite corner, which stays put.
        case corner(anchor: CGPoint)
    }

    private enum Interaction {
        case creating(UUID, anchor: CGPoint)
        case moving(UUID, start: CGPoint, original: Annotation)
        case resizing(UUID, Handle, original: Annotation)
    }

    private struct TextEditing {
        let view: AnnotationTextView
        var annotation: Annotation
        let isNew: Bool
        let undoManager = UndoManager()
    }

    private var interaction: Interaction?
    private var textEditing: TextEditing?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true

        imageView.image = model.image
        imageView.castsShadow = Self.isOpaqueAtCorner(model.image)
        overlay.canvas = self
        addSubview(imageView)
        addSubview(overlay)
        addSubview(textHost)

        model.onDisplay = { [weak self] in self?.overlay.needsDisplay = true }
        model.onToolChange = { [weak self] in self?.toolChanged() }
        model.onStyleChange = { [weak self] in self?.restyleText() ?? false }
        model.onFinishEditing = { [weak self] in self?.commitText() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout

    override func layout() {
        super.layout()
        let available = CGRect(
            x: insets.left,
            y: insets.top,
            width: max(bounds.width - insets.left - insets.right, 1),
            height: max(bounds.height - insets.top - insets.bottom, 1)
        )
        let size = model.imageSize
        // Fit, but never enlarge past the capture's own size.
        let fit = min(available.width / size.width, available.height / size.height, 1)
        let shown = CGSize(width: max((size.width * fit).rounded(), 1), height: max((size.height * fit).rounded(), 1))
        imageRect = CGRect(
            x: (available.midX - shown.width / 2).rounded(),
            y: (available.midY - shown.height / 2).rounded(),
            width: shown.width,
            height: shown.height
        )
        scale = shown.width / size.width

        imageView.frame = imageRect
        overlay.frame = bounds
        textHost.frame = imageRect
        textHost.bounds = CGRect(origin: .zero, size: size)
        overlay.needsDisplay = true
    }

    // MARK: Drawing

    fileprivate func drawOverlay() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clip(to: imageRect)
        ctx.translateBy(x: imageRect.minX, y: imageRect.minY)
        ctx.scaleBy(x: scale, y: scale)
        AnnotationRenderer.draw(displayedAnnotations, blurred: model.blurred, imageSize: model.imageSize, in: ctx)
        ctx.restoreGState()

        if let selected = model.selected, selected.id != textEditing?.annotation.id {
            drawSelection(selected, in: ctx)
        }
    }

    /// The model's annotations, with the text being typed shown live in its place.
    private var displayedAnnotations: [Annotation] {
        guard let editing = textEditing, case let .text(origin, _) = editing.annotation.shape else {
            return model.annotations
        }
        var live = editing.annotation
        live.shape = .text(origin: origin, string: editing.view.string)
        var annotations = model.annotations
        if let index = annotations.firstIndex(where: { $0.id == live.id }) {
            annotations[index] = live
        } else {
            annotations.append(live)
        }
        return annotations
    }

    private func drawSelection(_ annotation: Annotation, in ctx: CGContext) {
        switch annotation.shape {
        case let .arrow(from, to):
            drawHandle(at: viewPoint(from), in: ctx)
            drawHandle(at: viewPoint(to), in: ctx)
        case .text:
            drawOutline(viewRect(annotation.bounds).insetBy(dx: -5, dy: -3), in: ctx)
        case let .blur(rect):
            drawOutline(viewRect(rect), in: ctx)
            for (corner, _) in rect.cornerPairs {
                drawHandle(at: viewPoint(corner), in: ctx)
            }
        }
    }

    private func drawHandle(at point: CGPoint, in ctx: CGContext) {
        let rect = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor(white: 0, alpha: 0.3).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
    }

    /// Dashes over a solid white line, so the outline reads on light and dark captures alike.
    private func drawOutline(_ rect: CGRect, in ctx: CGContext) {
        let line = rect.integral.insetBy(dx: 0.5, dy: 0.5)
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.9).cgColor)
        ctx.stroke(line)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(line)
        ctx.restoreGState()
    }

    // MARK: Coordinates

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        imagePoint(fromView: convert(event.locationInWindow, from: nil))
    }

    private func imagePoint(fromView point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - imageRect.minX) / scale, y: (point.y - imageRect.minY) / scale)
    }

    private func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + point.x * scale, y: imageRect.minY + point.y * scale)
    }

    private func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(from: viewPoint(CGPoint(x: rect.minX, y: rect.minY)), to: viewPoint(CGPoint(x: rect.maxX, y: rect.maxY)))
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), model.imageSize.width),
            y: min(max(point.y, 0), model.imageSize.height)
        )
    }

    /// Six screen points, in image points.
    private var tolerance: CGFloat { 6 / scale }

    private func topmost(at point: CGPoint, kind: Annotation.Kind? = nil) -> Annotation? {
        model.annotations.last { annotation in
            (kind == nil || annotation.kind == kind) && annotation.contains(point, tolerance: tolerance)
        }
    }

    private func handle(at point: CGPoint, for annotation: Annotation) -> Handle? {
        let reach: CGFloat = 9
        switch annotation.shape {
        case let .arrow(from, to):
            if viewPoint(to).distance(to: point) <= reach { return .arrowEnd }
            if viewPoint(from).distance(to: point) <= reach { return .arrowStart }
        case let .blur(rect):
            for (corner, opposite) in rect.cornerPairs where viewPoint(corner).distance(to: point) <= reach {
                return .corner(anchor: opposite)
            }
        case .text:
            break
        }
        return nil
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let location = imagePoint(fromView: point)

        // A click outside the text being typed finishes it; with the text tool, that's all the click does.
        if commitText(), model.tool == .text { return }
        window?.makeFirstResponder(self)

        if let selected = model.selected {
            if let handle = handle(at: point, for: selected) {
                model.beginChange()
                interaction = .resizing(selected.id, handle, original: selected)
                return
            }
            if selected.contains(location, tolerance: tolerance) {
                if event.clickCount == 2, selected.kind == .text {
                    beginEditing(selected)
                } else {
                    beginMoving(selected, from: location)
                }
                return
            }
        }

        switch model.tool {
        case .select:
            if let hit = topmost(at: location) {
                model.select(hit.id)
                if event.clickCount == 2, hit.kind == .text {
                    beginEditing(hit)
                } else {
                    beginMoving(hit, from: location)
                }
            } else {
                model.select(nil)
            }
        case .arrow:
            let start = clamped(location)
            create(Annotation(shape: .arrow(from: start, to: start), color: model.color, size: model.size), anchor: start)
        case .blur:
            let start = clamped(location)
            create(Annotation(shape: .blur(CGRect(origin: start, size: .zero)), color: model.color, size: model.size), anchor: start)
        case .text:
            if let hit = topmost(at: location, kind: .text) {
                // Dragging moves it; a plain click edits it (see mouseUp).
                model.select(hit.id)
                beginMoving(hit, from: location)
            } else {
                let lineHeight = AnnotationRenderer.textSize("", size: model.size).height
                let origin = clamped(CGPoint(x: location.x, y: location.y - lineHeight / 2))
                let annotation = Annotation(shape: .text(origin: origin, string: ""), color: model.color, size: model.size)
                beginEditing(annotation, isNew: true)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let interaction else { return }
        let location = imagePoint(event)
        let straight = event.modifierFlags.contains(.shift)

        switch interaction {
        case let .creating(id, anchor):
            let end = clamped(location)
            model.update(id) { annotation in
                switch annotation.shape {
                case .arrow:
                    annotation.shape = .arrow(from: anchor, to: straight ? Self.snapped(end, from: anchor) : end)
                case .blur:
                    annotation.shape = .blur(CGRect(from: anchor, to: straight ? Self.squared(end, from: anchor) : end))
                case .text:
                    break
                }
            }
        case let .moving(id, start, original):
            let delta = CGVector(dx: location.x - start.x, dy: location.y - start.y)
            model.update(id) { $0 = original.offset(by: delta) }
            NSCursor.closedHand.set()
        case let .resizing(id, handle, original):
            let end = clamped(location)
            model.update(id) { annotation in
                switch (handle, original.shape) {
                case let (.arrowStart, .arrow(_, to)):
                    annotation.shape = .arrow(from: straight ? Self.snapped(end, from: to) : end, to: to)
                case let (.arrowEnd, .arrow(from, _)):
                    annotation.shape = .arrow(from: from, to: straight ? Self.snapped(end, from: from) : end)
                case let (.corner(anchor), .blur):
                    annotation.shape = .blur(CGRect(from: anchor, to: end))
                default:
                    break
                }
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let finished = interaction else { return }
        interaction = nil

        switch finished {
        case let .creating(id, _):
            if let annotation = model.annotation(id), isTooSmall(annotation) {
                model.remove(id)
            } else {
                model.select(id)
            }
            model.endChange()
        case let .moving(id, _, original):
            model.endChange()
            if model.tool == .text, original.kind == .text, model.annotation(id) == original {
                beginEditing(original)
            }
        case .resizing:
            model.endChange()
        }
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        commitText()
        guard let hit = topmost(at: imagePoint(event)) else { return nil }
        model.select(hit.id)

        let menu = NSMenu()
        if hit.kind == .text {
            menu.addItem(withTitle: "Edit Text", action: #selector(editSelectedText), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Delete", action: #selector(delete(_:)), keyEquivalent: "").target = self
        return menu
    }

    private func create(_ annotation: Annotation, anchor: CGPoint) {
        model.select(nil)
        model.beginChange()
        model.insert(annotation)
        interaction = .creating(annotation.id, anchor: anchor)
    }

    private func beginMoving(_ annotation: Annotation, from location: CGPoint) {
        model.beginChange()
        interaction = .moving(annotation.id, start: location, original: annotation)
    }

    /// A click that never became a drag leaves nothing behind.
    private func isTooSmall(_ annotation: Annotation) -> Bool {
        let minimum = 4 / scale
        switch annotation.shape {
        case let .arrow(from, to): return from.distance(to: to) < minimum * 2
        case let .blur(rect): return rect.width < minimum || rect.height < minimum
        case .text: return false
        }
    }

    private static func snapped(_ end: CGPoint, from start: CGPoint) -> CGPoint {
        let length = start.distance(to: end)
        let step = CGFloat.pi / 4
        let angle = (atan2(end.y - start.y, end.x - start.x) / step).rounded() * step
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    private static func squared(_ end: CGPoint, from start: CGPoint) -> CGPoint {
        let side = max(abs(end.x - start.x), abs(end.y - start.y))
        return CGPoint(
            x: start.x + (end.x >= start.x ? side : -side),
            y: start.y + (end.y >= start.y ? side : -side)
        )
    }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseMoved(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    private func cursor(at point: CGPoint) -> NSCursor {
        guard imageRect.insetBy(dx: -12, dy: -12).contains(point) else { return .arrow }
        let location = imagePoint(fromView: point)
        if let selected = model.selected, selected.id != textEditing?.annotation.id {
            if handle(at: point, for: selected) != nil { return .crosshair }
            if selected.contains(location, tolerance: tolerance) {
                return model.tool == .text && selected.kind == .text ? .iBeam : .openHand
            }
        }
        switch model.tool {
        case .select: return topmost(at: location) == nil ? .arrow : .openHand
        case .arrow, .blur: return .crosshair
        case .text: return .iBeam
        }
    }

    private func toolChanged() {
        commitText()
        if let window {
            cursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)).set()
        }
    }

    // MARK: Keyboard

    /// ⌘↩ finishes from anywhere in the window, including while typing text.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)) {
            onDone?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty,
           let key = event.charactersIgnoringModifiers?.lowercased(),
           let tool = AnnotationTool.allCases.first(where: { $0.key == key }) {
            model.tool = tool
            return
        }

        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            model.deleteSelection()
        case kVK_Escape:
            if model.selectedID != nil {
                model.select(nil)
            } else {
                window?.performClose(nil)
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if modifiers.isEmpty, let selected = model.selected, selected.kind == .text {
                beginEditing(selected)
            } else {
                super.keyDown(with: event)
            }
        case kVK_LeftArrow: nudge(CGVector(dx: -step, dy: 0))
        case kVK_RightArrow: nudge(CGVector(dx: step, dy: 0))
        case kVK_UpArrow: nudge(CGVector(dx: 0, dy: -step))
        case kVK_DownArrow: nudge(CGVector(dx: 0, dy: step))
        default:
            super.keyDown(with: event)
        }
    }

    private func nudge(_ delta: CGVector) {
        guard let selected = model.selected else { return }
        model.beginChange()
        model.update(selected.id) { $0 = selected.offset(by: delta) }
        model.endChange()
    }

    // MARK: Edit menu

    @objc func undo(_ sender: Any?) {
        if let textEditing {
            textEditing.undoManager.undo()
        } else {
            model.undo()
        }
    }

    @objc func redo(_ sender: Any?) {
        if let textEditing {
            textEditing.undoManager.redo()
        } else {
            model.redo()
        }
    }

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    @objc func delete(_ sender: Any?) {
        model.deleteSelection()
    }

    @objc private func editSelectedText() {
        if let selected = model.selected { beginEditing(selected) }
    }

    // MARK: Text

    private func beginEditing(_ annotation: Annotation, isNew: Bool = false) {
        commitText()
        guard case let .text(origin, string) = annotation.shape else { return }

        let view = AnnotationTextView(usingTextLayoutManager: false)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.focusRingType = .none
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.textContainerInset = .zero
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.frame.origin = origin
        view.string = string
        style(view, for: annotation)
        view.delegate = self
        view.onCancel = { [weak self] in self?.commitText() }

        textHost.addSubview(view)
        textEditing = TextEditing(view: view, annotation: annotation, isNew: isNew)
        sizeTextView()
        model.select(isNew ? nil : annotation.id)
        window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        overlay.needsDisplay = true
    }

    /// The text view only supplies the caret and selection; the overlay draws the styled text under it.
    private func style(_ view: NSTextView, for annotation: Annotation) {
        let attributes = AnnotationRenderer.textAttributes(for: annotation.size)
            .merging([.foregroundColor: NSColor.clear]) { $1 }
        view.typingAttributes = attributes
        view.insertionPointColor = annotation.color.nsColor
        if let storage = view.textStorage {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
    }

    private func sizeTextView() {
        guard let textEditing else { return }
        let size = AnnotationRenderer.textSize(textEditing.view.string, size: textEditing.annotation.size)
        // A little room after the last character for the caret.
        textEditing.view.frame.size = CGSize(width: size.width + 4, height: size.height)
    }

    /// Applies a color or size picked while typing. Returns false when nothing is being typed.
    private func restyleText() -> Bool {
        guard var editing = textEditing else { return false }
        editing.annotation.color = model.color
        editing.annotation.size = model.size
        textEditing = editing
        style(editing.view, for: editing.annotation)
        sizeTextView()
        overlay.needsDisplay = true
        return true
    }

    /// Turns the text being typed into an annotation. Returns false if nothing was being typed.
    @discardableResult
    func commitText() -> Bool {
        guard let editing = textEditing, case let .text(origin, _) = editing.annotation.shape else { return false }
        textEditing = nil

        var string = editing.view.string
        while let last = string.last, last.isWhitespace || last.isNewline {
            string.removeLast()
        }
        let hadFocus = window?.firstResponder === editing.view
        editing.view.delegate = nil
        editing.view.removeFromSuperview()
        if hadFocus { window?.makeFirstResponder(self) }

        model.beginChange()
        if string.isEmpty {
            if !editing.isNew { model.remove(editing.annotation.id) }
        } else {
            var annotation = editing.annotation
            annotation.shape = .text(origin: origin, string: string)
            if editing.isNew {
                model.insert(annotation)
            } else {
                model.update(annotation.id) { $0 = annotation }
            }
            model.select(annotation.id)
        }
        model.endChange()
        overlay.needsDisplay = true
        return true
    }

    func textDidChange(_ notification: Notification) {
        sizeTextView()
        overlay.needsDisplay = true
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        textEditing?.undoManager
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Return finishes; Shift Return is handled by the text view as a new line.
            commitText()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            commitText()
            return true
        default:
            return false
        }
    }

    // MARK: Helpers

    /// Window captures have transparent corners and bring their own shadow; only opaque captures get one here.
    private static func isOpaqueAtCorner(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return true
        default: break
        }
        guard let corner = image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)) else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn && pixel[3] > 250
    }
}

private final class AnnotationTextView: NSTextView {
    var onCancel: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.shift), [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)) {
            insertNewlineIgnoringFieldEditor(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // The system caret indicator collapses to zero width inside the canvas's scaled text host, so draw the
    // classic caret instead, two screen points wide at any zoom. Overriding this opts out of the indicator.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var caret = rect
        caret.size.width = caretWidth
        super.drawInsertionPoint(in: caret, color: color, turnedOn: flag)
    }

    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var rect = invalidRect
        rect.size.width += caretWidth
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    private var caretWidth: CGFloat {
        2 / max(convert(NSSize(width: 1, height: 1), to: nil).width, 0.01)
    }
}

/// Shows the capture itself; a layer, so dragging annotations never redraws the image.
private final class CanvasImageView: NSView {
    var image: CGImage?
    var castsShadow = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = image
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.masksToBounds = false
        if castsShadow {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.22
            layer.shadowRadius = 14
            layer.shadowOffset = CGSize(width: 0, height: -4)
        }
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = castsShadow ? CGPath(rect: bounds, transform: nil) : nil
    }
}

private final class CanvasOverlayView: NSView {
    weak var canvas: AnnotationCanvasView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        canvas?.drawOverlay()
    }
}

private final class CanvasTextHostView: NSView {
    override var isFlipped: Bool { true }

    /// Only the text view inside takes clicks; everything else falls through to the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

private extension CGRect {
    /// Each corner paired with the one across from it.
    var cornerPairs: [(CGPoint, CGPoint)] {
        let topLeft = CGPoint(x: minX, y: minY)
        let topRight = CGPoint(x: maxX, y: minY)
        let bottomRight = CGPoint(x: maxX, y: maxY)
        let bottomLeft = CGPoint(x: minX, y: maxY)
        return [(topLeft, bottomRight), (topRight, bottomLeft), (bottomRight, topLeft), (bottomLeft, topRight)]
    }
}
