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

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        SFSpeechRecognizer.requestAuthorization { _ in }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
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
