import AppKit
import Combine

@MainActor
final class AppCoordinator {
    private let settings = AppSettings.shared
    private let state = AppState.shared
    private let previews = PreviewManager()
    private let gallery = GalleryController()
    private let settingsWindow = SettingsWindowController()
    private var statusBar: StatusBarController?
    private var cancellables = Set<AnyCancellable>()
    private var isCapturing = false

    func start() {
        CaptureStorage.pruneCache()
        EditMenu.install()

        statusBar = StatusBarController(
            onCapture: { [weak self] mode in self?.capture(mode) },
            onGallery: { [weak self] in self?.toggleGallery() },
            onSettings: { [weak self] in self?.showSettings() }
        )

        Publishers.CombineLatest(settings.$shortcuts, state.$isRecordingShortcut)
            .sink { [weak self] shortcuts, isRecording in
                self?.registerHotKeys(shortcuts, suspended: isRecording)
            }
            .store(in: &cancellables)

        // @Published fires before the value is stored, so re-layout on the next runloop pass.
        settings.$corner
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.previews.layout(animated: true) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.state.refreshPermission() }
            .store(in: &cancellables)

        if !ScreenPermission.isGranted {
            // Let the menu bar item settle, then guide the user to the permission.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                PermissionGuide.shared.start()
            }
        } else if settings.isFirstLaunch {
            showSettings()
        }
    }

    func showSettings() {
        statusBar?.closePopover(restoreFocus: false)
        gallery.hide()
        settingsWindow.show()
    }

    func toggleGallery() {
        statusBar?.closePopover(restoreFocus: true)
        gallery.toggle()
    }

    func capture(_ mode: CaptureMode) {
        guard !isCapturing else { return }
        isCapturing = true
        statusBar?.closePopover(restoreFocus: true)
        gallery.hide()

        Task { @MainActor in
            defer { isCapturing = false }

            previews.setHidden(true)
            // Give the popover a moment to disappear so it isn't in the shot.
            try? await Task.sleep(for: .milliseconds(150))
            let captured = await ScreenCapturer.capture(mode, settings: settings)
            previews.setHidden(false)

            guard var url = captured, let image = NSImage(contentsOf: url) else {
                state.refreshPermission()
                return
            }

            if settings.saveToFolder {
                do {
                    url = try CaptureStorage.save(url, into: settings.saveFolder)
                } catch {
                    NSLog("Snaps: failed to save capture: \(error)")
                }
            }
            if settings.copyToClipboard {
                Clipboard.copy(image: image, pngURL: url)
            }
            CaptureHistory.shared.add(url: url, size: image.size)
            let preview = previews.show(image: image, fileURL: url)
            if settings.openEditorAfterCapture {
                preview.annotate()
            }
        }
    }

    private func perform(_ action: ShortcutAction) {
        if let mode = action.captureMode {
            capture(mode)
        } else {
            toggleGallery()
        }
    }

    private func registerHotKeys(_ shortcuts: [ShortcutAction: Shortcut], suspended: Bool) {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        // While recording a new shortcut, keep existing ones from firing.
        guard !suspended else { return }

        var unavailable = Set<ShortcutAction>()
        for action in ShortcutAction.allCases {
            guard let shortcut = shortcuts[action] else { continue }
            let ok = center.register(id: action.hotKeyID, shortcut: shortcut) { [weak self] in
                self?.perform(action)
            }
            if !ok { unavailable.insert(action) }
        }
        state.unavailableShortcuts = unavailable
    }
}
