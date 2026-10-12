import AppKit
import Combine
import SwiftUI

/// A capture as the editor left it: the original pixels plus annotations that can still be moved or removed.
struct EditorSession {
    let image: CGImage
    let imageSize: CGSize
    var annotations: [Annotation]
    /// What the file on disk currently shows.
    var applied: [Annotation]
}

/// Opens captures in annotation windows and keeps their annotations editable while Snaps runs.
@MainActor
final class AnnotationEditor {
    static let shared = AnnotationEditor()

    struct Update {
        let url: URL
        let image: NSImage
    }

    /// Fires whenever annotations are written back into a capture file.
    let didUpdate = PassthroughSubject<Update, Never>()

    private var windows: [EditorWindowController] = []
    private var sessions: [URL: EditorSession] = [:]
    private var sessionOrder: [URL] = []
    private let sessionLimit = 12

    /// Opens `url` for annotating, or brings its window forward if it's already open.
    /// - Parameters:
    ///   - target: where the capture lives when the editor writes to it, in case it moved meanwhile.
    ///   - onClose: called when the window closes; `copied` is true if Done put the result on the clipboard.
    @discardableResult
    func open(_ url: URL, target: (() -> URL?)? = nil, onClose: ((_ copied: Bool) -> Void)? = nil) -> Bool {
        if let existing = windows.first(where: { $0.url == url }) {
            existing.focus()
            return true
        }
        guard let session = sessions[url] ?? Self.load(url) else {
            NSSound.beep()
            return false
        }

        let controller = EditorWindowController(url: url, session: session) { target?() ?? url }
        controller.onClose = { [weak self, weak controller] copied, session, finalURL in
            guard let self, let controller else { return }
            self.windows.removeAll { $0 === controller }
            self.remember(session, for: finalURL)
            onClose?(copied)
        }
        windows.append(controller)
        controller.show()
        return true
    }

    private func remember(_ session: EditorSession, for url: URL) {
        sessionOrder.removeAll { $0 == url }
        guard !session.annotations.isEmpty || !session.applied.isEmpty else {
            sessions[url] = nil
            return
        }
        sessions[url] = session
        sessionOrder.append(url)
        while sessionOrder.count > sessionLimit {
            sessions[sessionOrder.removeFirst()] = nil
        }
    }

    private static func load(_ url: URL) -> EditorSession? {
        guard let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data),
              let image = rep.cgImage,
              rep.size.width > 0, rep.size.height > 0
        else { return nil }
        return EditorSession(image: image, imageSize: rep.size, annotations: [], applied: [])
    }
}

