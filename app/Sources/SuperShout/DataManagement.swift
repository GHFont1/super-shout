import AppKit
import AVFoundation
import Foundation
import Speech
import SwiftUI
import UniformTypeIdentifiers

private struct SuperShoutBackup: Codable {
    let formatVersion: Int
    let createdAt: Date
    let settingsPlist: Data
    let history: [TranscriptRecord]
}

enum PortableBackup {
    private static let portableKeys: Set<String> = [
        "hotkey", "keyActions", "keyEngines", "personalStyle", "businessContext",
        "removeFillers", "autoPunctuate", "smartLists", "smartSpacing", "aiPolishEnabled",
        "smartEntities", "handsFreeTap", "spokenCommands", "soundCues", "hudPosition",
        "voiceTutorEnabled", "polishModel", "aiProvider", "claudeCodeModel", "codexModel",
        "language", "audioInputUID", "enhanceQuietAudio", "personalDictionary", "vocabulary",
        "speechEngine", "voiceSnippets", "appModes", "historyRetention"
    ]

    static func export() -> String {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Super Shout Backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return "Export canceled." }
        let source = UserDefaults.standard.dictionaryRepresentation().filter { portableKeys.contains($0.key) }
        do {
            let plist = try PropertyListSerialization.data(fromPropertyList: source, format: .binary, options: 0)
            let backup = SuperShoutBackup(formatVersion: 1, createdAt: Date(), settingsPlist: plist, history: TranscriptHistory.shared.records)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(backup).write(to: url, options: .atomic)
            return "Backup exported. API keys and credentials were not included."
        } catch { return "Export failed: \(error.localizedDescription)" }
    }

    static func importBackup() -> String {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return "Import canceled." }
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let backup = try decoder.decode(SuperShoutBackup.self, from: Data(contentsOf: url))
            guard backup.formatVersion == 1,
                  let values = try PropertyListSerialization.propertyList(from: backup.settingsPlist, options: [], format: nil) as? [String: Any]
            else { return "That backup format is not supported." }
            for (key, value) in values where portableKeys.contains(key) { UserDefaults.standard.set(value, forKey: key) }
            TranscriptHistory.shared.mergeImported(backup.history)
            return "Settings and history imported. Restart Super Shout to apply every setting. Credentials were left unchanged."
        } catch { return "Import failed: \(error.localizedDescription)" }
    }
}

enum DiagnosticsReport {
    static func text() -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let micStatus = String(describing: AVCaptureDevice.authorizationStatus(for: .audio))
        let speechStatus = String(describing: SFSpeechRecognizer.authorizationStatus())
        let selected = Settings.shared.audioInputUID.isEmpty ? "System default" : (AudioInputDevice.available().first { $0.id == Settings.shared.audioInputUID }?.name ?? "Saved microphone unavailable")
        let safeLog = sanitizedLog()
        return """
        Super Shout Diagnostics
        Generated: \(ISO8601DateFormatter().string(from: Date()))
        App: \(version) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Hardware: \(machineModel())
        Speech engine setting: \(Settings.shared.speechEngine.displayName)
        Language: \(Settings.shared.language)
        Selected microphone: \(selected)
        Available microphones: \(AudioInputDevice.available().map(\.name).joined(separator: ", "))
        Quiet phone boost: \(Settings.shared.enhanceQuietAudio)
        Microphone permission: \(micStatus)
        Speech permission: \(speechStatus)
        Accessibility permission: \(AXIsProcessTrusted())
        Meeting audio permission: \(CGPreflightScreenCaptureAccess())
        Automatic update checks: \(bundle.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool ?? false)
        Automatic update install: \(bundle.object(forInfoDictionaryKey: "SUAutomaticallyUpdate") as? Bool ?? false)

        Sanitized recent log (transcript text, prompts, selections, and credentials excluded):
        \(safeLog)
        """
    }

    static func export() -> String {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Super Shout Diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return "Export canceled." }
        do { try text().write(to: url, atomically: true, encoding: .utf8); return "Diagnostics exported without transcript content or credentials." }
        catch { return "Export failed: \(error.localizedDescription)" }
    }

    private static func sanitizedLog() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SuperShout.log")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return "No log available." }
        let safeTerms = ["speech engine:", "SpeechAnalyzer:", "SpeechAnalyzer preparation failed:", "SpeechAnalyzer runtime failed:", "microphone selection failed uid=", "microphone:", "audio session:", "meeting speech lane", "event tap active"]
        return content.split(separator: "\n").suffix(800).map(String.init)
            .filter { line in safeTerms.contains { line.localizedCaseInsensitiveContains($0) } }
            .filter { !$0.localizedCaseInsensitiveContains("transcript: \"") && !$0.localizedCaseInsensitiveContains("instruction:") }
            .suffix(120).joined(separator: "\n")
    }

    private static func machineModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var chars = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        return String(cString: chars)
    }
}

struct DiagnosticsView: View {
    @State private var report = DiagnosticsReport.text()
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Privacy-safe diagnostics", systemImage: "stethoscope").font(.title2.bold())
            Text("This report contains device and permission state plus selected structural log lines. It excludes transcript text, AI prompts, selections, API keys, and business context.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView { Text(report).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Refresh") { report = DiagnosticsReport.text() }
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report, forType: .string) }
                Button("Export…") { message = DiagnosticsReport.export() }
                Spacer()
            }
        }.padding(20).frame(width: 680, height: 520)
        .alert("Super Shout", isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) { Button("OK") { message = "" } } message: { Text(message) }
    }
}
