import AVFoundation
import Speech

/// Streams microphone audio into SFSpeechRecognizer (on-device when available)
/// and reports live audio levels for the HUD waveform.
///
/// Continuity is the prime directive: speech must never be lost. Apple's
/// recognizer stops after ~1 minute and also self-finalizes during pauses, so
/// each recognition task writes into its own generation slot; whenever the
/// current task ends for any reason mid-dictation (rotation, pause
/// finalization, error, audio-route change), a fresh task takes over and the
/// finished segment is kept. Segments only ever accumulate.
final class Transcriber: NSObject {
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// generation → transcript parts for that task, assembled in order. A task
    /// usually has one part, but gains more when the recognizer resets itself
    /// mid-task (see updateSegment) — sealed parts are never overwritten.
    private var segments: [Int: [String]] = [:]
    private var generation = 0
    /// Old tasks kept alive until they deliver their final result.
    private var retiredTasks: [SFSpeechRecognitionTask] = []

    private var rotationTimer: Timer?
    private var finishing = false
    private var finishCompletion: ((String) -> Void)?
    private var fallbackWorkItem: DispatchWorkItem?

    /// Restart pacing: retries are throttled, never abandoned.
    private var lastRestartAt: Date?
    private var pendingRestart: DispatchWorkItem?
    /// True while a throttled restart is queued — the current task is already
    /// done, so a finish() during this window can complete immediately.
    private var awaitingRestart = false

    func begin() throws {
        segments = [:]
        generation = 0
        retiredTasks = []
        finishing = false
        lastRestartAt = nil
        awaitingRestart = false
        let locale = Locale(identifier: Settings.shared.language)
        recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "SuperShout", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable for \(locale.identifier)"])
        }

        startRecognitionTask()
        installTap()
        engine.prepare()
        try engine.start()

        // AirPods connecting, mic switching, etc. stop the engine mid-dictation.
        NotificationCenter.default.addObserver(
            self, selector: #selector(audioConfigurationChanged),
            name: .AVAudioEngineConfigurationChange, object: engine
        )

        // .common mode so rotation still fires while a menu is open or the
        // mouse is dragging — default-mode timers stall during event tracking.
        let timer = Timer(timeInterval: 45, repeats: true) { [weak self] _ in
            self?.rotateRecognitionTask()
        }
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    private func installTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            self?.reportLevel(buffer)
        }
    }

    private func startRecognitionTask() {
        guard let recognizer else { return }
        pendingRestart?.cancel()
        pendingRestart = nil
        awaitingRestart = false
        generation += 1
        let gen = generation
        segments[gen] = [""]

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
                    self.updateSegment(gen: gen, text: result.bestTranscription.formattedString)
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
                    } else if gen == self.generation {
                        NSLog("SuperShout: recognition error mid-dictation (gen \(gen)) — restarting")
                        self.restartMidDictation()
                    }
                }
            }
        }
    }

    /// Always keeps a live recognition task while dictating. Rapid successive
    /// restarts (e.g. repeated silence finalizations) are throttled to one per
    /// 0.5 s, but never abandoned — giving up would lose whatever is said next.
    private func restartMidDictation() {
        guard !finishing else { return }
        let now = Date()
        let rapid = lastRestartAt.map { now.timeIntervalSince($0) < 0.4 } ?? false
        lastRestartAt = now
        if !rapid {
            startRecognitionTask()
            return
        }
        awaitingRestart = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.finishing else { return }
            self.startRecognitionTask()
        }
        pendingRestart?.cancel()
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
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

    /// The audio engine stops when the input device changes (AirPods connect,
    /// mic unplugged). Reconnect immediately: retire the current task, retap
    /// the input at its new format, and keep going.
    @objc private func audioConfigurationChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finishing else { return }
            NSLog("SuperShout: audio configuration changed — reconnecting input")
            self.request?.endAudio()
            if let outgoing = self.task { self.retiredTasks.append(outgoing) }
            self.engine.inputNode.removeTap(onBus: 0)
            self.startRecognitionTask()
            self.installTap()
            if !self.engine.isRunning {
                self.engine.prepare()
                try? self.engine.start()
            }
        }
    }

    private func reapRetiredTasks() {
        retiredTasks.removeAll { $0.state == .completed || $0.state == .canceling }
    }

    /// Applies a new (partial or final) transcription for a task. The on-device
    /// recognizer sometimes resets mid-task after a pause and starts the
    /// transcript over — WITHOUT delivering isFinal first — so a blind
    /// overwrite would silently drop everything said before the pause. When
    /// the incoming text is dramatically shorter than what we have, seal the
    /// existing text and let the new text accumulate as a fresh part.
    private func updateSegment(gen: Int, text: String) {
        var parts = segments[gen] ?? [""]
        let current = parts.last ?? ""
        if current.count > 20, text.count < current.count / 2 {
            if current.hasPrefix(text) {
                // Truncated re-delivery of what we already have — keep the longer.
                NSLog("SuperShout: ignoring truncated update (gen \(gen), \(current.count)→\(text.count) chars)")
            } else {
                NSLog("SuperShout: recognizer reset detected (gen \(gen), \(current.count)→\(text.count) chars) — sealing earlier speech")
                parts.append(text)
            }
        } else {
            parts[parts.count - 1] = text
        }
        segments[gen] = parts
    }

    private func assembledTranscript() -> String {
        let ordered = segments.sorted { $0.key < $1.key }.flatMap(\.value).filter { !$0.isEmpty }
        // If the recognizer recovered after a detected reset and re-delivered
        // the full text, the sealed part is a prefix of its successor — drop
        // the duplicate rather than stuttering it.
        var out: [String] = []
        for (i, part) in ordered.enumerated() {
            if i + 1 < ordered.count, ordered[i + 1].lowercased().hasPrefix(part.lowercased()) { continue }
            out.append(part)
        }
        return out.joined(separator: " ")
    }

    /// Stops capture and completes as soon as the recognizer's final result
    /// lands (usually well under the fallback window).
    func finish(completion: @escaping (String) -> Void) {
        rotationTimer?.invalidate()
        rotationTimer = nil
        pendingRestart?.cancel()
        pendingRestart = nil
        finishing = true
        finishCompletion = completion
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()

        if awaitingRestart {
            // The current task already delivered its final result while a
            // restart was queued — every segment is sealed; nothing to wait on.
            completeFinish()
            return
        }

        let fallback = DispatchWorkItem { [weak self] in self?.completeFinish() }
        fallbackWorkItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: fallback)
    }

    private func completeFinish() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let completion = self.finishCompletion else { return }
            self.finishCompletion = nil
            self.fallbackWorkItem?.cancel()
            self.fallbackWorkItem = nil
            NotificationCenter.default.removeObserver(self)
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
        pendingRestart?.cancel()
        pendingRestart = nil
        finishing = true
        finishCompletion = nil
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        NotificationCenter.default.removeObserver(self)
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
