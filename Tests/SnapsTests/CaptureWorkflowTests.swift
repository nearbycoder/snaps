import AppKit
import XCTest
@testable import Snaps

final class CaptureWorkflowTests: XCTestCase {
    func testOnlyFilesInsideTheCaptureCacheAreDisposable() {
        let cache = CaptureStorage.cacheDirectory
        let savedFolder = cache.deletingLastPathComponent().appendingPathComponent("Captures saved")
        XCTAssertTrue(CaptureStorage.isInCache(cache.appendingPathComponent("Shot.png")))
        XCTAssertFalse(CaptureStorage.isInCache(savedFolder.appendingPathComponent("Shot.png")))
    }

    @MainActor
    func testSwitchingShortcutRowsAndLeavingSettingsRestoresHotKeys() async {
        _ = NSApplication.shared
        let first = ShortcutRecorderModel()
        let second = ShortcutRecorderModel()
        defer { first.stop(); second.stop() }

        first.start { _ in XCTFail("The previous shortcut row must be disarmed") }
        second.start { _ in }
        XCTAssertFalse(first.isRecording)
        XCTAssertTrue(second.isRecording)
        XCTAssertTrue(AppState.shared.isRecordingShortcut)

        SettingsWindowController().windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertFalse(second.isRecording)
        XCTAssertFalse(AppState.shared.isRecordingShortcut)
    }

    func testTranslucentBlurFullyCoversTheUnderlyingPixels() throws {
        let size = CGSize(width: 24, height: 24)
        let frame = CGRect(origin: .zero, size: size)
        let mark = Annotation(shape: .blur(frame.insetBy(dx: 4, dy: 4)), color: .red, size: .small)
        func solidImage(white: CGFloat, alpha: CGFloat) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8,
                                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(gray: white, alpha: alpha)
            context.fill(frame)
            return try XCTUnwrap(context.makeImage())
        }
        let blur = try solidImage(white: 0.5, alpha: 0.4)
        func render(over white: CGFloat) throws -> NSBitmapImageRep {
            let original = try solidImage(white: white, alpha: 1)
            let result = try XCTUnwrap(AnnotationRenderer.flatten(original, pointSize: size, annotations: [mark], blurred: blur))
            return NSBitmapImageRep(cgImage: result)
        }
        let dark = try render(over: 0)
        let light = try render(over: 1)
        for y in 4..<20 {
            for x in 4..<20 {
                XCTAssertEqual(dark.colorAt(x: x, y: y), light.colorAt(x: x, y: y))
            }
        }
        XCTAssertNotEqual(dark.colorAt(x: 0, y: 0), light.colorAt(x: 0, y: 0))
    }

    @MainActor
    func testUndoAndRedoUpdateTheSelectedAnnotationStyle() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let arrow = Annotation(shape: .arrow(from: .zero, to: CGPoint(x: 18, y: 18)), color: .red, size: .small)
        let session = EditorSession(image: try XCTUnwrap(context.makeImage()), imageSize: CGSize(width: 20, height: 20),
                                    annotations: [arrow], applied: [arrow])
        let model = EditorModel(session: session)
        model.select(arrow.id)
        model.beginChange()
        model.update(arrow.id) { $0.color = .green; $0.size = .large }
        model.endChange()

        model.undo()
        XCTAssertEqual(model.color, .red)
        XCTAssertEqual(model.size, .small)
        model.redo()
        XCTAssertEqual(model.color, .green)
        XCTAssertEqual(model.size, .large)
    }
}
