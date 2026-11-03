import AppKit
import Combine

@MainActor
final class AppCoordinator {
    private let settings = AppSettings.shared
    private let state = AppState.shared
    private let previews = PreviewManager()
    private let gallery = GalleryController()
    private let settingsWindow = SettingsWindowController()
    private lazy var recording = RecordingController(previews: previews)
    private var statusBar: StatusBarController?
    private var cancellables = Set<AnyCancellable>()
    private var isCapturing = false

    func start() {
        CaptureStorage.pruneCache()
        EditMenu.install()

        statusBar = StatusBarController(
            onCapture: { [weak self] mode in self?.capture(mode) },
            onRecord: { [weak self] format in self?.record(format) },
            onGallery: { [weak self] in self?.toggleGallery() },
            onSettings: { [weak self] in self?.showSettings() }
        )
        statusBar?.onRecordingClick = { [weak self] in self?.recording.toggle(.video) }
        recording.onStatusChange = { [weak self] status in self?.statusBar?.setRecordingStatus(status) }
        VideoEditor.shared.onNewRecording = { [weak self] url, poster, info in
            guard let self, self.settings.showPreview else { return }
            self.previews.show(image: poster, fileURL: url, recording: info)
        }

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

        // Captures kept nowhere else go away once nothing on screen shows them.
        previews.onRelease = { [weak self] url in self?.discardWhenUnused(url) }
        AnnotationEditor.shared.didClose
            .sink { [weak self] url in self?.discardWhenUnused(url) }
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
        // Not over the screenshot picker, where an area drag could catch it.
        guard !isCapturing else { return }
        statusBar?.closePopover(restoreFocus: true)
        gallery.toggle()
    }

    /// Starts recording, or stops the recording in progress.
    func record(_ format: RecordingFormat) {
        // The screenshot picker is up; two pickers at once fight over the cursor and Esc.
        guard !isCapturing else { return }
        // The picker takes focus itself and hands it back afterwards; activating the old app now would race it.
        let returnTo = statusBar?.appBeforePopover
        statusBar?.closePopover(restoreFocus: false)
        gallery.hide()
        recording.toggle(format, returnTo: returnTo)
    }

    func capture(_ mode: CaptureMode) {
        // Screenshots are fine mid-recording, but not over the picker or the countdown.
        guard !isCapturing, recording.phase == .idle || recording.phase == .recording else { return }
        guard ScreenPermission.isGranted else {
            // The picker would cover the system's permission prompt.
            PermissionGuide.shared.start()
            return
        }
        isCapturing = true
        let galleryWasOpen = gallery.isVisible
        let hadPopover = statusBar?.closePopover(restoreFocus: true) ?? false
        gallery.hide()

        Task { @MainActor in
            defer { isCapturing = false }

            previews.setHidden(true)
            if hadPopover {
                // Give the popover a moment to disappear so it isn't in the shot.
                try? await Task.sleep(for: .milliseconds(150))
            }

            let target: CaptureTarget?
            switch mode {
            case .area, .window:
                target = await CaptureOverlay.pick(allowsArea: mode == .area)
                if case .area = target {
                    // Let the window server take the overlay off screen before the pixels are read.
                    try? await Task.sleep(for: .milliseconds(80))
                }
            case .screen:
                if galleryWasOpen {
                    // The gallery takes 0.2 s to fade out.
                    try? await Task.sleep(for: .milliseconds(240))
                } else if !hadPopover {
                    // Same for hidden previews.
                    try? await Task.sleep(for: .milliseconds(80))
                }
                target = NSScreen.underMouse.map { .area($0.frame) }
            }

            guard let target else {
                previews.setHidden(false)
                return
            }
            let captured = await ScreenCapturer.capture(target, settings: settings)
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
            let item = settings.keepInGallery ? CaptureHistory.shared.add(url: url, size: image.size) : nil

            let preview = settings.showPreview ? previews.show(image: image, fileURL: url) : nil
            if settings.openEditorAfterCapture {
                if let preview {
                    preview.annotate()
                } else {
                    let captureURL = url
                    AnnotationEditor.shared.open(url, target: {
                        guard let item else { return captureURL }
                        return CaptureHistory.shared.items.first { $0.id == item.id }?.url
                    })
                }
            }
            discardWhenUnused(url)
        }
    }

    /// A capture that's neither in the gallery nor saved to a folder lives only in the cache. Once no
    /// preview or editor shows it, it's deleted, after a grace period in case an app is still reading a
    /// copy that was dragged out of the preview.
    private func discardWhenUnused(_ url: URL) {
        // Recordings go on the clipboard as files, so deleting one would break pasting it.
        // Unsaved ones are left to the weekly cache cleanup instead.
        guard !CaptureKind(url).isRecording else { return }
        func isUnused() -> Bool {
            CaptureStorage.isInCache(url)
                && !CaptureHistory.shared.contains(url)
                && !previews.isShowing(url)
                && !previews.wasHandedOut(url)
                && !AnnotationEditor.shared.isOpen(url)
        }
        guard isUnused() else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            guard isUnused() else { return }
            AnnotationEditor.shared.forget(url)
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func perform(_ action: ShortcutAction) {
        if let mode = action.captureMode {
            capture(mode)
        } else if let format = action.recordingFormat {
            record(format)
        } else {
            toggleGallery()
        }
    }

    private func registerHotKeys(_ shortcuts: [ShortcutAction: Shortcut], suspended: Bool) {
        let center = HotKeyCenter.shared
        // Only the shortcuts: the screenshot picker's temporary Esc hot key must survive this.
        for action in ShortcutAction.allCases { center.unregister(id: action.hotKeyID) }
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
