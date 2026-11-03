import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var previousApp: NSRunningApplication?
    private var recordingStatus: RecordingStatus = .idle
    /// While recording, clicking the menu bar item stops it instead of opening the popover.
    var onRecordingClick: (() -> Void)?

    init(
        onCapture: @escaping (CaptureMode) -> Void,
        onRecord: @escaping (RecordingFormat) -> Void,
        onGallery: @escaping () -> Void,
        onSettings: @escaping () -> Void
    ) {
        super.init()

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
        }
        showIdleIcon()

        let hosting = NSHostingController(rootView: MenuView(
            onCapture: onCapture,
            onRecord: onRecord,
            onGallery: onGallery,
            onSettings: onSettings
        ))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
    }

    /// Turns the menu bar item into a stop button with the recording time, and back.
    func setRecordingStatus(_ status: RecordingStatus) {
        guard status != recordingStatus else { return }
        recordingStatus = status
        guard let button = item.button else { return }
        switch status {
        case .idle:
            showIdleIcon()
        case .countdown, .finishing:
            item.length = NSStatusItem.squareLength
            button.title = ""
            button.toolTip = status == .finishing ? "Saving the recording" : "Starting to record"
            setSymbol(status == .finishing ? "hourglass" : "record.circle", tint: .systemRed)
        case let .recording(clock, paused):
            item.length = NSStatusItem.variableLength
            closePopover(restoreFocus: false)
            setSymbol(paused ? "pause.circle.fill" : "stop.circle.fill", tint: paused ? .systemOrange : .systemRed)
            button.attributedTitle = NSAttributedString(string: " " + clock, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium),
                .baselineOffset: 0.5,
            ])
            button.toolTip = "Stop recording"
        }
    }

    private func showIdleIcon() {
        item.length = NSStatusItem.squareLength
        item.button?.title = ""
        item.button?.toolTip = "Snaps"
        setSymbol("camera.viewfinder", tint: nil)
    }

    private var currentSymbol: String?

    private func setSymbol(_ name: String, tint: NSColor?) {
        guard let button = item.button, name != currentSymbol else { return }
        currentSymbol = name
        var image = NSImage(systemSymbolName: name, accessibilityDescription: "Snaps")
        if let tint {
            image = image?.withSymbolConfiguration(.init(paletteColors: [tint]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        button.image = image
    }

    @objc private func togglePopover() {
        if recordingStatus != .idle {
            onRecordingClick?()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }
        AppState.shared.refreshPermission()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// The app that was frontmost before the popover opened, while it's open.
    var appBeforePopover: NSRunningApplication? {
        popover.isShown ? previousApp : nil
    }

    /// Closes the popover; optionally hands focus back to the previous app so ⌘V lands there.
    func closePopover(restoreFocus: Bool) {
        guard popover.isShown else { return }
        popover.close()
        if restoreFocus {
            previousApp?.activate()
        }
    }
}

struct MenuView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var state = AppState.shared
    let onCapture: (CaptureMode) -> Void
    let onRecord: (RecordingFormat) -> Void
    let onGallery: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Snaps")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(CaptureMode.allCases) { mode in
                        CaptureTile(mode: mode, shortcut: settings.shortcuts[ShortcutAction(mode)]) {
                            onCapture(mode)
                        }
                    }
                }
            }

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(RecordingFormat.allCases) { format in
                        RecordTile(format: format, shortcut: settings.shortcuts[ShortcutAction(format)]) {
                            onRecord(format)
                        }
                    }
                }
            }

            Button(action: onGallery) {
                HStack(spacing: 10) {
                    Image(systemName: ShortcutAction.gallery.symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(.tint)
                    Text("Gallery")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(settings.shortcuts[.gallery]?.displayString ?? "")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(.rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
            .help(ShortcutAction.gallery.detail)

            if !state.hasScreenPermission {
                PermissionBanner()
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preview corner")
                        .font(.system(size: 12, weight: .medium))
                    Text(settings.corner.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CornerPicker(selection: $settings.corner)
                    .frame(width: 68, height: 44)
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))

            HStack {
                Button(action: onSettings) {
                    Label("Settings…", systemImage: "gearshape")
                }
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Label("Quit", systemImage: "power")
                }
            }
            .buttonStyle(.glass)
        }
        .padding(16)
        .frame(width: 340)
    }
}

struct CaptureTile: View {
    let mode: CaptureMode
    let shortcut: Shortcut?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 22, weight: .regular))
                    .frame(height: 26)
                Text(mode.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(shortcut?.displayString ?? "—")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .help(mode.detail)
    }
}

struct RecordTile: View {
    let format: RecordingFormat
    let shortcut: Shortcut?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: format.symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(.red)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(format.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(shortcut?.displayString ?? "—")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        .help(format.detail)
    }
}

struct PermissionBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Screen Recording access needed")
                    .font(.system(size: 12, weight: .semibold))
                Text("Snaps will open System Settings and show you where to drag it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Set Up Screen Recording") {
                    PermissionGuide.shared.start()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .rect(cornerRadius: 16))
    }
}

/// A miniature screen; click a corner to choose where previews appear.
struct CornerPicker: View {
    @Binding var selection: ScreenCorner

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let inset = max(3, size.height * 0.1)
            let thumb = CGSize(width: size.width * 0.3, height: size.height * 0.28)
            let radius = size.height * 0.16

            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.primary.opacity(0.05))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(.primary.opacity(0.2), lineWidth: 1)
                    }

                ForEach(ScreenCorner.allCases) { corner in
                    let selected = corner == selection
                    Button {
                        withAnimation(.snappy) { selection = corner }
                    } label: {
                        RoundedRectangle(cornerRadius: max(2, radius * 0.45), style: .continuous)
                            .fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.14)))
                            .frame(width: thumb.width, height: thumb.height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(corner.title)
                    .position(
                        x: corner.isLeft ? inset + thumb.width / 2 : size.width - inset - thumb.width / 2,
                        y: corner.isTop ? inset + thumb.height / 2 : size.height - inset - thumb.height / 2
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview corner")
    }
}
