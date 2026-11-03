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

            TabSwitch(selection: $state.settingsTab)

            // Every tab is laid out, so the window stays the size of the tallest instead of jumping.
            ZStack(alignment: .top) {
                ForEach(SettingsTab.allCases) { tab in
                    let selected = tab == state.settingsTab
                    page(tab)
                        .opacity(selected ? 1 : 0)
                        .allowsHitTesting(selected)
                        .accessibilityHidden(!selected)
                }
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

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: generalPage
        case .recording: recordingPage
        case .shortcuts: shortcutsPage
        }
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            GlassSection("Preview", symbol: "rectangle.on.rectangle") {
                previewOptions
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
                    "Keep in the gallery",
                    detail: "When off, a capture that isn’t saved to a folder is gone once you close it.",
                    isOn: $settings.keepInGallery
                )
                SettingToggle(
                    "Open in the editor",
                    detail: "Every screenshot opens ready to annotate, with the arrow selected.",
                    isOn: $settings.openEditorAfterCapture
                )
                if !settings.showPreview && !settings.keepInGallery && !settings.copyToClipboard
                    && !settings.saveToFolder && !settings.openEditorAfterCapture {
                    Label("With all of these off, captures aren’t kept anywhere.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                Divider().opacity(0.5)
                SettingToggle("Play capture sound", isOn: $settings.playSound)
                SettingToggle(
                    "Include window shadow",
                    detail: "When off, a window capture follows the window’s exact outline.",
                    isOn: $settings.includeWindowShadow
                )
            }

            GlassSection("General", symbol: "gearshape") {
                SettingToggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
            }
        }
    }

    private var recordingPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            GlassSection("Recording", symbol: "record.circle") {
                SettingToggle("Show the pointer", isOn: $settings.recordShowsCursor)
                SettingToggle(
                    "Highlight clicks",
                    detail: "Draws a ring wherever you click.",
                    isOn: $settings.recordHighlightsClicks
                )
                SettingToggle(
                    "Count down from 3",
                    detail: "Click the countdown to start right away.",
                    isOn: $settings.recordCountdown
                )
                Divider().opacity(0.5)
                SettingMenu("Video frame rate", selection: $settings.videoFrameRate) { $0.title }
            }

            GlassSection("Sound", symbol: "waveform") {
                SettingToggle(
                    "Record computer audio",
                    detail: "Whatever your Mac plays, except Snaps’ own sounds.",
                    isOn: $settings.recordSystemAudio
                )
                SettingToggle(
                    "Record microphone",
                    detail: "Snaps asks for access the first time.",
                    isOn: $settings.recordMicrophone
                )
                Text("GIFs never have sound. You can also flip both switches in the bar under the selection.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GlassSection("GIF", symbol: RecordingFormat.gif.symbol) {
                SettingMenu("Frame rate", selection: $settings.gifFrameRate) { $0.title }
                SettingMenu("Size", selection: $settings.gifSize) { $0.title }
                Text("Smaller and slower GIFs load faster in chats and docs. Retina recordings are recorded at 1×.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var shortcutsPage: some View {
        GlassSection("Shortcuts", symbol: "keyboard") {
            ForEach(ShortcutAction.allCases) { mode in
                HStack(spacing: 12) {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 15))
                        .frame(width: 22)
                        .foregroundStyle(mode.recordingFormat == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.red))
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
            Text("Press a recording shortcut again to stop.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// The switch sits on the corner row, whose sentence already says what it turns on.
    private var previewOptions: some View {
        let isOn = settings.showPreview
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                CornerPicker(selection: $settings.corner)
                    .frame(width: 112, height: 72)
                    .disabled(!isOn)
                    .opacity(isOn ? 1 : 0.4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isOn ? "Show previews in the \(settings.corner.title.lowercased()) corner" : "Previews are off")
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(isOn
                        ? "Drag a preview into any app, or press ⌘V: it’s already on your clipboard."
                        : "Captures go to your clipboard, or straight to the editor when it’s on.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Show previews", isOn: $settings.showPreview)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
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
            .disabled(!isOn)
            .opacity(isOn ? 1 : 0.4)
        }
        .animation(.easeInOut(duration: Motion.quick), value: isOn)
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

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, recording, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .shortcuts: "Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .recording: "record.circle"
        case .shortcuts: "keyboard"
        }
    }
}

struct TabSwitch: View {
    @Binding var selection: SettingsTab

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    let selected = tab == selection
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { selection = tab }
                    } label: {
                        Label(tab.title, systemImage: tab.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
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

struct SettingMenu<Value: Hashable & CaseIterable & Identifiable>: View where Value.AllCases: RandomAccessCollection {
    let title: String
    @Binding var selection: Value
    let label: (Value) -> String

    init(_ title: String, selection: Binding<Value>, label: @escaping (Value) -> String) {
        self.title = title
        self._selection = selection
        self.label = label
    }

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(Value.allCases) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
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
