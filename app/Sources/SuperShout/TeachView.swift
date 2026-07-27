import SwiftUI

/// "Fix Last Transcript" — the user edits what Super Shout heard, and the app
/// learns the difference so it gets it right next time.
struct TeachView: View {
    let heard: String
    var onDone: () -> Void

    @State private var corrected: String
    @State private var preview: LearningEngine.Lesson = .init()
    @State private var saved = false

    init(heard: String, onDone: @escaping () -> Void) {
        self.heard = heard
        self.onDone = onDone
        _corrected = State(initialValue: heard)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Teach Super Shout")
                .font(.title2.bold())
            Text("Edit the text below to how it should have come out. Super Shout will remember the difference.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("What it heard").font(.caption).foregroundStyle(.secondary)
                Text(heard.isEmpty ? "— nothing dictated yet —" : heard)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("What you meant").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $corrected)
                    .font(.body)
                    .frame(height: 90)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
                    .onChange(of: corrected) { recompute() }
            }

            if !preview.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("It will learn").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(preview.mappings.enumerated()), id: \.offset) { _, m in
                        HStack(spacing: 8) {
                            Text("“\(m.heard)”").foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            Text("“\(m.corrected)”").bold()
                        }.font(.callout)
                    }
                    if !preview.newTerms.isEmpty {
                        Text("New vocabulary: \(preview.newTerms.joined(separator: ", "))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            HStack {
                if saved {
                    Label("Learned", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Close") { onDone() }
                Button("Teach It") {
                    LearningEngine.apply(preview)
                    saved = true
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .onAppear { recompute() }
    }

    private func recompute() {
        saved = false
        preview = LearningEngine.lesson(heard: heard, corrected: corrected)
    }
}
