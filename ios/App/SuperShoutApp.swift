import SwiftUI
import AVFoundation
import Speech

@main
struct SuperShoutApp: App {
    var body: some Scene {
        WindowGroup {
            OnboardingView()
        }
    }
}

/// Container app: walks through enabling the keyboard and granting the
/// permissions the keyboard extension can't request itself.
struct OnboardingView: View {
    @State private var micGranted = AVAudioSession.sharedInstance().recordPermission == .granted
    @State private var speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
    @State private var testText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Text("📣").font(.system(size: 40))
                        VStack(alignment: .leading) {
                            Text("Super Shout").font(.title2.bold())
                            Text("Dictation that types anywhere — private, on-device.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Set up (one time)") {
                    step(1, "Grant microphone access", done: micGranted) {
                        AVAudioSession.sharedInstance().requestRecordPermission { ok in
                            DispatchQueue.main.async { micGranted = ok }
                        }
                    }
                    step(2, "Grant speech recognition", done: speechGranted) {
                        SFSpeechRecognizer.requestAuthorization { status in
                            DispatchQueue.main.async { speechGranted = status == .authorized }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        stepLabel(3, "Add the keyboard", done: false)
                        Text("Settings → General → Keyboard → Keyboards → Add New Keyboard → Super Shout, then turn on Allow Full Access.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }

                Section("Try it") {
                    TextField("Switch to the Super Shout keyboard (🌐) and tap the mic…", text: $testText, axis: .vertical)
                        .lineLimit(4...8)
                }

                Section {
                    Text("Your voice is transcribed entirely on this iPhone by Apple's speech engine. Nothing is sent anywhere.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Super Shout")
        }
    }

    private func step(_ n: Int, _ title: String, done: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            stepLabel(n, title, done: done)
            Spacer()
            if !done { Button("Grant", action: action) }
        }
    }

    private func stepLabel(_ n: Int, _ title: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .foregroundStyle(done ? .green : .secondary)
            Text(title)
        }
    }
}
