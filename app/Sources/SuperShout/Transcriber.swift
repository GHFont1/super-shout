import AVFoundation
import Speech

/// Streams microphone audio into SFSpeechRecognizer (on-device when available)
/// and reports live audio levels for the HUD waveform.
///
/// SFSpeechRecognizer stops delivering results after roughly a minute, so the
/// recognition task is rotated every 50 s and the segments are stitched back
/// together — long hands-free dictations no longer get truncated.
final class Transcriber: NSObject {
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latestTranscript = ""
    private var completedSegments: [String] = []

    private var rotationTimer: Timer?
    private var finishing = false
    private var finishCompletion: ((String) -> Void)?
    private var fallbackWorkItem: DispatchWorkItem?

    func begin() throws {
        latestTranscript = ""
        completedSegments = []
        finishing = false
        let locale = Locale(identifier: Settings.shared.language)
        recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "SuperShout", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable for \(locale.identifier)"])
        }

        startRecognitionTask()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            self?.reportLevel(buffer)
        }
        engine.prepare()
        try engine.start()

        rotationTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            self?.rotateRecognitionTask()
        }
    }

    private func startRecognitionTask() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // Bias recognition toward the user's own vocabulary (UPC, ASIN, brand names…)
        request.contextualStrings = Array(Settings.shared.contextualStrings.prefix(200))
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.latestTranscript = result.bestTranscription.formattedString
                self.onPartial?(self.assembledTranscript())
                if result.isFinal, self.finishing {
                    self.completeFinish()
                }
            } else if error != nil, self.finishing {
                self.completeFinish()
            }
        }
    }

    /// Seals the current segment and starts a fresh recognition task while the
    /// audio engine keeps running, sidestepping the ~1 min recognition limit.
    private func rotateRecognitionTask() {
        guard !finishing else { return }
        if !latestTranscript.isEmpty {
            completedSegments.append(latestTranscript)
            latestTranscript = ""
        }
        request?.endAudio()
        task?.cancel()
        startRecognitionTask()
    }

    private func assembledTranscript() -> String {
        (completedSegments + [latestTranscript])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Stops capture and completes as soon as the recognizer's final result
    /// lands (usually well under the 0.9 s fallback window).
    func finish(completion: @escaping (String) -> Void) {
        rotationTimer?.invalidate()
        rotationTimer = nil
        finishing = true
        finishCompletion = completion
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()

        let fallback = DispatchWorkItem { [weak self] in self?.completeFinish() }
        fallbackWorkItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: fallback)
    }

    private func completeFinish() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let completion = self.finishCompletion else { return }
            self.finishCompletion = nil
            self.fallbackWorkItem?.cancel()
            self.fallbackWorkItem = nil
            self.task?.cancel()
            self.task = nil
            self.request = nil
            completion(self.assembledTranscript())
        }
    }

    func cancel() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        finishing = true
        finishCompletion = nil
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        latestTranscript = ""
        completedSegments = []
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
