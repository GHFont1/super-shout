import AppKit
import Carbon.HIToolbox

/// Inserts text into whatever app/field currently has focus by swapping the
/// clipboard, synthesizing ⌘V, then restoring the previous clipboard.
final class TextInjector {
    private var lastInsertionAt: Date?
    private(set) var lastInserted: String?

    func insert(_ rawText: String) {
        paste(Settings.shared.smartSpacing ? joinWithContext(rawText) : rawText)
    }

    /// Pastes exactly as given — used for AI output, which either replaces a
    /// live selection or is already fully formed.
    func insertRaw(_ text: String) {
        paste(text)
    }

    /// Puts the text on the clipboard and leaves it there (no restore) for the
    /// user to paste manually — used when a synthetic paste can't land.
    func copyOnly(_ text: String) {
        lastInserted = nil
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        Log.write("copyOnly: \(text.count) chars left on clipboard")
    }

    private func paste(_ text: String) {
        lastInsertionAt = Date()
        lastInserted = text
        Log.write("paste: \(text.count) chars via synthetic ⌘V")
        let pb = NSPasteboard.general
        let savedItems = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy.isEmpty ? nil : copy
        } ?? []

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Give the pasteboard server a beat before the target app reads it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.pasteKeystroke()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard !savedItems.isEmpty else { return }
            pb.clearContents()
            let restored = savedItems.map { dict -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                return item
            }
            pb.writeObjects(restored)
        }
    }

    /// Reads what's immediately before the caret and joins the new text onto it
    /// with correct spacing, sentence casing, and line breaks for lists.
    private func joinWithContext(_ text: String) -> String {
        let isList = text.contains("\n- ")
        let previous = ContextReader.characterBeforeCaret()
        let readable = ContextReader.canReadContext()

        if isList {
            // A list always starts on its own line.
            guard let previous else { return text.trimmingCharacters(in: .newlines) }
            return previous == "\n" ? text.trimmingCharacters(in: .newlines) : text
        }

        if previous == nil && !readable {
            // App doesn't expose its text (e.g. some Electron/web fields).
            // Fall back to spacing after a recent insertion so runs don't collide.
            if let last = lastInsertionAt, Date().timeIntervalSince(last) < 120 {
                return " " + text
            }
            return text
        }

        return SpacingEngine.join(text, after: previous)
    }

    /// Removes the most recent insertion by sending one backspace per
    /// character. Works anywhere the paste worked.
    func undoLastInsertion() {
        guard let text = lastInserted else { return }
        lastInserted = nil
        let count = min(text.count, 1000)
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)
            down?.post(tap: .cgSessionEventTap)
            up?.post(tap: .cgSessionEventTap)
        }
    }

    private func pasteKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cgSessionEventTap)
        vUp?.post(tap: .cgSessionEventTap)
    }
}
