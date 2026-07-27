import AppKit
import SwiftUI

/// The "Shout Bar" — a floating, non-activating pill at the bottom-center of
/// the screen showing recording state, a live waveform, and partial text.
final class HUDController {
    private let model = HUDModel()
    private var panel: NSPanel?

    func update(for state: DictationState) {
        switch state {
        case .idle:
            // Success/cancel flashes are triggered explicitly via flashDone;
            // a bare return to idle (e.g. empty transcript) just hides.
            if model.mode == .listening || model.mode == .processing { hide() }
        case .listening(let handsFree):
            model.reset()
            model.mode = .listening
            model.statusText = handsFree ? "\(sessionLabel) (hands-free — tap again to finish)" : sessionLabel
            show()
        case .processing:
            model.mode = .processing
            model.statusText = "Processing…"
        }
    }

    func pushLevel(_ level: Float) { model.pushLevel(level) }
    func showPartial(_ text: String) { model.partialText = text }

    private var sessionLabel = "Listening…"

    /// Sets the label and accent color for the upcoming session so each mode
    /// (dictate orange, AI edit purple, AI compose cyan) is visually distinct.
    func configureSession(label: String, accent: Color) {
        sessionLabel = label
        model.accent = accent
    }

    /// Mid-processing status updates ("Asking Claude…").
    func showStatus(_ text: String) {
        model.mode = .processing
        model.statusText = text
        show()
    }

    func flashDone(_ message: String) {
        model.mode = .done
        model.statusText = message
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            if self?.model.mode == .done { self?.hide() }
        }
    }

    func flashError(_ message: String) {
        model.mode = .error
        model.statusText = message
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.hide() }
    }

    func flashInfo(_ message: String) {
        model.mode = .info
        model.statusText = message
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if self?.model.mode == .info { self?.hide() }
        }
    }

    private func show() {
        if panel == nil { buildPanel() }
        // Re-center every time — the main screen may have changed since the
        // panel was built (display plugged/unplugged, resolution change).
        if let panel, let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 24))
        }
        panel?.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func buildPanel() {
        let width: CGFloat = 420
        let height: CGFloat = 76
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: ShoutBarView(model: model))
        hosting.frame = panel.contentView!.bounds
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.minY + 24))
        }
        self.panel = panel
    }
}

enum HUDMode { case listening, processing, done, error, info }

final class HUDModel: ObservableObject {
    @Published var mode: HUDMode = .listening
    @Published var statusText = ""
    @Published var partialText = ""
    @Published var accent: Color = .orange
    @Published var levels: [Float] = Array(repeating: 0.05, count: 28)

    func pushLevel(_ level: Float) {
        levels.removeFirst()
        levels.append(max(0.05, level))
    }

    func reset() {
        partialText = ""
        levels = Array(repeating: 0.05, count: 28)
    }
}

struct ShoutBarView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconColor)

                if model.mode == .listening {
                    HStack(spacing: 2.5) {
                        ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(model.accent)
                                .frame(width: 3, height: CGFloat(6 + level * 26))
                        }
                    }
                    .frame(height: 34)
                } else {
                    Text(model.statusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            if model.mode == .listening && !model.partialText.isEmpty {
                Text(String(model.partialText.suffix(58)))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.08), value: model.levels)
    }

    private var icon: String {
        switch model.mode {
        case .listening: return "mic.fill"
        case .processing: return "ellipsis"
        case .done: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var iconColor: Color {
        switch model.mode {
        case .listening: return model.accent
        case .processing: return .yellow
        case .done: return .green
        case .error: return .red
        case .info: return .yellow
        }
    }
}
