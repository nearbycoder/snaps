import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, arrow, text, blur

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .text: "Text"
        case .blur: "Blur"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .blur: "drop.halffull"
        }
    }

    /// Single key that picks the tool while the canvas has focus.
    var key: String {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .text: "t"
        case .blur: "b"
        }
    }

    var hint: String {
        switch self {
        case .select: "Click an annotation to select it. Drag to move it, or press Delete to remove it."
        case .arrow: "Drag to draw an arrow. Hold Shift to keep it straight."
        case .text: "Click where the text should go and start typing. Return finishes it."
        case .blur: "Drag over anything you want to hide."
        }
    }
}

/// Fixed sRGB colors, so an export looks the same in light and dark mode.
enum AnnotationColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, white, black

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .red: NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1)
        case .orange: NSColor(srgbRed: 1, green: 0.584, blue: 0, alpha: 1)
        case .yellow: NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)
        case .green: NSColor(srgbRed: 0.204, green: 0.78, blue: 0.349, alpha: 1)
        case .blue: NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1)
        case .white: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .black: NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        }
    }

    /// The thin border that keeps a mark readable on any background.
    var outline: NSColor {
        switch self {
        case .white, .yellow: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.8)
        default: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }
}

enum StrokeSize: Int, CaseIterable, Identifiable {
    case small, medium, large

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// Sizes are in image points, so marks keep their weight relative to the capture.
    var arrowWidth: CGFloat {
        switch self {
        case .small: 4
        case .medium: 7
        case .large: 11
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .small: 16
        case .medium: 24
        case .large: 36
        }
    }
}

struct Annotation: Identifiable, Equatable {
    enum Shape: Equatable {
        case arrow(from: CGPoint, to: CGPoint)
        /// `origin` is the top-left corner of the first line.
        case text(origin: CGPoint, string: String)
        case blur(CGRect)
    }

    enum Kind { case arrow, text, blur }

    let id: UUID
    var shape: Shape
    var color: AnnotationColor
    var size: StrokeSize

    init(id: UUID = UUID(), shape: Shape, color: AnnotationColor, size: StrokeSize) {
        self.id = id
        self.shape = shape
        self.color = color
        self.size = size
    }

    var kind: Kind {
        switch shape {
        case .arrow: .arrow
        case .text: .text
        case .blur: .blur
        }
    }

    var bounds: CGRect {
        switch shape {
        case let .arrow(from, to):
            let pad = AnnotationRenderer.headLength(width: size.arrowWidth)
            return CGRect(from: from, to: to).insetBy(dx: -pad, dy: -pad)
        case let .text(origin, string):
            return CGRect(origin: origin, size: AnnotationRenderer.textSize(string, size: size))
        case let .blur(rect):
            return rect
        }
    }

    func offset(by delta: CGVector) -> Annotation {
        var copy = self
        switch shape {
        case let .arrow(from, to):
            copy.shape = .arrow(from: from.offset(by: delta), to: to.offset(by: delta))
        case let .text(origin, string):
            copy.shape = .text(origin: origin.offset(by: delta), string: string)
        case let .blur(rect):
            copy.shape = .blur(rect.offsetBy(dx: delta.dx, dy: delta.dy))
        }
        return copy
    }

    func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch shape {
        case let .arrow(from, to):
            let reach = max(size.arrowWidth, tolerance)
            if point.distance(to: to) <= AnnotationRenderer.headLength(width: size.arrowWidth) { return true }
            return point.distance(toSegment: from, to) <= reach
        case .text, .blur:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }
}

/// Draws annotations in image points with a top-left origin. The canvas and the export share it, so what
/// you see while editing is what lands on the clipboard.
enum AnnotationRenderer {
    static func draw(_ annotations: [Annotation], blurred: CGImage?, imageSize: CGSize, in ctx: CGContext) {
        for annotation in annotations {
            switch annotation.shape {
            case let .arrow(from, to):
                drawArrow(from: from, to: to, color: annotation.color, width: annotation.size.arrowWidth, in: ctx)
            case let .text(origin, string):
                drawText(string, at: origin, color: annotation.color, size: annotation.size, in: ctx)
            case let .blur(rect):
                drawBlur(rect, blurred: blurred, imageSize: imageSize, in: ctx)
            }
        }
    }

    // MARK: Arrow

    static func headLength(width: CGFloat) -> CGFloat {
        max(width * 4, 14)
    }

    /// A tapered shaft that widens into a swept head.
    static func arrowPath(from tail: CGPoint, to tip: CGPoint, width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let length = tail.distance(to: tip)
        guard length > 0.5 else { return path }

        let along = CGVector(dx: (tip.x - tail.x) / length, dy: (tip.y - tail.y) / length)
        let normal = CGVector(dx: -along.dy, dy: along.dx)
        let head = min(headLength(width: width), length * 0.6)
        let headHalf = head * 0.6
        let neckHalf = width / 2
        let tailHalf = width * 0.18

        func point(_ base: CGPoint, back: CGFloat, side: CGFloat) -> CGPoint {
            CGPoint(
                x: base.x - along.dx * back + normal.dx * side,
                y: base.y - along.dy * back + normal.dy * side
            )
        }

        path.move(to: point(tail, back: 0, side: tailHalf))
        path.addLine(to: point(tip, back: head * 0.8, side: neckHalf))
        path.addLine(to: point(tip, back: head, side: headHalf))
        path.addLine(to: tip)
        path.addLine(to: point(tip, back: head, side: -headHalf))
        path.addLine(to: point(tip, back: head * 0.8, side: -neckHalf))
        path.addLine(to: point(tail, back: 0, side: -tailHalf))
        path.closeSubpath()
        return path
    }

