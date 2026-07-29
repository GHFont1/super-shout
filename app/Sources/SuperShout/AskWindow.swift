import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The AI Ask chat surface: a native floating mini-window that opens when the
/// Ask key is pressed, shows live dictation, and keeps typed, spoken, pasted,
/// and file-backed follow-ups in the same conversation until it is closed.
final class AskSession: ObservableObject {
    struct Message: Identifiable {
        let id = UUID()
        let fromUser: Bool
        let text: String
    }

    @Published var messages: [Message] = []
    @Published var pending = false
    @Published var draft = ""
    @Published var attachments: [URL] = []
    @Published var dropTargeted = false
    /// True while the mic is open for this panel; `livePartial` is the
    /// in-flight transcript shown as a typing bubble.
    @Published var listening = false
    @Published var livePartial = ""
    /// Engine of the key that opened the conversation; follow-ups reuse it.
    var engine: EngineChoice = .auto

    func ask(_ question: String, selection: String?) {
        var q = question
        if let selection, !selection.isEmpty {
            q += "\n\nReferring to this text:\n" + selection
        }
        messages.append(Message(fromUser: true, text: q))
        send()
    }

    func followUp() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachments.isEmpty), !pending else { return }
        let files = attachments
        draft = ""
        attachments = []
        let question = text.isEmpty
            ? "Please inspect the attached item\(files.count == 1 ? "" : "s")."
            : text
        messages.append(Message(fromUser: true, text: question))
        send(attachments: files)
    }

    func clear() {
        messages = []
        pending = false
        draft = ""
        attachments = []
    }

    func addAttachments(_ urls: [URL]) {
        var known = Set(attachments.map(\.standardizedFileURL))
        attachments.append(contentsOf: urls.map(\.standardizedFileURL).filter {
            $0.isFileURL && known.insert($0).inserted
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

    private func send(attachments: [URL] = []) {
        pending = true
        let transcript = messages
            .map { "\($0.fromUser ? "User" : "Assistant"): \($0.text)" }
            .joined(separator: "\n\n")
        ClaudePolish.ask(transcript, engine: engine, attachments: attachments) { [weak self] answer in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending = false
                let response = answer ?? "Sorry — the request failed. Check the AI provider in Settings."
                self.messages.append(Message(fromUser: false, text: response))
                if let answer {
                    TranscriptHistory.shared.add(TranscriptRecord(text: answer, rawText: transcript, kind: .ask, appName: "Super Shout AI Ask"))
                }
            }
        }
    }

    var lastAnswer: String? {
        messages.last(where: { !$0.fromUser })?.text
    }
}

/// Borderless panels refuse key status by default; the follow-up field needs it.
final class AskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        AskWindowController.shared.hide()
    }
}

final class AskWindowController: NSObject, NSWindowDelegate {
    static let shared = AskWindowController()
    private var panel: AskPanel?
    private let session = AskSession()
    private var visible = false

    // MARK: Live dictation hooks (called by DictationController)

    /// Key pressed: pull the panel down immediately and show the mic as live.
    /// Never steals focus — the user's app stays frontmost while they speak.
    func beginLive(engine: EngineChoice) {
        session.engine = engine
        session.listening = true
        session.livePartial = ""
        show()
    }

    func updatePartial(_ text: String) {
        session.livePartial = text
    }

    /// Dictation ended with nothing usable (or was canceled).
    func endLive() {
        session.listening = false
        session.livePartial = ""
    }

    // MARK: Asking

    func ask(_ question: String, selection: String?, engine: EngineChoice = .auto) {
        session.listening = false
        session.livePartial = ""
        session.engine = engine
        show()
        session.ask(question, selection: selection)
    }

    // MARK: Panel management

