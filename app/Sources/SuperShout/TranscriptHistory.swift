import AppKit
import Foundation
import SwiftUI

final class TranscriptHistory: ObservableObject {
    static let shared = TranscriptHistory()
    @Published private(set) var records: [TranscriptRecord] = []

    private let url: URL
    private let queue = DispatchQueue(label: "com.gca.supershout.history", qos: .utility)

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Super Shout", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("transcripts.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([TranscriptRecord].self, from: data) {
            records = decoded
        } else {
            records = Settings.shared.historyStore.map { TranscriptRecord(text: $0, kind: .dictation) }
            persist()
        }
    }

    func add(_ record: TranscriptRecord) {
        records.insert(record, at: 0)
        if records.count > 2_000 { records.removeLast(records.count - 2_000) }
        Settings.shared.historyStore = Array(records.prefix(25).map(\.text))
        persist()
        NotificationCenter.default.post(name: .superShoutHistoryChanged, object: nil)
    }

    func delete(_ record: TranscriptRecord) {
        records.removeAll { $0.id == record.id }
        Settings.shared.historyStore = Array(records.prefix(25).map(\.text))
        persist()
        NotificationCenter.default.post(name: .superShoutHistoryChanged, object: nil)
    }

    func search(_ query: String) -> [TranscriptRecord] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return records }
        return records.compactMap { record -> (TranscriptRecord, Int)? in
            let haystack = record.searchableText
            let score = terms.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
            return score > 0 ? (record, score) : nil
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.createdAt > rhs.0.createdAt : lhs.1 > rhs.1
        }.map(\.0)
    }

    private func persist() {
        let snapshot = records
        let destination = url
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }
}

extension Notification.Name {
    static let superShoutHistoryChanged = Notification.Name("SuperShoutHistoryChanged")
}

struct TranscriptHistoryView: View {
    @ObservedObject private var store = TranscriptHistory.shared
    @State private var query = ""
    @State private var selection: TranscriptRecord.ID?
    @State private var recallAnswer = ""
    @State private var recalling = false

    private var results: [TranscriptRecord] { store.search(query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search everything you've said", text: $query)
                    .textFieldStyle(.plain)
                Button(recalling ? "Thinking…" : "Ask History") { askHistory() }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || recalling || !ClaudePolish.isConfigured)
            }
            .padding(12)
            Divider()
            HSplitView {
                List(results, selection: $selection) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.text.replacingOccurrences(of: "\n", with: " ")).lineLimit(2)
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(record.id)
                }
                .frame(minWidth: 280)
                if !recallAnswer.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Answer from your history", systemImage: "sparkles").font(.headline)
                            Text(recallAnswer).textSelection(.enabled)
                            Button("Back to transcript") { recallAnswer = "" }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minWidth: 360)
                } else if let record = results.first(where: { $0.id == selection }) ?? results.first {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(record.kind.rawValue.capitalized).font(.headline)
                            Text(record.text).textSelection(.enabled)
                            if let summary = record.summary, !summary.isEmpty {
                                Divider(); Text("Summary").font(.headline); Text(summary).textSelection(.enabled)
                            }
                            if !record.actionItems.isEmpty {
                                Divider(); Text("Action items").font(.headline)
                                ForEach(record.actionItems, id: \.self) { Text("• \($0)") }
                            }
                            Spacer()
                            HStack {
                                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.text, forType: .string) }
                                Button("Delete", role: .destructive) { store.delete(record); selection = nil }
                            }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minWidth: 360)
                } else {
                    ContentUnavailableView("No transcripts", systemImage: "text.quote", description: Text("Your dictation history will appear here."))
                }
            }
        }.frame(width: 760, height: 520)
    }

    private func askHistory() {
        recalling = true
        let formatter = ISO8601DateFormatter()
        let context = store.records.prefix(100).map { "[\(formatter.string(from: $0.createdAt))] \($0.text)" }.joined(separator: "\n\n")
        ClaudePolish.recallHistory(question: query, context: String(context.prefix(80_000))) { result in
            DispatchQueue.main.async { recallAnswer = result ?? "I couldn't search the history right now."; recalling = false }
        }
    }
}
