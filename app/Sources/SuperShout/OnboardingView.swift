import SwiftUI
import AVFoundation
import Speech
import AppKit

/// First-run checklist: shows the three required permissions with live status,
/// buttons that take you straight to the right place, and a field to test
/// dictation once everything is green.
struct OnboardingView: View {
    @State private var micGranted = false
    @State private var speechGranted = false
    @State private var axGranted = false
    @State private var meetingGranted = false
    @State private var testText = ""

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var allGranted: Bool { micGranted && speechGranted && axGranted }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text("📣").font(.system(size: 34))
                VStack(alignment: .leading) {
                    Text("Welcome to Super Shout").font(.title2.bold())
                    Text("Three one-time permissions and you're dictating everywhere.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            permissionRow(
                granted: micGranted,
                title: "Microphone",
                detail: "Hears you while you hold the hotkey.",
                action: requestMic
            )
            permissionRow(
                granted: speechGranted,
                title: "Speech Recognition",
                detail: "Transcribes on-device. Nothing leaves this Mac.",
                action: requestSpeech
            )
            permissionRow(
                granted: axGranted,
                title: "Accessibility",
                detail: "Powers the global hotkey and inserts text at your cursor.",
                action: openAXSettings
            )
            permissionRow(
                granted: meetingGranted,
                title: "Computer Audio (optional)",
                detail: "Required only for Meeting Mode. Super Shout receives audio but never saves screen pixels.",
                action: requestMeeting
            )

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(allGranted
                     ? "All set — hold \(Settings.shared.dictateKeyDisplay) and speak. Try it here:"
                     : "Grant the permissions above, then try it here:")
                    .font(.callout)
                    .foregroundStyle(allGranted ? .primary : .secondary)
                TextEditor(text: $testText)
                    .font(.body)
                    .frame(height: 64)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
            }

            HStack(spacing: 14) {
                feature("person.2.wave.2", "Meetings", "Separate you and computer audio")
                feature("text.quote", "History", "Search and recall past transcripts")
                feature("text.badge.plus", "Snippets", "Expand reusable spoken shortcuts")
            }

            HStack {
                Button("Test Microphone…") { AppDelegate.shared?.openDiagnostic() }
                Button("Open Transcript Library…") { AppDelegate.shared?.openHistory() }
                Spacer()
                Button(allGranted ? "Done" : "Close") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620, height: 650)
        .onAppear(perform: refresh)
        .onReceive(poll) { _ in refresh() }
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).foregroundStyle(.orange)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
    }

    private func permissionRow(granted: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…", action: action)
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func refresh() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        axGranted = AXIsProcessTrusted()
        meetingGranted = CGPreflightScreenCaptureAccess()
    }

    private func requestMic() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async(execute: refresh) }
        default:
            openPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    private func requestSpeech() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { _ in DispatchQueue.main.async(execute: refresh) }
        default:
            openPane("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        }
    }

    private func openAXSettings() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        openPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func requestMeeting() {
        if !CGRequestScreenCaptureAccess() {
            openPane("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
        refresh()
    }

    private func openPane(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}
