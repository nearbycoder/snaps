import AppKit
import SwiftUI

/// A glass strip that drops down across the top of the screen, over the menu bar.
@MainActor
final class GalleryController {
    private static let stripHeight: CGFloat = 196
    private static let edgeInset: CGFloat = 8

    private var panel: GlassPanel?
    private var clickMonitor: Any?
    private(set) var isVisible = false

    // Re-open on whichever display the cursor moves to.
    private lazy var follower = ScreenFollower { [weak self] _ in
        guard let self, self.isVisible else { return }
        self.hide()
        self.show()
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard !isVisible, let screen = NSScreen.underMouse else { return }
        isVisible = true
        follower.start(on: screen)
        CaptureHistory.shared.pruneMissing()

        // The glass covers the menu bar, but content stays clear of the camera notch.
        let topInset = max(0, screen.safeAreaInsets.top - Self.edgeInset)
        let height = Self.stripHeight + topInset
        let frame = NSRect(
            x: screen.frame.minX + Self.edgeInset,
            y: screen.frame.maxY - height - Self.edgeInset,
            width: screen.frame.width - Self.edgeInset * 2,
            height: height
        )

        let panel = GlassPanel(contentSize: frame.size)
        panel.onCancel = { [weak self] in self?.hide() }
        panel.setContent(
            GalleryView(
                topInset: topInset,
                onClose: { [weak self] in self?.hide() },
                onAnnotate: { [weak self] item in self?.annotate(item) }
            ),
            cornerRadius: 28
        )
        self.panel = panel

        var start = frame
        start.origin.y += 40
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.async { panel.invalidateShadow() }

        // Clicking anywhere outside the strip closes it.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func annotate(_ item: CaptureItem) {
        hide()
        AnnotationEditor.shared.open(item.url, target: {
            CaptureHistory.shared.items.first { $0.id == item.id }?.url
        })
    }

    func hide() {
        guard isVisible, let panel else { return }
        isVisible = false
        follower.stop()
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
        self.panel = nil

        var end = panel.frame
        end.origin.y += 40
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                panel.close()
            }
        })
    }
}

struct GalleryView: View {
    @ObservedObject private var history = CaptureHistory.shared
    @ObservedObject private var settings = AppSettings.shared
    let topInset: CGFloat
    let onClose: () -> Void
    let onAnnotate: (CaptureItem) -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 150)
                .padding(.leading, 20)

            Divider()
                .padding(.vertical, 18)
                .opacity(0.6)

            if history.items.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(history.items) { item in
                            GalleryCard(item: item, onAnnotate: onAnnotate)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
            }
        }
        .padding(.top, topInset)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "photo.stack")
                    .foregroundStyle(.tint)
                Text("Gallery")
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(history.items.isEmpty ? "No captures yet" : "\(history.items.count) recent")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    GlassIconButton(symbol: "xmark", help: "Close (Esc)", action: onClose)
                    GlassIconButton(symbol: "folder", help: "Open save folder") {
                        NSWorkspace.shared.open(settings.saveFolder)
                    }
                    GlassIconButton(symbol: "trash", help: "Clear gallery") {
                        CaptureHistory.shared.clear()
                    }
                    .disabled(history.items.isEmpty)
                }
            }
        }
        .padding(.vertical, 18)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("Your captures will show up here")
                .font(.system(size: 13, weight: .medium))
            Text(emptyHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyHint: String {
        let hints = CaptureMode.allCases.compactMap { mode in
            settings.shortcuts[ShortcutAction(mode)].map { "\($0.displayString) \(mode.title.lowercased())" }
        }
        return hints.isEmpty ? "Use the menu bar icon to take one." : hints.joined(separator: "  ·  ")
    }
}

@MainActor
final class GalleryCardModel: ObservableObject {
    @Published var thumbnail: NSImage?
    @Published var isHovering = false
    @Published var toast: String?
    private var toastTask: Task<Void, Never>?

    func load(_ url: URL) async {
        if thumbnail == nil {
            thumbnail = await Thumbnails.load(url)
        }
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(.snappy) { toast = message }
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.toast = nil }
        }
    }
}

struct GalleryCard: View {
    let item: CaptureItem
    let onAnnotate: (CaptureItem) -> Void
    @StateObject private var model = GalleryCardModel()

    private static let imageHeight: CGFloat = 128
    private var imageWidth: CGFloat {
        min(max(Self.imageHeight * item.aspectRatio, 96), 260)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                thumbnail
                DragSource(
                    fileURL: item.url,
                    image: model.thumbnail,
                    inset: 0,
                    onHover: { model.isHovering = $0 },
                    onClick: copy,
                    onDoubleClick: { onAnnotate(item) },
                    onDragStart: {},
                    onDragEnd: { _ in }
                )
                if model.isHovering {
                    controls
                        .padding(7)
                        .transition(.opacity)
                }
                if let toast = model.toast {
                    Label(toast, systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: imageWidth, height: Self.imageHeight)
            .scaleEffect(model.isHovering ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: model.isHovering)

            Text(item.date, format: .relative(presentation: .named))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 2)
        }
        .task(id: item.url) { await model.load(item.url) }
        .help("Click to copy · Drag to share · Double-click to open")
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.12))
            if let image = model.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: imageWidth, height: Self.imageHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(model.isHovering ? 0.45 : 0.18), lineWidth: model.isHovering ? 1 : 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }

    private var controls: some View {
        VStack {
            HStack {
                Spacer()
                GlassIconButton(symbol: "trash", help: "Remove") {
                    withAnimation(.snappy) { CaptureHistory.shared.remove(item) }
                }
            }
            Spacer()
            HStack {
                Spacer()
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        GlassIconButton(symbol: "pencil", help: "Annotate") { onAnnotate(item) }
                        GlassIconButton(symbol: "doc.on.doc", help: "Copy", action: copy)
                        GlassIconButton(
                            symbol: CaptureStorage.isInCache(item.url) ? "square.and.arrow.down" : "folder",
                            help: CaptureStorage.isInCache(item.url) ? "Save to folder" : "Show in Finder",
                            action: saveAndReveal
                        )
                    }
                }
            }
        }
    }

    private func copy() {
        guard let image = NSImage(contentsOf: item.url) else { return }
        Clipboard.copy(image: image, pngURL: item.url)
        model.showToast("Copied")
    }

    private func saveAndReveal() {
        var url = item.url
        if CaptureStorage.isInCache(url) {
            do {
                url = try CaptureStorage.save(url, into: AppSettings.shared.saveFolder)
                CaptureHistory.shared.updateURL(from: item.url, to: url)
            } catch {
                model.showToast("Couldn’t save")
                return
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
