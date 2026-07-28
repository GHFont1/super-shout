import AppKit
import SwiftUI

/// The AI Ask chat surface: a pull-down panel covering the top-right quadrant
/// of the screen. It slides down the moment the Ask key is pressed, shows the
/// live dictation as you speak, and stays up — answers and typed/spoken
/// follow-ups land in the same conversation until you close it.
final class AskSession: ObservableObject {
    struct Message: Identifiable {
        let id = UUID()
        let fromUser: Bool
        let text: String
    }

    @Published var messages: [Message] = []
    @Published var pending = false
    @Published var draft = ""
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
        guard !text.isEmpty, !pending else { return }
        draft = ""
        messages.append(Message(fromUser: true, text: text))
        send()
    }

    func clear() {
        messages = []
        pending = false
        draft = ""
    }

    private func send() {
        pending = true
        let transcript = messages
            .map { "\($0.fromUser ? "User" : "Assistant"): \($0.text)" }
            .joined(separator: "\n\n")
        ClaudePolish.ask(transcript, engine: engine) { [weak self] answer in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending = false
                self.messages.append(Message(fromUser: false, text: answer ?? "Sorry — the request failed. Check the AI provider in Settings."))
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

final class AskWindowController {
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

    private func targetFrame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let w = max(480, vf.width / 2)
        let h = max(420, vf.height / 2)
        return NSRect(x: vf.maxX - w, y: vf.maxY - h, width: w, height: h)
    }

    private func show() {
        if panel == nil { build() }
        guard let panel, let screen = NSScreen.main else { return }
        let final = targetFrame(on: screen)
        if visible {
            panel.setFrame(final, display: true)
            panel.orderFrontRegardless()
            return
        }
        visible = true
        SoundCue.askOpen.play()
        // Start tucked above the screen edge and slide down.
        var start = final
        start.origin.y = screen.frame.maxY
        panel.setFrame(start, display: false)
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(final, display: true)
            panel.animator().alphaValue = 1.0
        }
    }

    func hide() {
        guard let panel, visible else { return }
        visible = false
        var up = panel.frame
        up.origin.y = (panel.screen ?? NSScreen.main)?.frame.maxY ?? up.maxY
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(up, display: true)
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1.0
        })
    }

    private func build() {
        let p = AskPanel(
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
        p.contentViewController = NSHostingController(rootView: AskView(session: session))
        panel = p
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
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: 16,
            bottomTrailingRadius: 16, topTrailingRadius: 0
        ))
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 16,
                bottomTrailingRadius: 16, topTrailingRadius: 0
            )
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
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
            Button {
                AskWindowController.shared.hide()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Hide (Esc)")
            .keyboardShortcut(.cancelAction)
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
        HStack(spacing: 8) {
            TextField("Type a follow-up, or hold your Ask key to speak…", text: $session.draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { session.followUp() }
            Button("Ask") { session.followUp() }
                .disabled(session.pending || session.draft.trimmingCharacters(in: .whitespaces).isEmpty)
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
        .padding(10)
    }
}
