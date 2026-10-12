import AppKit
import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel
    let canvas: AnnotationCanvasView
    let titlebarHeight: CGFloat
    let onCopy: () -> Void
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsToolHint = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.leading, 84) // clear of the window buttons
                .padding(.trailing, 14)
                .frame(height: titlebarHeight)

            ZStack(alignment: .bottom) {
                CanvasHost(canvas: canvas)
                feedback
                    .padding(.bottom, 36)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .background {
            VisualEffectBackground(material: .underPageBackground).ignoresSafeArea()
        }
        .task(id: model.tool) {
            showsToolHint = true
            try? await Task.sleep(for: .seconds(2.6))
            if !Task.isCancelled { showsToolHint = false }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            toolPicker
            stylePicker
            Spacer(minLength: 8)
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    GlassIconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", size: 30) { model.undo() }
                        .disabled(!model.canUndo)
                    GlassIconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", size: 30) { model.redo() }
                        .disabled(!model.canRedo)
                }
            }
            Button(action: onCopy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.glass)
            .help("Copy the annotated image (⌘C)")
            Button(action: onDone) {
                Text("Done").frame(minWidth: 40)
            }
            .buttonStyle(.glassProminent)
            .help("Save the annotations into the capture and close (⌘↩)")
        }
        .controlSize(.large)
    }

    private var toolPicker: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(AnnotationTool.allCases) { tool in
                    let isSelected = model.tool == tool
                    Button {
                        model.tool = tool
                    } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .glassEffect(
                        isSelected ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                        in: .circle
                    )
                    .help("\(tool.title) (\(tool.key.uppercased()))")
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .animation(reduceMotion ? nil : Motion.smoothOut(Motion.fast), value: model.tool)
    }

    private var stylePicker: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(AnnotationColor.allCases) { color in
                    ColorSwatch(color: color, isSelected: model.color == color) {
                        model.setColor(color)
                    }
                }
            }
            .padding(.horizontal, 5)
            .frame(height: 34)
            .glassEffect(.regular, in: .capsule)

            HStack(spacing: 2) {
                ForEach(StrokeSize.allCases) { size in
                    SizeOption(size: size, isSelected: model.size == size) {
                        model.setSize(size)
                    }
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 34)
            .glassEffect(.regular, in: .capsule)
        }
        .animation(.easeInOut(duration: Motion.quick), value: model.color)
        .animation(.easeInOut(duration: Motion.quick), value: model.size)
        .opacity(model.acceptsStyle ? 1 : 0.4)
        .disabled(!model.acceptsStyle)
        .animation(.easeInOut(duration: Motion.quick), value: model.acceptsStyle)
    }

    /// A toast after Copy, otherwise a hint for the current tool while it's new or the canvas is still empty.
    private var feedback: some View {
        ZStack {
            if let toast = model.toast {
                Label(toast, systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .transition(Motion.pill(reduceMotion: reduceMotion))
            } else if model.isEmpty || showsToolHint {
                Text(model.tool.hint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .id(model.tool)
                    .transition(Motion.pill(reduceMotion: reduceMotion))
            }
        }
        .animation(Motion.smoothOut(Motion.fast), value: model.toast)
        .animation(Motion.smoothOut(Motion.fast), value: model.tool)
        .animation(Motion.smoothOut(Motion.fast), value: model.isEmpty || showsToolHint)
    }
}

private struct ColorSwatch: View {
    let color: AnnotationColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: color.nsColor))
                .frame(width: 16, height: 16)
                .overlay {
                    Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5)
                }
                .padding(3)
                .overlay {
                    Circle().strokeBorder(.primary.opacity(isSelected ? 0.85 : 0), lineWidth: 1.5)
                }
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color.title)
        .accessibilityLabel(color.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SizeOption: View {
    let size: StrokeSize
    let isSelected: Bool
    let action: () -> Void

    private var dot: CGFloat {
        switch size {
        case .small: 5
        case .medium: 8
        case .large: 11
        }
    }

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(.primary)
                .frame(width: dot, height: dot)
                .frame(width: 26, height: 26)
                .background {
                    Circle().fill(.primary.opacity(isSelected ? 0.14 : 0))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(size.title)
        .accessibilityLabel(size.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct CanvasHost: NSViewRepresentable {
    let canvas: AnnotationCanvasView

    func makeNSView(context: Context) -> AnnotationCanvasView { canvas }
    func updateNSView(_ nsView: AnnotationCanvasView, context: Context) {}
}
