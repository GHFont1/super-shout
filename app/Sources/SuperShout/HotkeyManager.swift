import AppKit

/// Listens for the configured hold-key globally via a CGEvent tap.
/// Hold = push-to-talk. Quick tap (< 0.35 s) toggles hands-free lock.
/// While dictation is live, Esc cancels it (and is swallowed so the
/// frontmost app never sees the keypress).
final class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onQuickTap: (() -> Void)?
    var onEscape: (() -> Void)?
    var isListening: (() -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyIsDown = false
    private var pressStartedAt: Date?

    private var retryTimer: Timer?

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
        let target = Settings.shared.hotkey
        guard keyCode == target.keyCode else { return }

        let isDown: Bool
        switch target {
        case .fn: isDown = event.flags.contains(.maskSecondaryFn)
        case .rightCommand: isDown = event.flags.contains(.maskCommand)
        case .rightOption: isDown = event.flags.contains(.maskAlternate)
        }

        if isDown && !keyIsDown {
            keyIsDown = true
            pressStartedAt = Date()
            DispatchQueue.main.async { self.onPress?() }
        } else if !isDown && keyIsDown {
            keyIsDown = false
            let held = pressStartedAt.map { Date().timeIntervalSince($0) } ?? 1
            DispatchQueue.main.async {
                if held < 0.35 {
                    self.onQuickTap?()
                } else {
                    self.onRelease?()
                }
            }
        }
    }
}
