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
        case .area: "Drag a region, or click a window"
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

/// What a screen recording turns into.
enum RecordingFormat: String, CaseIterable, Identifiable {
    case video, gif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: "Record Video"
        case .gif: "Record GIF"
        }
    }

    var shortTitle: String {
        switch self {
        case .video: "Video"
        case .gif: "GIF"
        }
    }

    var detail: String {
        switch self {
        case .video: "Record an area, a window or a screen as MP4"
        case .gif: "Record an area, a window or a screen as an animated GIF"
        }
    }

    var symbol: String {
        switch self {
        case .video: "record.circle"
        case .gif: "rectangle.stack.badge.play"
        }
    }
}

/// Everything that can be bound to a global shortcut.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case area, window, screen, recordVideo, recordGIF, gallery

    init(_ mode: CaptureMode) {
        self = ShortcutAction(rawValue: mode.rawValue)!
    }

    init(_ format: RecordingFormat) {
        self = format == .video ? .recordVideo : .recordGIF
    }

    var id: String { rawValue }
    var captureMode: CaptureMode? { CaptureMode(rawValue: rawValue) }

    var recordingFormat: RecordingFormat? {
        switch self {
        case .recordVideo: .video
        case .recordGIF: .gif
        default: nil
        }
    }

    var title: String { captureMode?.title ?? recordingFormat?.title ?? "Gallery" }
    var detail: String {
        captureMode?.detail ?? recordingFormat?.detail ?? "Browse recent captures across the top of the screen"
    }
    var symbol: String { captureMode?.symbol ?? recordingFormat?.symbol ?? "photo.stack" }

    var hotKeyID: UInt32 {
        switch self {
        case .area: 1
        case .window: 2
        case .screen: 3
        case .gallery: 4
        case .recordVideo: 5
        case .recordGIF: 6
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

enum VideoFrameRate: Int, CaseIterable, Identifiable {
    case thirty = 30
    case sixty = 60

    var id: Int { rawValue }
    var title: String { "\(rawValue) fps" }
}

enum GIFFrameRate: Int, CaseIterable, Identifiable {
    case ten = 10
    case fifteen = 15
    case twenty = 20
    case twentyFive = 25

    var id: Int { rawValue }
    var title: String { "\(rawValue) fps" }
}

/// The widest a GIF gets, in pixels. Retina recordings are halved first, so `full` is the size in points.
enum GIFSize: Int, CaseIterable, Identifiable {
    case small = 480
    case medium = 720
    case large = 1080
    case full = 0

    var id: Int { rawValue }
    var title: String { self == .full ? "Full size" : "\(rawValue) px wide" }
    var maxWidth: Int? { self == .full ? nil : rawValue }
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
        static let showPreview = "showPreview"
        static let keepInGallery = "keepInGallery"
        static let recordCursor = "recordShowsCursor"
        static let recordClicks = "recordHighlightsClicks"
        static let recordSystemAudio = "recordSystemAudio"
        static let recordMicrophone = "recordMicrophone"
        static let recordCountdown = "recordCountdown"
        static let videoFrameRate = "videoFrameRate"
        static let gifFrameRate = "gifFrameRate"
        static let gifSize = "gifSize"
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
    /// The floating preview in the corner after each capture.
    @Published var showPreview: Bool {
        didSet { defaults.set(showPreview, forKey: Key.showPreview) }
    }
    /// Whether new captures are added to the gallery. Off, a capture lasts only as long as it's on screen.
    @Published var keepInGallery: Bool {
        didSet { defaults.set(keepInGallery, forKey: Key.keepInGallery) }
    }
    @Published var recordShowsCursor: Bool {
        didSet { defaults.set(recordShowsCursor, forKey: Key.recordCursor) }
    }
    @Published var recordHighlightsClicks: Bool {
        didSet { defaults.set(recordHighlightsClicks, forKey: Key.recordClicks) }
    }
    @Published var recordSystemAudio: Bool {
        didSet { defaults.set(recordSystemAudio, forKey: Key.recordSystemAudio) }
    }
    @Published var recordMicrophone: Bool {
        didSet { defaults.set(recordMicrophone, forKey: Key.recordMicrophone) }
    }
    @Published var recordCountdown: Bool {
        didSet { defaults.set(recordCountdown, forKey: Key.recordCountdown) }
    }
    @Published var videoFrameRate: VideoFrameRate {
        didSet { defaults.set(videoFrameRate.rawValue, forKey: Key.videoFrameRate) }
    }
    @Published var gifFrameRate: GIFFrameRate {
        didSet { defaults.set(gifFrameRate.rawValue, forKey: Key.gifFrameRate) }
    }
    @Published var gifSize: GIFSize {
        didSet { defaults.set(gifSize.rawValue, forKey: Key.gifSize) }
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
            Key.showPreview: true,
            Key.keepInGallery: true,
            Key.duration: PreviewDuration.medium.rawValue,
            Key.recordCursor: true,
            Key.recordClicks: true,
            Key.recordSystemAudio: false,
            Key.recordMicrophone: false,
            Key.recordCountdown: true,
            Key.videoFrameRate: VideoFrameRate.thirty.rawValue,
            Key.gifFrameRate: GIFFrameRate.fifteen.rawValue,
            Key.gifSize: GIFSize.medium.rawValue,
        ])

        corner = ScreenCorner(rawValue: defaults.string(forKey: Key.corner) ?? "") ?? .bottomLeft
        previewDuration = PreviewDuration(rawValue: defaults.integer(forKey: Key.duration)) ?? .medium
        copyToClipboard = defaults.bool(forKey: Key.copy)
        saveToFolder = defaults.bool(forKey: Key.save)
        playSound = defaults.bool(forKey: Key.sound)
        includeWindowShadow = defaults.bool(forKey: Key.shadow)
        openEditorAfterCapture = defaults.bool(forKey: Key.openEditor)
        showPreview = defaults.bool(forKey: Key.showPreview)
        keepInGallery = defaults.bool(forKey: Key.keepInGallery)
        recordShowsCursor = defaults.bool(forKey: Key.recordCursor)
        recordHighlightsClicks = defaults.bool(forKey: Key.recordClicks)
        recordSystemAudio = defaults.bool(forKey: Key.recordSystemAudio)
        recordMicrophone = defaults.bool(forKey: Key.recordMicrophone)
        recordCountdown = defaults.bool(forKey: Key.recordCountdown)
        videoFrameRate = VideoFrameRate(rawValue: defaults.integer(forKey: Key.videoFrameRate)) ?? .thirty
        gifFrameRate = GIFFrameRate(rawValue: defaults.integer(forKey: Key.gifFrameRate)) ?? .fifteen
        gifSize = GIFSize(rawValue: defaults.integer(forKey: Key.gifSize)) ?? .medium
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
    @Published var settingsTab: SettingsTab = .general

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