    static func drawArrow(from: CGPoint, to: CGPoint, color: AnnotationColor, width: CGFloat, in ctx: CGContext) {
        let path = arrowPath(from: from, to: to, width: width)
        withShadow(ctx) {
            ctx.addPath(path)
            ctx.setStrokeColor(color.outline.cgColor)
            ctx.setLineWidth(max(1.5, width * 0.4))
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.addPath(path)
            ctx.setFillColor(color.nsColor.cgColor)
            ctx.fillPath()
        }
    }

    // MARK: Text

    static func font(for size: StrokeSize) -> NSFont {
        let base = NSFont.systemFont(ofSize: size.fontSize, weight: .bold)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: size.fontSize) ?? base
    }

    /// Font plus a little tracking, so the outline doesn't fuse neighboring letters.
    static func textAttributes(for size: StrokeSize) -> [NSAttributedString.Key: Any] {
        [.font: font(for: size), .kern: size.fontSize * 0.04]
    }

    static let textOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    static func textSize(_ string: String, size: StrokeSize) -> CGSize {
        // An empty or trailing line still takes up a line.
        let measuring = string.isEmpty || string.hasSuffix("\n") ? string + " " : string
        let measured = NSAttributedString(string: measuring, attributes: textAttributes(for: size))
            .boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: textOptions)
        return CGSize(width: ceil(measured.width), height: ceil(measured.height))
    }

    static func drawText(_ string: String, at origin: CGPoint, color: AnnotationColor, size: StrokeSize, in ctx: CGContext) {
        guard !string.isEmpty else { return }
        let attributes = textAttributes(for: size)
        // Generous bounds so rounding never wraps a line.
        let measured = textSize(string, size: size)
        let rect = CGRect(origin: origin, size: CGSize(width: measured.width + 200, height: measured.height + 200))
        // Stroke is centered on the glyph edge, so double the width that should show outside it.
        let outline = max(1.5, size.fontSize * 0.08)
        let strokePercent = outline * 2 / size.fontSize * 100

        withShadow(ctx) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            ctx.setLineJoin(.round)
            NSAttributedString(string: string, attributes: attributes.merging([
                .strokeColor: color.outline,
                .strokeWidth: strokePercent,
            ]) { $1 }).draw(with: rect, options: textOptions)
            NSAttributedString(string: string, attributes: attributes.merging([
                .foregroundColor: color.nsColor,
            ]) { $1 }).draw(with: rect, options: textOptions)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: Blur

    static func drawBlur(_ rect: CGRect, blurred: CGImage?, imageSize: CGSize, in ctx: CGContext) {
        let shape = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        if let blurred {
            drawUpright(blurred, in: CGRect(origin: .zero, size: imageSize), ctx: ctx)
        } else {
            // The blurred copy is still rendering; cover the area so nothing leaks meanwhile.
            ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
            ctx.fill(rect)
        }
        ctx.restoreGState()
    }

    /// A pixelated, then softened copy of the whole capture. Each blur mark shows a piece of it, so the
    /// hidden content is gone for good instead of just smeared.
    static func makeBlurred(_ image: CGImage, pointSize: CGSize) -> CGImage? {
        let density = CGFloat(image.width) / max(pointSize.width, 1)
        let input = CIImage(cgImage: image)

        let pixellate = CIFilter.pixellate()
        pixellate.inputImage = input.clampedToExtent()
        pixellate.scale = Float(12 * density)
        pixellate.center = .zero
        guard let blocks = pixellate.outputImage else { return nil }

        let output = blocks
            .applyingGaussianBlur(sigma: Double(7 * density))
            .cropped(to: input.extent)
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext().createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: colorSpace)
    }

    // MARK: Export

    /// Draws the capture and its annotations at full resolution.
    static func flatten(_ image: CGImage, pointSize: CGSize, annotations: [Annotation], blurred: CGImage?) -> CGImage? {
        let width = image.width
        let height = image.height
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Switch to image points with a top-left origin, like the canvas.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(width) / pointSize.width, y: -CGFloat(height) / pointSize.height)
        draw(annotations, blurred: blurred, imageSize: pointSize, in: ctx)
        return ctx.makeImage()
    }

    /// PNG data whose DPI keeps the capture's point size, like `screencapture` writes it.
    static func pngData(_ image: CGImage, pointSize: CGSize) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        let dpi = 72 * Double(image.width) / Double(max(pointSize.width, 1))
        let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: Helpers

    /// A soft drop shadow, sized in the current user space so it matches between canvas and export.
    private static func withShadow(_ ctx: CGContext, _ body: () -> Void) {
        let transform = ctx.userSpaceToDeviceSpaceTransform
        let scale = max(hypot(transform.a, transform.b), 0.01)
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -1.5 * scale),
            blur: 4 * scale,
            color: NSColor(white: 0, alpha: 0.35).cgColor
        )
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Draws a CGImage right side up into a context whose y axis points down.
    private static func drawUpright(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }
}

extension CGPoint {
    func offset(by delta: CGVector) -> CGPoint {
        CGPoint(x: x + delta.dx, y: y + delta.dy)
    }

    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }

    func distance(toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(to: a) }
        let t = max(0, min(1, ((x - a.x) * dx + (y - a.y) * dy) / lengthSquared))
        return distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}

extension CGRect {
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
