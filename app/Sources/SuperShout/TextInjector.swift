import AppKit
import Carbon.HIToolbox

/// Inserts text into whatever app/field currently has focus by swapping the
/// clipboard, synthesizing ⌘V, then restoring the previous clipboard.
final class TextInjector {
    func insert(_ text: String) {
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