    private func defaultFrame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let w: CGFloat = min(680, max(520, vf.width * 0.38))
        let h: CGFloat = min(620, max(460, vf.height * 0.58))
        return NSRect(x: vf.maxX - w - 18, y: vf.maxY - h - 18, width: w, height: h)
    }

    private func show() {
        if panel == nil { build() }
        guard let panel else { return }
        if visible {
            panel.orderFrontRegardless()
            return
        }
        visible = true
        SoundCue.askOpen.play()
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
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1.0
        })
    }

    private func build() {
        let frame = NSScreen.main.map(defaultFrame(on:)) ?? NSRect(x: 240, y: 200, width: 620, height: 540)
        let p = AskPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        p.title = "Super Shout Ask"
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
        p.minSize = NSSize(width: 420, height: 340)
        p.delegate = self
        p.setFrameAutosaveName("SuperShoutAskWindow")
        p.contentViewController = NSHostingController(rootView: AskView(session: session))
        panel = p
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

/// Lightweight markdown renderer for answers: paragraphs, headings, bullet and
/// numbered lists, and fenced code blocks, with **bold** / *italic* / `code`
/// inline styling — so responses read like ChatGPT/Claude, not raw markdown.
struct MarkdownText: View {
    let text: String

    private enum Block {
        case heading(String)
        case paragraph(String)
        case bullet(String, indent: Int)
        case numbered(String, String)
        case code(String)
    }

    var body: some View {
        let blocks = Self.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let s):
                    Text(Self.inline(s))
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.top, 2)
                case .paragraph(let s):
                    Text(Self.inline(s))
                case .bullet(let s, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.inline(s))
                    }
                    .padding(.leading, 6 + CGFloat(indent) * 16)
                case .numbered(let marker, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).foregroundStyle(.secondary)
                        Text(Self.inline(s))
                    }
                    .padding(.leading, 6)
                case .code(let s):
                    Text(s)
                        .font(.system(size: 12.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var code: [String] = []
        var inCode = false

        func flushPara() {
            if !para.isEmpty {
                blocks.append(.paragraph(para.joined(separator: " ")))
                para = []
            }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code = []
                } else {
                    flushPara()
                }
                inCode.toggle()
                continue
            }
            if inCode { code.append(rawLine); continue }
            if line.isEmpty { flushPara(); continue }

            if let r = line.range(of: #"^#{1,4}\s+"#, options: .regularExpression) {
                flushPara()
                blocks.append(.heading(String(line[r.upperBound...])))
                continue
            }
            if let r = line.range(of: #"^[-*•]\s+"#, options: .regularExpression) {
                flushPara()
                let leading = rawLine.prefix(while: { $0 == " " }).count
                blocks.append(.bullet(String(line[r.upperBound...]), indent: min(leading / 2, 3)))
                continue
            }
            if let r = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
                flushPara()
                let marker = String(line[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
                blocks.append(.numbered(marker, String(line[r.upperBound...])))
                continue
            }
            para.append(line)
        }
        flushPara()
        if inCode && !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }
}

struct AskView: View {
    @ObservedObject var session: AskSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            conversation
            Divider().opacity(0.4)
            inputBar
        }
        .background(.regularMaterial)
        .onDrop(of: [UTType.fileURL.identifier, UTType.plainText.identifier],
                isTargeted: $session.dropTargeted,
                perform: acceptDrop)
        .overlay {
            if session.dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.mint, style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .padding(5)
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .foregroundStyle(.mint)
            Text("Super Shout — Ask")
                .font(.headline)
            if session.listening {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("Listening…").font(.caption.bold()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.red.opacity(0.12), in: Capsule())
            }
            Spacer()
            Button("New chat") { session.clear() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(session.messages.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if session.messages.isEmpty && !session.listening {
                        Text("Hold your Ask key and talk — the question and answer land here. Type follow-ups below.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(session.messages) { m in
                        if m.fromUser {
                            // ChatGPT-style: the user's message is a compact
                            // bubble on the right…
                            HStack {
                                Spacer(minLength: 60)
                                Text(m.text)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                            }
                            .id(m.id)
                        } else {
                            // …and the answer is clean full-width text with
                            // real formatting, no bubble.
                            MarkdownText(text: m.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                                .id(m.id)
                        }
                    }
                    if session.listening {
                        HStack {
                            Spacer(minLength: 60)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red)
                                Text(session.livePartial.isEmpty ? "Listening…" : session.livePartial)
                                    .foregroundStyle(session.livePartial.isEmpty ? .secondary : .primary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(Color.mint.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4]))
                            )
                        }
                        .id("live")
                    }
                    if session.pending {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .id("pending")
                    }
                }
                .font(.system(size: 14))
                .lineSpacing(3.5)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
            .onChange(of: session.messages.count) {
                if let last = session.messages.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .onChange(of: session.pending) {
                if session.pending { withAnimation { proxy.scrollTo("pending", anchor: .bottom) } }
            }
            .onChange(of: session.livePartial) {
                if session.listening { proxy.scrollTo("live", anchor: .bottom) }
            }
            .onChange(of: session.listening) {
                if session.listening { withAnimation { proxy.scrollTo("live", anchor: .bottom) } }
            }
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(session.attachments, id: \.self) { url in
                            HStack(spacing: 5) {
                                Image(systemName: url.hasDirectoryPath ? "folder" : "doc")
                                Text(url.lastPathComponent).lineLimit(1)
                                Button { session.removeAttachment(url) } label: {
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
                TextField("Paste or type a follow-up…", text: $session.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { session.followUp() }
                Button { session.chooseFiles() } label: { Image(systemName: "paperclip") }
                    .help("Attach files or folders")
                Button("Ask") { session.followUp() }
                    .disabled(session.pending || (session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.attachments.isEmpty))
                Button {
                    if let answer = session.lastAnswer {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(answer, forType: .string)
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy last answer")
                .disabled(session.lastAnswer == nil)
            }
            Text("Drop files or folders anywhere in the window to ask about them.")
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
                    DispatchQueue.main.async { session.addAttachments([url]) }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                provider.loadObject(ofClass: NSString.self) { value, _ in
                    guard let text = value as? String else { return }
                    DispatchQueue.main.async {
                        if !session.draft.isEmpty { session.draft += "\n" }
                        session.draft += text
                    }
                }
            }
        }
        return accepted
    }
}
