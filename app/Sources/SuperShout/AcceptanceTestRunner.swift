import AppKit
import AVFoundation
import Foundation
import Speech

@MainActor
enum AcceptanceTestRunner {
    private static let micPhrase = "Super Shout acoustic phone test seven four nine"
    private static let meetingPhrase = "Super Shout computer audio meeting test eight two six"

    static func run() {
        Task {
            var results: [String: Any] = [
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            results["microphone"] = await microphoneTest()
            results["phoneSpeechFixture"] = await phoneSpeechFixtureTest()
            results["meeting"] = await meetingTest()
            let passed = (results["microphone"] as? [String: Any])?["passed"] as? Bool == true
                && (results["phoneSpeechFixture"] as? [String: Any])?["passed"] as? Bool == true
                && (results["meeting"] as? [String: Any])?["passed"] as? Bool == true
            results["passed"] = passed
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]),
               let output = String(data: data, encoding: .utf8) { print(output) }
            fflush(stdout)
            exit(passed ? 0 : 1)
        }
    }

    private static func microphoneTest() async -> [String: Any] {
        Transcriber.prepareModernEngine()
        try? await Task.sleep(for: .seconds(1))
        let transcriber = Transcriber()
        var partial = ""
        var peak: Float = 0
        transcriber.onPartial = { partial = $0 }
        transcriber.onLevel = { peak = max(peak, $0) }
        do { try transcriber.begin() }
        catch { return ["passed": false, "error": error.localizedDescription] }
        try? await Task.sleep(for: .milliseconds(700))
        await speak(micPhrase)
        try? await Task.sleep(for: .seconds(2))
        let final = await withCheckedContinuation { continuation in transcriber.finish { continuation.resume(returning: $0) } }
        let heard = final.isEmpty ? partial : final
        return [
            "passed": peak > 0.025,
            "peak": peak,
            "ambientSpeech": heard
        ]
    }

    private static func phoneSpeechFixtureTest() async -> [String: Any] {
        guard #available(macOS 26.0, *) else { return ["passed": true, "note": "Classic engine platform"] }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("supershout-phone-fixture-\(UUID().uuidString).aiff")
        await createSpeechFile(at: url, phrase: micPhrase)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forReading: url)
            let requested = Locale(identifier: Settings.shared.language)
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
                return ["passed": false, "error": "Locale unsupported"]
            }
            let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let analyzer = SpeechAnalyzer(modules: [module])
            let collector = Task { () throws -> String in
                var chunks: [Double: String] = [:]
                for try await result in module.results {
                    chunks[CMTimeGetSeconds(result.range.start)] = String(result.text.characters)
                }
                return chunks.sorted { $0.key < $1.key }.map(\.value).joined(separator: " ")
            }
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            let heard = try await collector.value
            let normalized = heard.lowercased()
            let wordsMatch = phraseMatches(heard, required: ["super", "shout", "acoustic", "phone", "test"])
            let numberMatch = normalized.contains("749") || phraseMatches(heard, required: ["seven", "four", "nine"])
            return ["passed": wordsMatch && numberMatch, "heard": heard]
        } catch { return ["passed": false, "error": error.localizedDescription] }
    }

    private static func meetingTest() async -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else {
            return ["passed": false, "error": "Computer audio permission is not granted"]
        }
        let meeting = MeetingTranscriptionController(saveToHistory: false, excludeCurrentProcessAudio: false)
        meeting.start()
        let started = await waitUntil(timeout: 8) { meeting.isRecording }
        guard started else { return ["passed": false, "error": meeting.status] }
        await speak(meetingPhrase)
        try? await Task.sleep(for: .seconds(3))
        meeting.stop()
        try? await Task.sleep(for: .seconds(3))
        let normalized = meeting.computerText.lowercased()
        let phrasePassed = phraseMatches(meeting.computerText, required: ["super", "shout", "computer", "audio", "meeting", "test"])
        let numberPassed = normalized.contains("8:26") || normalized.contains("826") || phraseMatches(meeting.computerText, required: ["eight", "two", "six"])
        return [
            "passed": phrasePassed && numberPassed,
            "computerHeard": meeting.computerText,
            "microphoneHeard": meeting.yourText,
            "computerSamples": meeting.computerSampleCount,
            "microphoneSamples": meeting.microphoneSampleCount
        ]
    }

    private static func speak(_ phrase: String) async {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-r", "155", phrase]
            try? process.run(); process.waitUntilExit()
        }.value
    }

    private static func createSpeechFile(at url: URL, phrase: String) async {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-r", "145", "-o", url.path, phrase]
            try? process.run(); process.waitUntilExit()
        }.value
    }

    private static func waitUntil(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    private static func phraseMatches(_ text: String, required: [String]) -> Bool {
        let normalized = text.lowercased()
        return required.filter { normalized.contains($0) }.count >= required.count - 1
    }
}
