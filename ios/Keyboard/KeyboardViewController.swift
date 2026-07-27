import UIKit
import SwiftUI
import AVFoundation
import Speech

/// The Super Shout keyboard: a dictation pad. Tap the mic to talk, tap again
/// to stop — cleaned text is typed into whatever field is focused, with the
/// same smarts as the Mac app (entity fixes, spacing, punctuation).
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var hosting: UIHostingController<KeyboardView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        model.needsGlobe = needsInputModeSwitchKey
        model.onInsert = { [weak self] text in self?.insertCleaned(text) }
        model.onDelete = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        model.onSpace = { [weak self] in self?.textDocumentProxy.insertText(" ") }
        model.onReturn = { [weak self] in self?.textDocumentProxy.insertText("\n") }
        model.onGlobe = { [weak self] in self?.advanceToNextInputMode() }

        let host = UIHostingController(rootView: KeyboardView(model: model))
        hosting = host
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.heightAnchor.constraint(equalToConstant: 230)
        ])
        host.didMove(toParent: self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        model.stopListening()
        super.viewWillDisappear(animated)
    }

    private func insertCleaned(_ raw: String) {
        var options = CleanupEngine.CleanOptions()
        // Match the Mac behavior in ordinary fields; keyboards can't easily
        // detect search boxes, so keep it simple and standard.
        let cleaned = CleanupEngine.clean(raw, options: options)
        guard !cleaned.isEmpty else { return }
        let before = textDocumentProxy.documentContextBeforeInput
        let joined = SpacingEngine.join(cleaned, after: before?.last)
        textDocumentProxy.insertText(joined)
    }
}

/// Observable state + speech pipeline for the keyboard UI.
final class KeyboardModel: ObservableObject {
    @Published var listening = false
    @Published var partial = ""
    @Published var level: Float = 0
    @Published var errorText: String?
    var needsGlobe = true

    var onInsert: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onSpace: (() -> Void)?
    var onReturn: (() -> Void)?
    var onGlobe: (() -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""

    func toggleListening() {
        listening ? finishListening() : startListening()
    }

    private func startListening() {
        errorText = nil
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVAudioSession.sharedInstance().recordPermission == .granted else {
            errorText = "Open the Super Shout app first to grant mic + speech access."
            return
        }
        let rec = SFSpeechRecognizer(locale: Locale(identifier: Settings.shared.language))
        guard let rec, rec.isAvailable else {
            errorText = "Speech recognition unavailable."
            return
        }
        recognizer = rec
        latest = ""
        partial = ""

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorText = "Keyboards can't reach the mic on this device. Enable Allow Full Access in Settings."
            Log.write("iOS keyboard audio session failed: \(error.localizedDescription)")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.contextualStrings = Array(Settings.shared.contextualStrings.prefix(200))
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        task = rec.recognitionTask(with: req) { [weak self] result, _ in
            guard let self, let result else { return }
            DispatchQueue.main.async {
                self.latest = result.bestTranscription.formattedString
                self.partial = self.latest
            }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            self?.reportLevel(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            listening = true
        } catch {
            errorText = "Couldn't start the microphone."
            Log.write("iOS keyboard engine start failed: \(error.localizedDescription)")
        }
    }

    private func finishListening() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        listening = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.task?.cancel()
            self.task = nil
            self.request = nil
            let text = self.latest
            self.partial = ""
            if !text.isEmpty { self.onInsert?(text) }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func stopListening() {
        guard listening else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        listening = false
        partial = ""
    }

    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in stride(from: 0, to: n, by: 8) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n / 8 + 1))
        DispatchQueue.main.async { self.level = min(1, rms * 12) }
    }
}

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        VStack(spacing: 10) {
            Text(model.listening ? (model.partial.isEmpty ? "Listening…" : String(model.partial.suffix(70)))
                                 : (model.errorText ?? "Tap the mic and talk"))
                .font(.footnote)
                .foregroundStyle(model.errorText == nil ? .secondary : Color.red)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            Button {
                model.toggleListening()
            } label: {
                ZStack {
                    Circle()
                        .fill(model.listening ? Color.red : Color.orange)
                        .frame(width: 74, height: 74)
                        .scaleEffect(model.listening ? 1 + CGFloat(model.level) * 0.25 : 1)
                        .animation(.easeOut(duration: 0.1), value: model.level)
                    Image(systemName: model.listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                if model.needsGlobe {
                    key("globe") { model.onGlobe?() }
                }
                key("space", wide: true) { model.onSpace?() }
                key("delete.left") { model.onDelete?() }
                key("return") { model.onReturn?() }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
    }

    private func key(_ symbol: String, wide: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if symbol == "space" {
                    Text("space").font(.system(size: 15))
                } else {
                    Image(systemName: symbol).font(.system(size: 17))
                }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: wide ? .infinity : 60)
            .frame(height: 42)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
