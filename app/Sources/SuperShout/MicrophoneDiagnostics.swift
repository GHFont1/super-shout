import AVFoundation
import SwiftUI

final class MicrophoneDiagnostic: ObservableObject {
    @Published var level: Float = 0
    @Published var peak: Float = 0
    @Published var status = "Ready to test"
    @Published var transcript = ""
    @Published var isTesting = false

    private var transcriber: Transcriber?

    func start() {
        guard !isTesting else { return }
        transcript = ""
        peak = 0
        let t = Transcriber()
        transcriber = t
        t.onLevel = { [weak self] value in
            self?.level = value
            self?.peak = max(self?.peak ?? 0, value)
            if value < 0.025 { self?.status = "Very quiet — move closer or choose another mic" }
            else if value > 0.92 { self?.status = "Clipping — move the phone farther away" }
            else { self?.status = "Good signal — say: Super Shout can hear this phone" }
        }
        t.onPartial = { [weak self] text in self?.transcript = text }
        do {
            try t.begin()
            isTesting = true
            status = "Listening…"
        } catch {
            transcriber = nil
            status = error.localizedDescription
        }
    }

    func stop() {
        guard let transcriber else { return }
        transcriber.finish { [weak self] text in
            self?.transcript = text
            self?.isTesting = false
            self?.transcriber = nil
            if text.isEmpty { self?.status = "No speech detected — verify the selected microphone" }
            else { self?.status = "Test complete" }
        }
    }

    func cancel() {
        transcriber?.cancel()
        transcriber = nil
        isTesting = false
    }
}

struct MicrophoneDiagnosticView: View {
    @StateObject private var diagnostic = MicrophoneDiagnostic()

    private var deviceName: String {
        if let selected = AudioInputDevice.available().first(where: { $0.id == Settings.shared.audioInputUID }) { return selected.name }
        return AudioInputDevice.systemDefaultName() ?? "System default"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "mic.and.signal.meter.fill").font(.system(size: 28)).foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text("Microphone Check").font(.title2.bold())
                    Text(deviceName).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(diagnostic.level > 0.92 ? .red : diagnostic.level > 0.025 ? .green : .yellow)
                            .frame(width: max(4, geo.size.width * CGFloat(diagnostic.level)))
                    }
                }.frame(height: 14)
                Text(diagnostic.status).font(.callout).foregroundStyle(.secondary)
            }
            GroupBox("What Super Shout hears") {
                Text(diagnostic.transcript.isEmpty ? "Your test phrase will appear here." : diagnostic.transcript)
                    .foregroundStyle(diagnostic.transcript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                    .padding(6).textSelection(.enabled)
            }
            HStack {
                Button(diagnostic.isTesting ? "Stop Test" : "Start Test") {
                    diagnostic.isTesting ? diagnostic.stop() : diagnostic.start()
                }.keyboardShortcut(.defaultAction)
                Button("Open Sound Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                }
                Spacer()
                Text("Quiet phone boost: \(Settings.shared.enhanceQuietAudio ? "On" : "Off")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(22).frame(width: 500, height: 330).onDisappear { diagnostic.cancel() }
    }
}
