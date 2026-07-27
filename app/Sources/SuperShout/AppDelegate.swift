import AppKit
import SwiftUI
import AVFoundation
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    let controller = DictationController()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "megaphone.fill", accessibilityDescription: "Super Shout")
        }
        rebuildMenu()

        controller.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.updateIcon(for: state)
                if case .idle = state { self?.rebuildMenu() }
            }
        }

        requestPermissions()
        controller.start()

        // Quiet update check shortly after launch, then daily.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { UpdateChecker.check() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in
            UpdateChecker.check()
        }

        // Voice Tutor studies recent dictation in the background (≤ every 6 h).
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { VoiceTutor.runIfDue() }
        tutorTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            VoiceTutor.runIfDue()
        }
    }

    private var tutorTimer: Timer?

    private var updateTimer: Timer?

    @objc private func checkForUpdates() {
        UpdateChecker.check(verbose: true)
    }

    private var axPollTimer: Timer?

    private var allPermissionsGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && SFSpeechRecognizer.authorizationStatus() == .authorized
            && AXIsProcessTrusted()
    }

    private func requestPermissions() {
        if !allPermissionsGranted {
            openOnboarding()
            axPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.allPermissionsGranted {
                    self.axPollTimer?.invalidate()
                    self.axPollTimer = nil
                    self.rebuildMenu()
                }
            }
        }
    }

    /// "Press 🌐 key to" system setting. 0 = Do Nothing; anything else fires a
    /// macOS action on an fn tap and fights our quick-tap hands-free toggle.
    private var fnKeyConflict: Bool {
        guard Settings.shared.action(for: .fn) != .off else { return false }
        let usage = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
        return (usage ?? 1) != 0
    }

    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateIcon(for state: DictationState) {
        let name: String
        switch state {
        case .idle: name = "megaphone.fill"
        case .listening: name = "waveform.circle.fill"
        case .processing: name = "ellipsis.circle.fill"
        }
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Super Shout")
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for key in HoldKey.allCases {
            let action = Settings.shared.action(for: key)
            guard action != .off else { continue }
            let line = NSMenuItem(title: "Hold \(key.displayName) — \(action.displayName)", action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
        }

        let words = Settings.shared.totalWordsDictated
        if words > 0 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            var title = "\(formatter.string(from: NSNumber(value: words)) ?? "\(words)") words dictated"
            // Speaking beats typing (~40 wpm) — show the difference once it's real.
            let savedMinutes = Double(words) / 40.0 - Settings.shared.totalSecondsDictated / 60.0
            if savedMinutes >= 2 {
                title += savedMinutes >= 90
                    ? String(format: " · ~%.1f hrs saved", savedMinutes / 60)
                    : " · ~\(Int(savedMinutes)) min saved"
            }
            let stats = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            stats.isEnabled = false
            menu.addItem(stats)
        }
        menu.addItem(.separator())

        if !AXIsProcessTrusted() {
            let warn = NSMenuItem(title: "⚠️ Grant Accessibility Access…", action: #selector(openOnboarding), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        if fnKeyConflict {
            let warn = NSMenuItem(
                title: "⚠️ fn also triggers a macOS 🌐 action — set “Press 🌐 key to” to “Do Nothing”…",
                action: #selector(openKeyboardSettings), keyEquivalent: ""
            )
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        if !controller.history.isEmpty {
            let historyItem = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            for (i, text) in controller.history.prefix(10).enumerated() {
                let title = text.count > 60 ? String(text.prefix(60)) + "…" : text
                let item = NSMenuItem(title: title, action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                sub.addItem(item)
            }
            historyItem.submenu = sub
            menu.addItem(historyItem)
            menu.addItem(.separator())
        }

        let undo = NSMenuItem(title: "Undo Last Insertion", action: #selector(undoLastInsertion), keyEquivalent: "z")
        undo.target = self
        undo.isEnabled = controller.canUndo
        menu.addItem(undo)

        let teach = NSMenuItem(title: "Fix Last Transcript…", action: #selector(openTeach), keyEquivalent: "e")
        teach.target = self
        teach.isEnabled = !controller.history.isEmpty
        menu.addItem(teach)

        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Super Shout", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func undoLastInsertion() {
        controller.undoLastInsertion()
        rebuildMenu()
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard sender.tag < controller.history.count else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(controller.history[sender.tag], forType: .string)
    }

    private var teachWindow: NSWindow?

    @objc func openTeach() {
        let heard = controller.history.first ?? ""
        let view = TeachView(heard: heard) { [weak self] in
            self?.teachWindow?.close()
            self?.teachWindow = nil
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Teach Super Shout"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        teachWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView()))
            window.title = "Welcome to Super Shout"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Super Shout Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
