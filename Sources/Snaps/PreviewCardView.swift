import AppKit
import SwiftUI

struct PreviewActions {
    var close: () -> Void
    var togglePin: () -> Void
    var copy: () -> Void
    var save: () -> Void
    var open: () -> Void
    var annotate: () -> Void
    var hover: (Bool) -> Void
    var dragStarted: () -> Void
    var dragEnded: (Bool) -> Void
}

struct PreviewCardView: View {
    @ObservedObject var model: PreviewModel
    let imageArea: NSSize
    let imageSize: NSSize
    let actions: PreviewActions

    private let innerRadius = PreviewController.cornerRadius - PreviewController.padding

    var body: some View {
        ZStack {
            thumbnail
                .padding(PreviewController.padding)

            // Handles hover, drag-out and double-click across the whole card.
            DragSource(
                fileURL: model.fileURL,
                image: model.image,
                inset: PreviewController.padding,
                onHover: actions.hover,
                onClick: nil,
                onDoubleClick: actions.annotate,
                onDragStart: actions.dragStarted,
                onDragEnd: actions.dragEnded
            )

            if model.isHovering {
                controls
                    .padding(PreviewController.padding + 6)
                    .transition(.opacity)
            }

            if let toast = model.toast {
                Label(toast, systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.isHovering)
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.12))
            Image(nsImage: model.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: imageSize.width, height: imageSize.height)
        }
        .frame(width: imageArea.width, height: imageArea.height)
        .clipShape(RoundedRectangle(cornerRadius: innerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                GlassIconButton(symbol: "xmark", help: "Close", action: actions.close)
                Spacer()
                GlassIconButton(
                    symbol: model.isPinned ? "pin.fill" : "pin",
                    help: model.isPinned ? "Unpin" : "Keep on screen",
                    action: actions.togglePin
                )
            }
            Spacer()
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    GlassIconButton(symbol: "pencil", help: "Annotate", action: actions.annotate)
                    GlassIconButton(symbol: "doc.on.doc", help: "Copy to clipboard", action: actions.copy)
                    GlassIconButton(
                        symbol: model.isSaved ? "folder" : "square.and.arrow.down",
                        help: model.isSaved ? "Show in Finder" : "Save to folder",
                        action: actions.save
                    )
                    GlassIconButton(symbol: "arrow.up.forward.app", help: "Open", action: actions.open)
                }
            }
        }
    }
}

struct GlassIconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
    }
}

/// AppKit view that acts as a file drag source and tracks hover even while the app is inactive.
struct DragSource: NSViewRepresentable {
    let fileURL: URL
    let image: NSImage?
    /// Inset from the view's edges to the displayed image, used to position the drag image.
    let inset: CGFloat
    let onHover: (Bool) -> Void
    let onClick: (() -> Void)?
    let onDoubleClick: () -> Void
    let onDragStart: () -> Void
    let onDragEnd: (Bool) -> Void
    /// When set, the drag image is a square of this size under the cursor instead of the image fitted to the view.
    var dragImageSize: CGFloat? = nil

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.fileURL = fileURL
        view.image = image
        view.inset = inset
        view.onHover = onHover
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
        view.dragImageSize = dragImageSize
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var fileURL: URL?
    var image: NSImage?
    var inset: CGFloat = 0
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: ((Bool) -> Void)?
    var dragImageSize: CGFloat?

    private var mouseDownEvent: NSEvent?
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        if event.clickCount == 2 {
            mouseDownEvent = nil
            onDoubleClick?()
        }
    }

    override func mouseUp(with event: NSEvent) {
        // A press that never turned into a drag is a click.
        if mouseDownEvent != nil, event.clickCount == 1 {
            onClick?()
        }
        mouseDownEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let fileURL else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) > 3 else { return }
        mouseDownEvent = nil

        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(dragFrame(at: convert(down.locationInWindow, from: nil)), contents: image)
        let session = beginDraggingSession(with: [item], event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        onDragStart?()
    }

    /// The image's displayed rect within the card, so the drag image lines up with the thumbnail.
    private func dragFrame(at point: NSPoint) -> NSRect {
        if let side = dragImageSize {
            return NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        }
        guard let size = image?.size, size.width > 0, size.height > 0 else { return bounds }
        let inset = bounds.insetBy(dx: inset, dy: inset)
        let scale = min(inset.width / size.width, inset.height / size.height, 1)
        let w = size.width * scale
        let h = size.height * scale
        return NSRect(x: inset.midX - w / 2, y: inset.midY - h / 2, width: w, height: h)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnd?(operation != [])
    }
}
