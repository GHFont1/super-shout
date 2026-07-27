import AVFoundation
import Speech

/// Streams microphone audio into SFSpeechRecognizer (on-device when available)
/// and reports live audio levels for the HUD waveform.
final class Transcriber: NSObject {
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latestTranscript = ""

    func begin() throws {
        latestTranscript = ""
        let locale = Locale(identifier: Settings.shared.language)
        recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "SuperShout", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable for \(locale.identifier)"])
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // Bias recognition toward the user's own vocabulary (UPC, ASIN, brand names…)
        request.contextualStrings = Array(Settings.shared.contextualStrings.prefix(200))
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            self.latestTranscript = result.bestTranscription.formattedString
            self.onPartial?(self.latestTranscript)
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            self?.reportLevel(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops capture and returns the final transcript once recognition settles.
    func finish(completion: @escaping (String) -> Void) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()

        // Give the recognizer a short window to emit its final result.
        let snapshotDeadline = DispatchTime.now() + 0.7
        DispatchQueue.main.asyncAfter(deadline: snapshotDeadline) { [weak self] in
            guard let self else { return }
            self.task?.cancel()
            self.task = nil
            self.request = nil
            completion(self.latestTranscript)
        }
    }

    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        latestTranscript = ""
    }

    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in stride(from: 0, to: n, by: 8) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n / 8 + 1))
        let level = min(1, rms * 12)
        DispatchQueue.main.async { self.onLevel?(level) }
    }
}
