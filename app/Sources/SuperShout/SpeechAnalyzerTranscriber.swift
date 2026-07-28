import AVFoundation
import Speech

protocol SpeechTranscribing: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    func begin() throws
    func finish(completion: @escaping (String) -> Void)
    func cancel()
}

/// Stable façade used by dictation, diagnostics, and future capture sources.
/// Automatic mode chooses SpeechAnalyzer only after its on-device assets are
/// installed; otherwise the proven SFSpeechRecognizer path starts instantly.
final class Transcriber: SpeechTranscribing {
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    private var backend: SpeechTranscribing?

    func begin() throws {
        let choice = Settings.shared.speechEngine
        let useAnalyzer: Bool
        if #available(macOS 26.0, *) {
            useAnalyzer = choice != .legacy && SpeechAnalyzerAssets.shared.ready
        } else { useAnalyzer = false }

        let selected: SpeechTranscribing
        if #available(macOS 26.0, *), useAnalyzer {
            selected = SpeechAnalyzerMicrophoneTranscriber()
            Log.write("speech engine: Apple SpeechAnalyzer")
        } else {
            selected = LegacyTranscriber()
            Log.write("speech engine: classic SFSpeechRecognizer" + (choice == .speechAnalyzer ? " (new model still preparing)" : ""))
        }
        selected.onPartial = { [weak self] in self?.onPartial?($0) }
        selected.onLevel = { [weak self] in self?.onLevel?($0) }
        backend = selected
        try selected.begin()
    }

    func finish(completion: @escaping (String) -> Void) { backend?.finish(completion: completion) }
    func cancel() { backend?.cancel(); backend = nil }

    static func prepareModernEngine() {
        if #available(macOS 26.0, *) { SpeechAnalyzerAssets.shared.prepare() }
    }
}

@available(macOS 26.0, *)
final class SpeechAnalyzerAssets {
    static let shared = SpeechAnalyzerAssets()
    private let lock = NSLock()
    private var preparing = false
    private var isReady = false

    var ready: Bool {
        lock.lock(); defer { lock.unlock() }
        return isReady
    }

    func prepare() {
        lock.lock()
        guard !preparing, !isReady else { lock.unlock(); return }
        preparing = true; lock.unlock()
        Task {
            do {
                let requested = Locale(identifier: Settings.shared.language)
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
                    Log.write("SpeechAnalyzer: locale unsupported: \(requested.identifier)"); finish(ready: false); return
                }
                let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                let status = await AssetInventory.status(forModules: [module])
                if status != .installed, let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    Log.write("SpeechAnalyzer: downloading \(locale.identifier) model")
                    try await request.downloadAndInstall()
                }
                _ = try? await AssetInventory.reserve(locale: locale)
                let finalStatus = await AssetInventory.status(forModules: [module])
                finish(ready: finalStatus == .installed)
                Log.write("SpeechAnalyzer: model status=\(String(describing: finalStatus))")
            } catch {
                Log.write("SpeechAnalyzer preparation failed: \(error.localizedDescription)")
                finish(ready: false)
            }
        }
    }

    private func finish(ready: Bool) {
        lock.lock(); isReady = ready; preparing = false; lock.unlock()
    }
}

@available(macOS 26.0, *)
final class SpeechAnalyzerMicrophoneTranscriber: SpeechTranscribing {
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var chunks: [Double: String] = [:]
    private var finishCompletion: ((String) -> Void)?
    private var finishing = false

    func begin() throws {
        chunks = [:]; finishing = false
        let selectedUID = Settings.shared.audioInputUID
        _ = AudioInputDevice.apply(uid: selectedUID, to: engine)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(800))
        continuation = pair.continuation

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            if let copied = Self.copyBuffer(buffer) {
                self.continuation?.yield(AnalyzerInput(buffer: copied))
            }
            self.reportLevel(buffer)
        }
        engine.prepare(); try engine.start()

        let localeID = Settings.shared.language
        resultTask = Task { [weak self] in
            guard let self else { return }
            let requested = Locale(identifier: localeID)
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else { return }
            let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(Settings.shared.contextualStrings.prefix(200))
            let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
            self.analyzer = analyzer
            do {
                try await analyzer.setContext(context)
                try await analyzer.prepareToAnalyze(in: format)
                self.analysisTask = Task { try? await analyzer.start(inputSequence: pair.stream) }
                for try await result in module.results {
                    let key = CMTimeGetSeconds(result.range.start)
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        self.chunks[key] = text
                        self.onPartial?(self.transcript)
                    }
                }
            } catch {
                Log.write("SpeechAnalyzer runtime failed: \(error.localizedDescription)")
            }
            await MainActor.run { if self.finishing { self.completeFinish() } }
        }
    }

    func finish(completion: @escaping (String) -> Void) {
        finishCompletion = completion; finishing = true
        engine.inputNode.removeTap(onBus: 0); engine.stop(); continuation?.finish()
        Task { [weak self] in
            guard let self else { return }
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            try? await Task.sleep(for: .milliseconds(350))
            await MainActor.run { self.completeFinish() }
        }
    }

    func cancel() {
        engine.inputNode.removeTap(onBus: 0); engine.stop(); continuation?.finish()
        analysisTask?.cancel(); resultTask?.cancel()
        Task { await analyzer?.cancelAndFinishNow() }
        finishCompletion = nil
    }

    private var transcript: String { chunks.sorted { $0.key < $1.key }.map(\.value).filter { !$0.isEmpty }.joined(separator: " ") }

    private func completeFinish() {
        guard let completion = finishCompletion else { return }
        finishCompletion = nil; completion(transcript)
    }

    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength); guard count > 0 else { return }
        var sum: Float = 0
        for i in stride(from: 0, to: count, by: 8) { sum += data[i] * data[i] }
        let level = min(1, sqrt(sum / Float(count / 8 + 1)) * 12)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    private static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let src = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(src.count, dst.count) {
            guard let srcData = src[index].mData, let dstData = dst[index].mData else { continue }
            let bytes = Int(min(src[index].mDataByteSize, dst[index].mDataByteSize))
            memcpy(dstData, srcData, bytes)
            dst[index].mDataByteSize = UInt32(bytes)
        }
        return copy
    }
}
