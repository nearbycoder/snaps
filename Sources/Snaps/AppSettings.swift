import AppKit
import Combine
import ServiceManagement

enum CaptureMode: String, CaseIterable, Identifiable, Codable {
    case area, window, screen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: "Area"
        case .window: "Window"
        case .screen: "Full Screen"
        }
    }

    var detail: String {
        switch self {
        case .area: "Drag to select a region"
        case .window: "Click a window to capture it"
        case .screen: "The display under your cursor"
        }
    }

    var symbol: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .screen: "display"
        }
    }

}

/// Everything that can be bound to a global shortcut.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case area, window, screen, gallery

    init(_ mode: CaptureMode) {
        self = ShortcutAction(rawValue: mode.rawValue)!
    }

    var id: String { rawValue }
    var captureMode: CaptureMode? { CaptureMode(rawValue: rawValue) }

    var title: String { captureMode?.title ?? "Gallery" }
    var detail: String { captureMode?.detail ?? "Browse recent captures across the top of the screen" }
    var symbol: String { captureMode?.symbol ?? "photo.stack" }

    var hotKeyID: UInt32 {
        switch self {
        case .area: 1
        case .window: 2
        case .screen: 3
        case .gallery: 4
        }
    }
}

enum ScreenCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }

    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
}

enum PreviewDuration: Int, CaseIterable, Identifiable {
    case short = 5
    case medium = 10
    case long = 20
    case forever = 0

    var id: Int { rawValue }
    var title: String { self == .forever ? "Until closed" : "\(rawValue) seconds" }
    var interval: TimeInterval? { self == .forever ? nil : TimeInterval(rawValue) }
}

/// Persisted user preferences.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let corner = "previewCorner"
        static let duration = "previewDuration"
        static let copy = "copyToClipboard"
        static let save = "saveToFolder"
        static let folder = "saveFolderPath"
        static let sound = "playSound"
        static let shadow = "includeWindowShadow"
        static let openEditor = "openEditorAfterCapture"
        static let shortcuts = "shortcuts"
        static let launched = "hasLaunchedBefore"
    }

    @Published var corner: ScreenCorner {
        didSet { defaults.set(corner.rawValue, forKey: Key.corner) }
    }
    @Published var previewDuration: PreviewDuration {
        didSet { defaults.set(previewDuration.rawValue, forKey: Key.duration) }
    }
    @Published var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: Key.copy) }
    }
    @Published var saveToFolder: Bool {
        didSet { defaults.set(saveToFolder, forKey: Key.save) }
    }
    @Published var saveFolder: URL {
        didSet { defaults.set(saveFolder.path, forKey: Key.folder) }
    }
    @Published var playSound: Bool {
        didSet { defaults.set(playSound, forKey: Key.sound) }
    }
    @Published var includeWindowShadow: Bool {
        didSet { defaults.set(includeWindowShadow, forKey: Key.shadow) }
    }
    @Published var openEditorAfterCapture: Bool {
        didSet { defaults.set(openEditorAfterCapture, forKey: Key.openEditor) }
    }
    @Published private(set) var shortcuts: [ShortcutAction: Shortcut] {
        didSet { saveShortcuts() }
    }

    let isFirstLaunch: Bool

    private init() {
        defaults.register(defaults: [
            Key.copy: true,
            Key.save: false,
            Key.sound: true,
            Key.shadow: true,
            Key.openEditor: false,
            Key.duration: PreviewDuration.medium.rawValue,
        ])

        corner = ScreenCorner(rawValue: defaults.string(forKey: Key.corner) ?? "") ?? .bottomLeft
        previewDuration = PreviewDuration(rawValue: defaults.integer(forKey: Key.duration)) ?? .medium
        copyToClipboard = defaults.bool(forKey: Key.copy)
        saveToFolder = defaults.bool(forKey: Key.save)
        playSound = defaults.bool(forKey: Key.sound)
        includeWindowShadow = defaults.bool(forKey: Key.shadow)
        openEditorAfterCapture = defaults.bool(forKey: Key.openEditor)
        saveFolder = defaults.string(forKey: Key.folder).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]

        // Cleared shortcuts are stored as null; actions missing entirely (e.g. newly added) get their default.
        let stored = defaults.data(forKey: Key.shortcuts)
            .flatMap { try? JSONDecoder().decode([String: Shortcut?].self, from: $0) } ?? [:]
        var resolved: [ShortcutAction: Shortcut] = [:]
        for action in ShortcutAction.allCases {
            if let entry = stored[action.rawValue] {
                resolved[action] = entry
            } else {
                resolved[action] = Shortcut.defaults[action]
            }
        }
        shortcuts = resolved

        isFirstLaunch = !defaults.bool(forKey: Key.launched)
        defaults.set(true, forKey: Key.launched)
    }

    /// Assigns a shortcut to a mode, removing it from any other mode that used it.
    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        var updated = shortcuts
        if let shortcut {
            for (other, existing) in updated where other != action && existing == shortcut {
                updated[other] = nil
            }
        }
        updated[action] = shortcut
        shortcuts = updated
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Snaps: failed to update login item: \(error)")
            }
        }
    }

    private func saveShortcuts() {
        let stored: [String: Shortcut?] = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map {
            ($0.rawValue, shortcuts[$0])
        })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Key.shortcuts)
        }
    }
}

/// Runtime (non-persisted) state shared across the UI.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var hasScreenPermission = ScreenPermission.isGranted
    @Published var unavailableShortcuts: Set<ShortcutAction> = []
    @Published var isRecordingShortcut = false

    func refreshPermission() {
        let granted = ScreenPermission.isGranted
        if granted != hasScreenPermission {
            hasScreenPermission = granted
        }
    }
}

enum ScreenPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// CGPreflightScreenCaptureAccess only updates after a relaunch. Other apps' window titles are
    /// hidden without the permission and appear as soon as it's granted, so this reflects changes live.
    static var isGrantedLive: Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let me = ProcessInfo.processInfo.processIdentifier
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) != me,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let title = info[kCGWindowName as String] as? String
            else { return false }
            return !title.isEmpty
        }
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Quits and reopens Snaps so a newly granted permission takes effect.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
