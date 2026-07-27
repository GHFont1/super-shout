import AppKit
import ApplicationServices

/// Reads the character immediately before the insertion point in the focused
/// text field, using the Accessibility API. Used to decide spacing and
/// capitalization so consecutive dictations read as continuous prose.
enum ContextReader {

    /// Returns the character before the caret, or nil if the caret is at the very
    /// start of the field or the app doesn't expose its text over Accessibility.
    static func characterBeforeCaret() -> Character? {
        guard let element = focusedTextElement() else { return nil }

        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let axRange = rangeValue, CFGetTypeID(axRange) == AXValueGetTypeID()
        else { return nil }

        var range = CFRange()
        guard AXValueGetValue(axRange as! AXValue, .cfRange, &range) else { return nil }
        guard range.location > 0 else { return nil }  // caret at start of field

        var charRange = CFRange(location: range.location - 1, length: 1)
        guard let rangeArg = AXValueCreate(.cfRange, &charRange) else { return nil }

        var textValue: AnyObject?
        if AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeArg,
            &textValue
        ) == .success, let s = textValue as? String, let c = s.last {
            return c
        }

        // Fallback: some apps expose the whole value but not ranged reads.
        var whole: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &whole) == .success,
           let text = whole as? String {
            let chars = Array(text)
            let idx = range.location - 1
            if idx >= 0 && idx < chars.count { return chars[idx] }
        }
        return nil
    }

    /// True when Accessibility gave us a usable focused text element at all.
    static func canReadContext() -> Bool {
        focusedTextElement() != nil
    }

    /// True when the focused element is a search field (or a browser's
    /// address-and-search bar). Dictated search queries shouldn't end with a
    /// period — "brakes and rotors." makes for a worse query.
    static func isSearchFieldFocused() -> Bool {
        guard let element = focusedTextElement() else { return false }
        for attribute in [kAXSubroleAttribute, kAXRoleAttribute, kAXRoleDescriptionAttribute] {
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let s = value as? String, s.lowercased().contains("search") {
                return true
            }
        }
        return false
    }

    private static func focusedTextElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        return (element as! AXUIElement)
    }
}
