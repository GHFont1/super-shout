import AppKit
import SwiftUI
import AVFoundation
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    let controller = DictationController()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

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
    }

    private var axPollTimer: Timer?

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        SFSpeechRecognizer.requestAuthorization { _ in }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            showAccessibilityAlert()
            axPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                if AXIsProcessTrusted() {
                    self?.axPollTimer?.invalidate()
                    self?.axPollTimer = nil
                    self?.rebuildMenu()
                }
            }
        }
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Enable Accessibility for Super Shout"
        alert.informativeText = "The dictation hotkey needs Accessibility access.\n\nSystem Settings → Privacy & Security → Accessibility → turn ON Super Shout.\n\nDictation starts working the moment you flip the switch — no restart needed."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
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
        let hk = Settings.shared.hotkey.displayName
        menu.addItem(withTitle: "Super Shout — hold \(hk) to talk", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        if !AXIsProcessTrusted() {
            let warn = NSMenuItem(title: "⚠️ Grant Accessibility Access…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        if !controller.history.isEmpty {
            let historyItem = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (i, text) in controller.history.enumerated() {
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

        let teach = NSMenuItem(title: "Fix Last Transcript…", action: #selector(openTeach), keyEquivalent: "e")
        teach.target = self
        teach.isEnabled = !controller.history.isEmpty
        menu.addItem(teach)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Super Shout", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
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
