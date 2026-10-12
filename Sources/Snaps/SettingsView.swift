import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            hosting.sizingOptions = [.preferredContentSize]

            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.title = "Snaps Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        AppState.shared.refreshPermission()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var state = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if !state.hasScreenPermission {
                PermissionBanner()
            }

            GlassSection("Shortcuts", symbol: "keyboard") {
                ForEach(ShortcutAction.allCases) { mode in
                    HStack(spacing: 12) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 15))
                            .frame(width: 22)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mode.title).font(.system(size: 13, weight: .medium))
                            Text(mode.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShortcutRecorder(
                            shortcut: Binding(
                                get: { settings.shortcuts[mode] },
                                set: { settings.setShortcut($0, for: mode) }
                            ),
                            isUnavailable: state.unavailableShortcuts.contains(mode)
                        )
                    }
                }
            }

            GlassSection("Preview", symbol: "rectangle.on.rectangle") {
                HStack(spacing: 16) {
                    CornerPicker(selection: $settings.corner)
                        .frame(width: 112, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Show previews in the \(settings.corner.title.lowercased()) corner")
                            .font(.system(size: 13, weight: .medium))
                        Text("Drag a preview into any app, or press ⌘V: it’s already on your clipboard.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider().opacity(0.5)
                HStack {
                    Text("Dismiss after").font(.system(size: 13))
                    Spacer()
                    Picker("Dismiss after", selection: $settings.previewDuration) {
                        ForEach(PreviewDuration.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            GlassSection("After Capture", symbol: "sparkles") {
                SettingToggle("Copy to clipboard", isOn: $settings.copyToClipboard)
                SettingToggle("Save to folder", isOn: $settings.saveToFolder)
                if settings.saveToFolder {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                        Text((settings.saveFolder.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
                SettingToggle(
                    "Open in the editor",
                    detail: "Every capture opens ready to annotate, with the arrow selected.",
                    isOn: $settings.openEditorAfterCapture
                )
                Divider().opacity(0.5)
                SettingToggle("Play capture sound", isOn: $settings.playSound)
                SettingToggle("Include window shadow", isOn: $settings.includeWindowShadow)
            }

            GlassSection("General", symbol: "gearshape") {
                SettingToggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            VisualEffectBackground().ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("Snaps").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Capture it. It’s on your clipboard. Drag it anywhere.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.saveFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolder = url
        }
    }
}

struct GlassSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }
}

struct SettingToggle: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    var isUnavailable = false

    @StateObject private var recorder = ShortcutRecorderModel()

    var body: some View {
        HStack(spacing: 6) {
            if isUnavailable && !recorder.isRecording {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("This shortcut is already used by another app")
            }
            Button(action: toggleRecording) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(recorder.isRecording || shortcut == nil ? .secondary : .primary)
                    .frame(minWidth: 108)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(
                recorder.isRecording ? .regular.tint(.accentColor.opacity(0.35)).interactive() : .regular.interactive(),
                in: .capsule
            )

            Button {
                shortcut = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Clear shortcut")
            .opacity(shortcut != nil && !recorder.isRecording ? 1 : 0)
            .disabled(shortcut == nil || recorder.isRecording)
        }
        .onDisappear { recorder.stop() }
    }

    private var label: String {
        if recorder.isRecording { return "Type shortcut…" }
        return shortcut?.displayString ?? "Record Shortcut"
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            recorder.start { shortcut = $0 }
        }
    }
}

/// Captures the next key combo typed while the settings window is focused.
@MainActor
final class ShortcutRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?

    func start(onRecord: @escaping (Shortcut?) -> Void) {
        stop()
        isRecording = true
        AppState.shared.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event, onRecord: onRecord)
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if isRecording {
            isRecording = false
            AppState.shared.isRecordingShortcut = false
        }
    }

    private func handle(_ event: NSEvent, onRecord: (Shortcut?) -> Void) {
        let modifiers = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        let keyCode = Int(event.keyCode)

        if keyCode == kVK_Escape && modifiers.isEmpty {
            stop()
            return
        }
        if (keyCode == kVK_Delete || keyCode == kVK_ForwardDelete) && modifiers.isEmpty {
            onRecord(nil)
            stop()
            return
        }
        // Require a real modifier (not just Shift) unless it's a function key.
        guard !modifiers.subtracting(.shift).isEmpty || Shortcut.isFunctionKey(event.keyCode) else {
            NSSound.beep()
            return
        }
        onRecord(Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers))
        stop()
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