@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    let url: URL
    var onClose: ((_ copied: Bool, _ session: EditorSession, _ url: URL) -> Void)?

    private let target: () -> URL
    private let model: EditorModel
    private let canvas: AnnotationCanvasView
    private var window: NSWindow?
    private var previousApp: NSRunningApplication?
    private var copiedOnClose = false

    init(url: URL, session: EditorSession, target: @escaping () -> URL) {
        self.url = url
        self.target = target
        model = EditorModel(session: session)
        canvas = AnnotationCanvasView(model: model)
        super.init()
        canvas.onCopy = { [weak self] in self?.copy() }
        canvas.onDone = { [weak self] in self?.done() }
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
        // An empty toolbar makes the title bar tall enough to hold the tools beside the window buttons.
        window.toolbar = NSToolbar(identifier: "AnnotationEditor")
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 820, height: 480)
        window.delegate = self
        window.setFrame(initialFrame(), display: false)

        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        let hosting = NSHostingView(rootView: EditorView(
            model: model,
            canvas: canvas,
            titlebarHeight: titlebarHeight,
            onCopy: { [weak self] in self?.copy() },
            onDone: { [weak self] in self?.done() }
        ))
        hosting.sizingOptions = []
        window.contentView = hosting
        self.window = window

        focus()
        window.makeFirstResponder(canvas)
        Task { await model.prepareBlur() }
    }

    func focus() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // After a hotkey capture macOS may not let Snaps activate; show the window on top anyway.
        window?.orderFrontRegardless()
    }

    /// Centered on the display under the cursor, showing the capture at up to its own size.
    private func initialFrame() -> NSRect {
        let visible = NSScreen.underMouse?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let chrome = NSSize(width: 48, height: 52 + 32)
        let room = NSSize(width: visible.width * 0.88 - chrome.width, height: visible.height * 0.88 - chrome.height)
        let image = model.imageSize
        let scale = min(room.width / image.width, room.height / image.height, 1)
        let width = min(max((image.width * scale).rounded() + chrome.width, 820), visible.width)
        let height = min(max((image.height * scale).rounded() + chrome.height, 480), visible.height)
        return NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height).integral
    }

    // MARK: Actions

    /// Writes pending annotations into the capture file. Returns false if that failed.
    private func apply() -> Bool {
        canvas.commitText()
        guard model.hasUnappliedChanges else { return true }

        let url = target()
        guard let flattened = AnnotationRenderer.flatten(
            model.image,
            pointSize: model.imageSize,
            annotations: model.annotations,
            blurred: model.blurredForExport()
        ), let data = AnnotationRenderer.pngData(flattened, pointSize: model.imageSize) else {
            model.showToast("Couldn’t save")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Snaps: failed to save annotations: \(error)")
            model.showToast("Couldn’t save")
            return false
        }

        model.markApplied()
        Thumbnails.evict(url)
        AnnotationEditor.shared.didUpdate.send(.init(url: url, image: NSImage(cgImage: flattened, size: model.imageSize)))
        return true
    }

    private func copy() {
        guard apply() else { return }
        let url = target()
        guard let image = NSImage(contentsOf: url) else {
            model.showToast("Couldn’t copy")
            return
        }
        Clipboard.copy(image: image, pngURL: url)
        model.showToast("Copied")
    }

    private func done() {
        canvas.commitText()
        let changed = model.hasUnappliedChanges
        guard apply() else { return }
        if changed, AppSettings.shared.copyToClipboard {
            let url = target()
            if let image = NSImage(contentsOf: url) {
                Clipboard.copy(image: image, pngURL: url)
                copiedOnClose = true
            }
        }
        window?.close()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Closing without Done keeps the annotations as a draft for next time.
        canvas.commitText()
        let closing = window
        let othersVisible = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
        onClose?(copiedOnClose, model.session, target())
        // Hand focus back, so ⌘V lands in the app the capture was meant for.
        if !othersVisible {
            previousApp?.activate()
        }
    }
}

@MainActor
final class EditorModel: ObservableObject {
    let image: CGImage
    let imageSize: CGSize
    private(set) var blurred: CGImage?

    @Published var tool: AnnotationTool = .arrow {
        didSet {
            guard tool != oldValue else { return }
            onToolChange?()
            // Picking a drawing tool means drawing, not dragging whatever happened to be selected.
            if tool != .select { select(nil) }
        }
    }
    @Published private(set) var color: AnnotationColor
    @Published private(set) var size: StrokeSize
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isEmpty = true
    @Published private(set) var selectionKind: Annotation.Kind?
    @Published private(set) var toast: String?

    private(set) var annotations: [Annotation] {
        didSet { annotationsChanged() }
    }
    private(set) var selectedID: UUID?
    private var applied: [Annotation]

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var pending: [Annotation]?
    private var toastTask: Task<Void, Never>?

    /// Hooks for the canvas.
    var onDisplay: (() -> Void)?
    var onToolChange: (() -> Void)?
    /// Returns true when the canvas applied a new color or size to text being typed.
    var onStyleChange: (() -> Bool)?
    var onFinishEditing: (() -> Void)?

    private enum Key {
        static let color = "annotationColor"
        static let size = "annotationSize"
    }

    init(session: EditorSession) {
        image = session.image
        imageSize = session.imageSize
        annotations = session.annotations
        applied = session.applied
        let defaults = UserDefaults.standard
        color = AnnotationColor(rawValue: defaults.string(forKey: Key.color) ?? "") ?? .red
        size = StrokeSize(rawValue: defaults.object(forKey: Key.size) as? Int ?? StrokeSize.medium.rawValue) ?? .medium
        isEmpty = annotations.isEmpty
    }

    var session: EditorSession {
        EditorSession(image: image, imageSize: imageSize, annotations: annotations, applied: applied)
    }

