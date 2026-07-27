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
    /// Fired when a left-side modifier is held alone for a while — the user
    /// almost certainly meant the right-side hold key.
    var onMisusedModifier: (() -> Void)?

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
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = manager.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown || type == .keyUp {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                if type == .keyDown {
                    manager.sawOtherKey = true
                    if keyCode == 53, manager.isListening?() == true {  // Esc cancels dictation
                        DispatchQueue.main.async { manager.onEscape?() }
                        return nil  // swallow so the focused app doesn't also react
                    }
                }
                // Non-modifier hold keys (F-keys) arrive here, not as flagsChanged.
                if let key = HoldKey.allCases.first(where: { !$0.isModifier && $0.keyCode == keyCode }),
                   Settings.shared.action(for: key) != .off {
                    if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
                    manager.updateKeyState(key, isDown: type == .keyDown)
                    return nil  // swallow so the F-key's normal function doesn't also fire
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

    /// Left ⌘ (55), left ⌥ (58), left ⌃ (59), right ⌃ (62) — not hold keys
    /// (shortcuts live there), but a lone long hold gets a helpful hint.
    private static let hintKeys: Set<Int64> = [55, 58, 59, 62]
    private var hintKeyDownAt: [Int64: Date] = [:]
    fileprivate var sawOtherKey = false

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if Self.hintKeys.contains(keyCode) {
            handleHintKey(keyCode, event: event)
            return
        }
        guard let key = HoldKey.allCases.first(where: { $0.keyCode == keyCode }) else {
            Log.write("flagsChanged ignored: keyCode=\(keyCode) flags=\(String(event.flags.rawValue, radix: 16))")
            return
        }
        Log.write("flagsChanged: key=\(key.rawValue) action=\(Settings.shared.action(for: key).rawValue) flags=\(String(event.flags.rawValue, radix: 16))")
        guard Settings.shared.action(for: key) != .off else { return }

        let isDown: Bool
        switch key {
        case .fn: isDown = event.flags.contains(.maskSecondaryFn)
        case .rightCommand: isDown = event.flags.contains(.maskCommand)
        case .rightOption: isDown = event.flags.contains(.maskAlternate)
        case .rightShift: isDown = event.flags.contains(.maskShift)
        default: return  // F-keys never arrive as flagsChanged
        }

        updateKeyState(key, isDown: isDown)
    }

    private func updateKeyState(_ key: HoldKey, isDown: Bool) {
        let wasDown = keyDown[key] ?? false
        if isDown && !wasDown {
            keyDown[key] = true
            pressStartedAt[key] = Date()
            Log.write("press: \(key.rawValue)")
            DispatchQueue.main.async { self.onPress?(key) }
        } else if !isDown && wasDown {
            keyDown[key] = false
            let held = pressStartedAt[key].map { Date().timeIntervalSince($0) } ?? 1
            Log.write("release: \(key.rawValue) held=\(String(format: "%.2f", held))s")
            DispatchQueue.main.async {
                if held < 0.35 {
                    self.onQuickTap?(key)
                } else {
                    self.onRelease?(key)
                }
            }
        }
    }

    private func handleHintKey(_ keyCode: Int64, event: CGEvent) {
        let mask: CGEventFlags = keyCode == 55 ? .maskCommand : keyCode == 58 ? .maskAlternate : .maskControl
        let isDown = event.flags.contains(mask)
        if isDown && hintKeyDownAt[keyCode] == nil {
            hintKeyDownAt[keyCode] = Date()
            sawOtherKey = false
        } else if !isDown, let started = hintKeyDownAt[keyCode] {
            hintKeyDownAt[keyCode] = nil
            let held = Date().timeIntervalSince(started)
            // Held alone for a while with no shortcut typed → they wanted the
            // right-side hold key.
            if held >= 0.8 && !sawOtherKey && isListening?() != true {
                Log.write("hint: left/ctrl modifier keyCode=\(keyCode) held alone \(String(format: "%.2f", held))s")
                DispatchQueue.main.async { self.onMisusedModifier?() }
            }
        }
    }
}
