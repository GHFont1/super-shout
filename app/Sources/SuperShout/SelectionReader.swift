import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// Captures the currently selected text in whatever app has focus.
/// Tries the Accessibility API first; falls back to a clipboard-preserving
/// synthetic ⌘C for apps that don't expose their selection (some web views).
enum SelectionReader {

    static func capture(completion: @escaping (String?) -> Void) {
        if let s = axSelection(), !s.isEmpty {
            completion(s)
            return
        }
        copyFallback(completion: completion)
    }

    private static func axSelection() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID()
        else { return nil }
        let element = f as! AXUIElement
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String
        else { return nil }
        return text
    }

    private static func copyFallback(completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let savedItems = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy.isEmpty ? nil : copy
        } ?? []
        let changeCount = pb.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let cDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let cUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        cDown?.flags = .maskCommand
        cUp?.flags = .maskCommand
        cDown?.post(tap: .cgSessionEventTap)
        cUp?.post(tap: .cgSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let copied = pb.changeCount != changeCount ? pb.string(forType: .string) : nil
            if !savedItems.isEmpty {
                pb.clearContents()
                let restored = savedItems.map { dict -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in dict { item.setData(data, forType: type) }
                    return item
                }
                pb.writeObjects(restored)
            }
            completion((copied?.isEmpty == false) ? copied : nil)
        }
    }
}