    var selected: Annotation? { selectedID.flatMap(annotation) }
    var hasUnappliedChanges: Bool { annotations != applied }

    /// Color and size mean nothing to blur, so the pickers rest while it's in play.
    var acceptsStyle: Bool { selectionKind.map { $0 != .blur } ?? (tool != .blur) }

    func annotation(_ id: UUID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    // MARK: Blur

    /// Renders the blurred copy off the main thread, after the window is already on screen.
    func prepareBlur() async {
        guard blurred == nil else { return }
        let image = image
        let size = imageSize
        let result = await Task.detached(priority: .userInitiated) {
            AnnotationRenderer.makeBlurred(image, pointSize: size)
        }.value
        if blurred == nil { blurred = result }
        onDisplay?()
    }

    func blurredForExport() -> CGImage? {
        if blurred == nil, annotations.contains(where: { $0.kind == .blur }) {
            blurred = AnnotationRenderer.makeBlurred(image, pointSize: imageSize)
        }
        return blurred
    }

    // MARK: Editing

    /// Changes between `beginChange` and `endChange` become one undo step.
    func beginChange() {
        if pending == nil { pending = annotations }
    }

    func endChange() {
        guard let before = pending else { return }
        pending = nil
        guard before != annotations else { return }
        undoStack.append(before)
        redoStack.removeAll()
        historyChanged()
    }

    func insert(_ annotation: Annotation) {
        annotations.append(annotation)
    }

    func update(_ id: UUID, _ change: (inout Annotation) -> Void) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        change(&annotations[index])
    }

    func remove(_ id: UUID) {
        annotations.removeAll { $0.id == id }
    }

    func select(_ id: UUID?) {
        guard id != selectedID else { return }
        selectedID = id
        let selected = self.selected
        if selectionKind != selected?.kind { selectionKind = selected?.kind }
        // The pickers show the selection's style, so a change applies from where it is.
        if let selected, selected.kind != .blur {
            if color != selected.color { color = selected.color }
            if size != selected.size { size = selected.size }
        }
        onDisplay?()
    }

    func deleteSelection() {
        guard let selectedID else { return }
        beginChange()
        remove(selectedID)
        endChange()
    }

    func undo() {
        onFinishEditing?()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        historyChanged()
    }

    func redo() {
        onFinishEditing?()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        historyChanged()
    }

    func setColor(_ color: AnnotationColor) {
        self.color = color
        UserDefaults.standard.set(color.rawValue, forKey: Key.color)
        if onStyleChange?() == true { return }
        restyleSelection { $0.color = color }
    }

    func setSize(_ size: StrokeSize) {
        self.size = size
        UserDefaults.standard.set(size.rawValue, forKey: Key.size)
        if onStyleChange?() == true { return }
        restyleSelection { $0.size = size }
    }

    func markApplied() {
        applied = annotations
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func restyleSelection(_ change: (inout Annotation) -> Void) {
        guard let selected, selected.kind != .blur else { return }
        beginChange()
        update(selected.id, change)
        endChange()
    }

    private func annotationsChanged() {
        if let selectedID, annotation(selectedID) == nil { select(nil) }
        if isEmpty != annotations.isEmpty { isEmpty = annotations.isEmpty }
        onDisplay?()
    }

    private func historyChanged() {
        let undoable = !undoStack.isEmpty
        let redoable = !redoStack.isEmpty
        if canUndo != undoable { canUndo = undoable }
        if canRedo != redoable { canRedo = redoable }
    }
}

/// Snaps has no visible menu bar, but its main menu still routes ⌘Z, ⌘C, ⌘V and ⌘W to the focused window.
@MainActor
enum EditMenu {
    private static let editID = NSUserInterfaceItemIdentifier("dev.nearby.Snaps.edit")

    static func install() {
        // AppKit usually builds a bare app menu on its own; add to it rather than replace it.
        let main = NSApp.mainMenu ?? NSMenu()
        guard !main.items.contains(where: { $0.identifier == editID }) else { return }
        if main.items.isEmpty {
            let appItem = NSMenuItem()
            appItem.submenu = NSMenu(title: "Snaps")
            main.addItem(appItem)
        }

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.identifier = editID
        editItem.submenu = edit
        main.addItem(editItem)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
