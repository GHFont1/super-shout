import AppKit
import SwiftUI

/// The AI Ask chat window: spoken questions land here with answers from the
/// configured provider, plus a typed follow-up field — a mini chat box.
final class AskSession: ObservableObject {
    struct Message: Identifiable {
        let id = UUID()
        let fromUser: Bool
        let text: String
    }

    @Published var messages: [Message] = []
    @Published var pending = false
    @Published var draft = ""

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

    private func send() {
        pending = true
        let transcript = messages
            .map { "\($0.fromUser ? "User" : "Assistant"): \($0.text)" }
            .joined(separator: "\n\n")
        ClaudePolish.ask(transcript) { [weak self] answer in
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

final class AskWindowController {
    static let shared = AskWindowController()
    private var window: NSWindow?
    private let session = AskSession()

    func ask(_ question: String, selection: String?) {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        session.ask(question, selection: selection)
    }

    private func build() {
        let w = NSWindow(contentViewController: NSHostingController(rootView: AskView(session: session)))
        w.title = "Super Shout — Ask"
        w.styleMask = [.titled, .closable, .resizable]
        w.setContentSize(NSSize(width: 540, height: 500))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
    }
}

struct AskView: View {
    @ObservedObject var session: AskSession

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(session.messages) { m in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(m.fromUser ? "You" : "Assistant")
                                    .font(.caption.bold())
                                    .foregroundStyle(m.fromUser ? Color.orange : Color.secondary)
                                Text(m.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(10)
                            .background(
                                m.fromUser ? Color.orange.opacity(0.08) : Color(nsColor: .textBackgroundColor).opacity(0.55),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .id(m.id)
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
                    .padding(14)
                }
                .onChange(of: session.messages.count) {
                    if let last = session.messages.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                .onChange(of: session.pending) {
                    if session.pending { withAnimation { proxy.scrollTo("pending", anchor: .bottom) } }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Follow up…", text: $session.draft)
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
        .frame(minWidth: 460, minHeight: 380)
    }
}
