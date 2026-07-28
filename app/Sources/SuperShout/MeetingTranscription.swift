import AppKit
import CoreMedia
import ScreenCaptureKit
import Speech
import SwiftUI

private final class MeetingSpeechLane {
    var onText: ((String) -> Void)?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Settings.shared.language))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var segments: [Int: String] = [:]
    private var generation = 0
    private let lock = NSLock()

    func start() { startTask() }

    func append(_ sample: CMSampleBuffer) {
        lock.lock(); let active = request; lock.unlock()
        active?.appendAudioSampleBuffer(sample)
    }

    func rotate() {
        guard let old = request else { return }
        startTask()
        old.endAudio()
    }

    func stop() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    var text: String { segments.sorted { $0.key < $1.key }.map(\.value).filter { !$0.isEmpty }.joined(separator: " ") }

    private func startTask() {
        generation += 1
        let gen = generation
        segments[gen] = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = Array(Settings.shared.contextualStrings.prefix(200))
        if recognizer?.supportsOnDeviceRecognition == true { request.requiresOnDeviceRecognition = true }
        lock.lock(); self.request = request; lock.unlock()
        task = recognizer?.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            DispatchQueue.main.async {
                self.segments[gen] = result.bestTranscription.formattedString
                self.onText?(self.text)
                if result.isFinal, gen == self.generation { self.startTask() }
            }
        }
    }
}

final class MeetingTranscriptionController: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    @Published var isRecording = false
    @Published var status = "Ready"
    @Published var yourText = ""
    @Published var computerText = ""
    @Published var summary = ""
    @Published var isSummarizing = false

    private let you = MeetingSpeechLane()
    private let computer = MeetingSpeechLane()
    private var stream: SCStream?
    private var legacyMic: Transcriber?
    private var rotationTimer: Timer?
    private let audioQueue = DispatchQueue(label: "com.gca.supershout.meeting-audio", qos: .userInitiated)
    private var startedAt: Date?

    override init() {
        super.init()
        you.onText = { [weak self] in self?.yourText = $0 }
        computer.onText = { [weak self] in self?.computerText = $0 }
    }

    func start() {
        guard !isRecording else { return }
        status = "Requesting system audio access…"
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { throw NSError(domain: "SuperShout", code: 40, userInfo: [NSLocalizedDescriptionKey: "No display is available to capture audio."]) }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 2; config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
                if #available(macOS 15.0, *) {
                    config.captureMicrophone = true
                    let uid = Settings.shared.audioInputUID
                    if !uid.isEmpty { config.microphoneCaptureDeviceID = uid }
                }
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
                if #available(macOS 15.0, *) {
                    try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
                }
                self.stream = stream
                computer.start()
                if #available(macOS 15.0, *) {
                    you.start()
                } else {
                    let mic = Transcriber()
                    mic.onPartial = { [weak self] in self?.yourText = $0 }
                    try mic.begin()
                    legacyMic = mic
                }
                try await stream.startCapture()
                startedAt = Date(); isRecording = true; status = "Recording microphone + computer audio"
                rotationTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
                    self?.you.rotate(); self?.computer.rotate()
                }
            } catch {
                status = "Could not start: \(error.localizedDescription)"
                you.stop(); computer.stop(); stream = nil
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        rotationTimer?.invalidate(); rotationTimer = nil
        let activeStream = stream
        stream = nil
        Task { try? await activeStream?.stopCapture() }
        you.stop(); computer.stop()
        legacyMic?.finish { [weak self] in self?.yourText = $0 }
        legacyMic = nil
        isRecording = false
        status = "Recording stopped"
        saveRecord(summary: nil)
    }

    func summarize() {
        guard !yourText.isEmpty || !computerText.isEmpty else { return }
        guard ClaudePolish.isConfigured else { status = "Set up an AI provider in Settings to summarize"; return }
        isSummarizing = true; status = "Creating summary and action items…"
        ClaudePolish.summarizeMeeting(markdownTranscript) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSummarizing = false
                self.summary = result ?? ""
                self.status = result == nil ? "Summary failed" : "Summary ready"
                if let result { self.saveRecord(summary: result) }
            }
        }
    }

    var markdownTranscript: String {
        var output = "# Meeting Transcript\n\n"
        output += "Date: \(Date().formatted(date: .long, time: .shortened))\n\n"
        if !yourText.isEmpty { output += "## You\n\n\(yourText)\n\n" }
        if !computerText.isEmpty { output += "## Computer audio\n\n\(computerText)\n\n" }
        if !summary.isEmpty { output += "## Summary and action items\n\n\(summary)\n" }
        return output
    }

    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Super Shout Meeting \(Date().formatted(.iso8601.year().month().day())).md"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url { try? markdownTranscript.write(to: url, atomically: true, encoding: .utf8) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        if type == .audio { computer.append(sampleBuffer) }
        if #available(macOS 15.0, *), type == .microphone { you.append(sampleBuffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.status = "Capture stopped: \(error.localizedDescription)"; self?.stop() }
    }

    private func saveRecord(summary: String?) {
        let text = markdownTranscript
        guard text.count > 40 else { return }
        TranscriptHistory.shared.add(TranscriptRecord(text: text, kind: .meeting, duration: startedAt.map { Date().timeIntervalSince($0) }, summary: summary))
    }
}

extension MeetingTranscriptionController: @unchecked Sendable {}

struct MeetingTranscriptionView: View {
    @StateObject private var controller = MeetingTranscriptionController()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(controller.isRecording ? .red : .secondary).frame(width: 10, height: 10)
                Text(controller.status).font(.headline)
                Spacer()
                Button(controller.isRecording ? "Stop" : "Start") { controller.isRecording ? controller.stop() : controller.start() }
                    .keyboardShortcut(.defaultAction)
                Button("Summarize") { controller.summarize() }.disabled(controller.isRecording || controller.isSummarizing)
                Button("Export Markdown…") { controller.export() }.disabled(controller.yourText.isEmpty && controller.computerText.isEmpty)
            }.padding(14)
            Divider()
            HSplitView {
                transcriptPane("You", icon: "mic.fill", text: controller.yourText)
                transcriptPane("Computer", icon: "speaker.wave.2.fill", text: controller.computerText)
            }
            if !controller.summary.isEmpty {
                Divider()
                ScrollView { Text(controller.summary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14) }
                    .frame(height: 150)
            }
        }.frame(width: 820, height: controller.summary.isEmpty ? 500 : 650)
    }

    private func transcriptPane(_ title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline).padding([.top, .horizontal], 14)
            ScrollView { Text(text.isEmpty ? "Waiting for speech…" : text).foregroundStyle(text.isEmpty ? .secondary : .primary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(14) }
        }.frame(minWidth: 350)
    }
}

final class MeetingWindowController {
    static let shared = MeetingWindowController()
    private var window: NSWindow?
    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: MeetingTranscriptionView()))
            window.title = "Meeting Transcription"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
