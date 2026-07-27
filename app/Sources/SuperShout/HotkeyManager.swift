import AppKit

/// Watches all three hold keys globally via a CGEvent tap; each key can carry
/// a different action (dictate / AI edit / AI compose). Hold = push-to-talk,
/// quick tap (< 0.35 s) toggles hands-free for that key's mode. While
/// dictation is live, Esc cancels it (swallowed so the frontmost app never
/// sees the keypress).
final class HotkeyManager {
    var onPress: ((HoldKey) -> Void)?
    var onRelease: ((HoldKey) -> Void)?
    var onQuickTap: ((HoldKey) -> Void)?
    var onEscape: (() -> Void)?
    var isListening: (() -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyDown: [HoldKey: Bool] = [:]
    private var pressStartedAt: [HoldKey: Date] = [:]

    private var retryTimer: Timer?

    /// Whether any configured hold key is physically down right now.
    var keyCurrentlyDown: Bool { keyDown.values.contains(true) }

    func start() {
        attemptStart()
        // Permission may be granted after launch — keep retrying until the tap exists.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.eventTap != nil {
                self.retryTimer?.invalidate()
                self.retryTimer = nil
            } else {
                self.attemptStart()
            }
        }
    }

    private func attemptStart() {
        guard eventTap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = manager.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                if keyCode == 53, manager.isListening?() == true {  // Esc cancels dictation
                    DispatchQueue.main.async { manager.onEscape?() }
                    return nil  // swallow so the focused app doesn't also react
                }
                return Unmanaged.passUnretained(event)
            }
            manager.handleFlagsChanged(event)
            return Unmanaged.passUnretained(event)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,  // active tap: covered by Accessibility (listen-only would need Input Monitoring)
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        )
        guard let eventTap else {
            NSLog("SuperShout: failed to create event tap — grant Accessibility/Input Monitoring permission")
            return
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        NSLog("SuperShout: event tap active (AX trusted=\(AXIsProcessTrusted()))")
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let key = HoldKey.allCases.first(where: { $0.keyCode == keyCode }) else { return }
        guard Settings.shared.action(for: key) != .off else { return }

        let isDown: Bool
        switch key {
        case .fn: isDown = event.flags.contains(.maskSecondaryFn)
        case .rightCommand: isDown = event.flags.contains(.maskCommand)
        case .rightOption: isDown = event.flags.contains(.maskAlternate)
        }

        let wasDown = keyDown[key] ?? false
        if isDown && !wasDown {
            keyDown[key] = true
            pressStartedAt[key] = Date()
            DispatchQueue.main.async { self.onPress?(key) }
        } else if !isDown && wasDown {
            keyDown[key] = false
            let held = pressStartedAt[key].map { Date().timeIntervalSince($0) } ?? 1
            DispatchQueue.main.async {
                if held < 0.35 {
                    self.onQuickTap?(key)
                } else {
                    self.onRelease?(key)
                }
            }
        }
    }
}
