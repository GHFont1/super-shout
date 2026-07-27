import AppKit
import Carbon.HIToolbox

/// Inserts text into whatever app/field currently has focus by swapping the
/// clipboard, synthesizing ⌘V, then restoring the previous clipboard.
final class TextInjector {
    private var lastInsertionAt: Date?

    func insert(_ rawText: String) {
        let text = Settings.shared.smartSpacing ? joinWithContext(rawText) : rawText
        lastInsertionAt = Date()
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

        pasteKeystroke()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
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
