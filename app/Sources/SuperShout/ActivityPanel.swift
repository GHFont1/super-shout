import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @Published var draft = ""
    @Published var attachments: [URL] = []
    @Published var dropTargeted = false
    var agentEngine: EngineChoice = Settings.shared.engine(for: .f19)

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
        }
    }

    func clearFinished() {
        tasks.removeAll { !$0.running }
        if tasks.isEmpty { ActivityPanelController.shared.hide() }
    }

    func addAttachments(_ urls: [URL]) {
        var existing = Set(attachments.map(\.standardizedFileURL))
        attachments.append(contentsOf: urls.map(\.standardizedFileURL).filter {
            $0.isFileURL && existing.insert($0).inserted
        })
    }

    func removeAttachment(_ url: URL) {
        attachments.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
    }

    func chooseFiles() {
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseFiles = true
        picker.canChooseDirectories = true
        picker.prompt = "Attach"
        if picker.runModal() == .OK { addAttachments(picker.urls) }
    }

    /// Typed/pasted requests and dropped files use the same real AI Do lane as
    /// F19. A submission starts a new task, so the currently running voice task
    /// remains intact and auditable.
    func submit() {
        let instruction = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty || !attachments.isEmpty else { return }
        let files = attachments
        draft = ""
        attachments = []

        let visibleTitle = instruction.isEmpty
            ? "Work with \(files.count) attached item\(files.count == 1 ? "" : "s")"
            : instruction
        let task = begin(
            kind: "AI Do · \(ClaudePolish.resolvedEngineLabel(for: agentEngine))",
            title: visibleTitle
        )
        var request = instruction.isEmpty ? "Inspect the attached items and tell me what you find." : instruction
        if !files.isEmpty {
            request += "\n\nATTACHED FILES OR FOLDERS (local paths):\n"
                + files.map { "- \($0.path)" }.joined(separator: "\n")
        }
        ClaudePolish.agentAct(instruction: request, selection: nil, engine: agentEngine, onProgress: { line in
            self.update(task, line)
        }) { report in
            DispatchQueue.main.async {
                self.finish(task, report: report)
                if let report {
                    TranscriptHistory.shared.add(TranscriptRecord(
                        text: report,
                        rawText: request,
                        kind: .action,
                        appName: "Super Shout AI Do"
                    ))
                }
            }
        }
    }
}

final class ActivityPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        ActivityPanelController.shared.hide()
    }
}

final class ActivityPanelController: NSObject, NSWindowDelegate {
    static let shared = ActivityPanelController()
    private var panel: ActivityPanel?
    private var visible = false

    private func defaultFrame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let w: CGFloat = 460
        let h: CGFloat = 500
        return NSRect(x: vf.maxX - w - 12, y: vf.maxY - h - 12, width: w, height: h)
    }

    func show() {
        if panel == nil { build() }
        guard let panel else { return }
        if visible {
            panel.orderFrontRegardless()
            return
        }
        visible = true
        panel.alphaValue = 0.0
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
        let frame = NSScreen.main.map(defaultFrame(on:)) ?? NSRect(x: 200, y: 200, width: 460, height: 500)
        let p = ActivityPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        p.title = "Super Shout Activity"
        p.titleVisibility = .visible
        p.isReleasedWhenClosed = false
        p.level = .floating
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.minSize = NSSize(width: 380, height: 300)
        p.delegate = self
        p.setFrameAutosaveName("SuperShoutActivityWindow")
        p.contentViewController = NSHostingController(rootView: ActivityView())
        panel = p
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

struct ActivityView: View {
    @ObservedObject var center = ActivityCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").foregroundStyle(.pink)
                Text("AI Do").font(.headline)
                Spacer()
                Button("Clear") { center.clearFinished() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(center.tasks.allSatisfy { $0.running })
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


            Divider().opacity(0.4)
            composer
        }
        .background(.regularMaterial)
        .onDrop(of: [UTType.fileURL.identifier, UTType.plainText.identifier],
                isTargeted: $center.dropTargeted,
                perform: acceptDrop)
        .overlay {
            if center.dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.pink, style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .padding(5)
                    .allowsHitTesting(false)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !center.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(center.attachments, id: \.self) { url in
                            HStack(spacing: 5) {
                                Image(systemName: url.hasDirectoryPath ? "folder" : "doc")
                                Text(url.lastPathComponent).lineLimit(1)
                                Button { center.removeAttachment(url) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Paste or type another AI Do request…", text: $center.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { center.submit() }
                Button { center.chooseFiles() } label: { Image(systemName: "paperclip") }
                    .help("Attach files or folders")
                Button { center.submit() } label: { Image(systemName: "arrow.up.circle.fill") }
                    .buttonStyle(.borderless)
                    .font(.title2)
                    .foregroundStyle(.pink)
                    .disabled(center.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && center.attachments.isEmpty)
                    .help("Run AI Do")
            }
            Text("Paste text normally, or drop files and folders anywhere in this window.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { center.addAttachments([url]) }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                provider.loadObject(ofClass: NSString.self) { value, _ in
                    guard let text = value as? String else { return }
                    DispatchQueue.main.async {
                        if !center.draft.isEmpty { center.draft += "\n" }
                        center.draft += text
                    }
                }
            }
        }
        return accepted
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
