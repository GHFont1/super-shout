import AVFoundation
import Speech

/// Streams microphone audio into SFSpeechRecognizer (on-device when available)
/// and reports live audio levels for the HUD waveform.
///
/// SFSpeechRecognizer stops delivering results after roughly a minute, so a
/// fresh recognition task takes over every 45 s while the audio engine keeps
/// running. Each task writes into its own generation slot and is allowed to
/// finalize naturally after handoff — no cancel race, no words lost at the
/// seam, no length limit.
final class Transcriber: NSObject {
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// generation → best transcript for that task, assembled in order.
    private var segments: [Int: String] = [:]
    private var generation = 0
    /// Old tasks kept alive until they deliver their final result.
    private var retiredTasks: [SFSpeechRecognitionTask] = []

    private var rotationTimer: Timer?
    private var finishing = false
    private var finishCompletion: ((String) -> Void)?
    private var fallbackWorkItem: DispatchWorkItem?

    func begin() throws {
        segments = [:]
        generation = 0
        retiredTasks = []
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

        rotationTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            self?.rotateRecognitionTask()
        }
    }

    private func startRecognitionTask() {
        guard let recognizer else { return }
        generation += 1
        let gen = generation
        segments[gen] = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        // Bias recognition toward the user's own vocabulary (UPC, ASIN, brand names…)
        request.contextualStrings = Array(Settings.shared.contextualStrings.prefix(200))
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let result {
                    let text = result.bestTranscription.formattedString
                    if !text.isEmpty { self.autoRestartCount = 0 }
                    self.segments[gen] = text
                    self.onPartial?(self.assembledTranscript())
                    if result.isFinal {
                        self.reapRetiredTasks()
                        if self.finishing {
                            if gen == self.generation { self.completeFinish() }
                        } else if gen == self.generation {
                            // The recognizer finalized itself after a pause in
                            // speech. Seal this segment and hand off to a fresh
                            // task so nothing after the pause is lost.
                            NSLog("SuperShout: recognizer self-finalized (gen \(gen)) — continuing with next segment")
                            self.restartMidDictation()
                        }
                    }
                } else if error != nil {
                    self.reapRetiredTasks()
                    if self.finishing {
                        if gen == self.generation { self.completeFinish() }
                    } else if gen == self.generation, self.engine.isRunning {
                        NSLog("SuperShout: recognition error mid-dictation (gen \(gen)) — restarting")
                        self.restartMidDictation()
                    }
                }
            }
        }
    }

    /// Restart guard so a persistently failing recognizer can't spin.
    private var autoRestartCount = 0

    private func restartMidDictation() {
        autoRestartCount += 1
        guard autoRestartCount <= 8 else {
            NSLog("SuperShout: too many recognizer restarts — giving up until finish")
            return
        }
        startRecognitionTask()
    }

    /// Hands the audio stream to a fresh recognition task before the current
    /// one hits the ~1 min ceiling. The outgoing task keeps running on the
    /// audio it already has and finalizes its own segment.
    private func rotateRecognitionTask() {
        guard !finishing else { return }
        let outgoingRequest = request
        if let outgoing = task { retiredTasks.append(outgoing) }
        // New task first: the tap's `self?.request` now feeds the new request,
        // so no buffers fall between the two.
        startRecognitionTask()
        outgoingRequest?.endAudio()
        NSLog("SuperShout: rotated recognition task (generation \(generation))")
    }

    private func reapRetiredTasks() {
        retiredTasks.removeAll { $0.state == .completed || $0.state == .canceling }
    }

    private func assembledTranscript() -> String {
        segments.sorted { $0.key < $1.key }
            .map(\.value)
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
            self.retiredTasks.forEach { $0.cancel() }
            self.retiredTasks = []
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
        retiredTasks.forEach { $0.cancel() }
        retiredTasks = []
        segments = [:]
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
