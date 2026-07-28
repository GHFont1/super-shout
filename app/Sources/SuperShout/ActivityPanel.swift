import AppKit
import SwiftUI

/// Live progress surface for background agent work (AI Do, Deep Research):
/// a small feed in the top-right corner that appears when a task starts,
/// streams what the agent is actually doing, and shows the final report.
final class ActivityTask: ObservableObject, Identifiable {
    let id = UUID()
    let kind: String
    let title: String
    let started = Date()
    @Published var updates: [String] = []
    @Published var report: String?
    @Published var failed = false
    var running: Bool { report == nil && !failed }

    init(kind: String, title: String) {
        self.kind = kind
        self.title = title
    }
}

final class ActivityCenter: ObservableObject {
    static let shared = ActivityCenter()
    @Published var tasks: [ActivityTask] = []

    func begin(kind: String, title: String) -> ActivityTask {
        let t = ActivityTask(kind: kind, title: title)
        DispatchQueue.main.async {
            self.tasks.insert(t, at: 0)
            if self.tasks.count > 10 { self.tasks.removeLast() }
            ActivityPanelController.shared.show()
        }
        return t
    }

    func update(_ task: ActivityTask, _ line: String) {
        DispatchQueue.main.async {
            // Collapse immediate duplicates (some tools repeat identically).
            if task.updates.last != line { task.updates.append(line) }
            if task.updates.count > 100 { task.updates.removeFirst() }
        }
    }

    func finish(_ task: ActivityTask, report: String?) {
        DispatchQueue.main.async {
            if let report {
                task.report = report
            } else {
                task.failed = true
            }
            ActivityPanelController.shared.show()
        }
    }

    func clearFinished() {
        tasks.removeAll { !$0.running }
        if tasks.isEmpty { ActivityPanelController.shared.hide() }
    }
}

final class ActivityPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        ActivityPanelController.shared.hide()
    }
}

final class ActivityPanelController {
    static let shared = ActivityPanelController()
    private var panel: ActivityPanel?
    private var visible = false

    private func targetFrame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let w: CGFloat = 400
        let h: CGFloat = 340
        return NSRect(x: vf.maxX - w - 12, y: vf.maxY - h - 12, width: w, height: h)
    }

    func show() {
        if panel == nil { build() }
        guard let panel, let screen = NSScreen.main else { return }
        let final = targetFrame(on: screen)
        if visible {
            panel.orderFrontRegardless()
            return
        }
        visible = true
        var start = final
        start.origin.y = screen.frame.maxY
        panel.setFrame(start, display: false)
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(final, display: true)
            panel.animator().alphaValue = 1.0
        }
    }

    func hide() {
        guard let panel, visible else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1.0
        })
    }

    private func build() {
        let p = ActivityPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        p.isReleasedWhenClosed = false
        p.level = .floating
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.contentViewController = NSHostingController(rootView: ActivityView())
        panel = p
    }
}

struct ActivityView: View {
    @ObservedObject var center = ActivityCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").foregroundStyle(.pink)
                Text("Super Shout — Activity").font(.headline)
                Spacer()
                Button("Clear") { center.clearFinished() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(center.tasks.allSatisfy { $0.running })
                Button {
                    ActivityPanelController.shared.hide()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide (Esc)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if center.tasks.isEmpty {
                        Text("Background tasks (AI Do, Deep Research) show their progress here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(center.tasks) { task in
                        ActivityRow(task: task)
                    }
                }
                .padding(12)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

struct ActivityRow: View {
    @ObservedObject var task: ActivityTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if task.running {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: task.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(task.failed ? Color.red : Color.green)
                }
                Text(task.kind).font(.caption.bold())
                Spacer()
                if task.running {
                    TimelineView(.periodic(from: task.started, by: 1)) { _ in
                        Text(elapsed).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Text(task.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if task.running {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(task.updates.suffix(4).enumerated()), id: \.offset) { i, u in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle()
                                .fill(i == task.updates.suffix(4).count - 1 ? Color.pink : Color.secondary.opacity(0.5))
                                .frame(width: 5, height: 5)
                            Text(u)
                                .font(.caption2)
                                .foregroundStyle(i == task.updates.suffix(4).count - 1 ? .primary : .secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.leading, 2)
            } else if let report = task.report {
                Text(report)
                    .font(.caption)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else if task.failed {
                Text("Failed — see ~/Library/Logs/SuperShout.log")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var elapsed: String {
        let s = Int(Date().timeIntervalSince(task.started))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
