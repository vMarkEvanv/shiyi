import AppKit
import ApplicationServices

enum SelectionReadError: LocalizedError {
    case noSelection
    case tooLong
    case secureField
    var errorDescription: String? {
        switch self {
        case .noSelection: return "没有读到选中文字。请先在其他应用中选中一段文字，再按 ⌥⌘T；不支持取词的应用可以在这里粘贴翻译。"
        case .tooLong: return "选中文字过长，请选取 5,000 字以内的内容。"
        case .secureField: return "密码输入框中的内容不会被读取。"
        }
    }
}

enum TextContext {
    /// Accessibility uses UTF-16 offsets. Expand at composed-character boundaries.
    static func surroundingText(in text: String, selection: NSRange, radius: Int = 600) -> String {
        let source = text as NSString
        guard selection.location != NSNotFound, selection.location >= 0,
              selection.length >= 0, selection.location <= source.length,
              selection.length <= source.length - selection.location else { return "" }
        let start = max(0, selection.location - max(0, radius))
        let end = min(source.length, selection.location + selection.length + max(0, radius))
        let safeRange = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        return source.substring(with: safeRange).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func excludedApps(from value: String) -> Set<String> {
        Set(value.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }
}

/// Called on a private serial queue so slow accessibility providers cannot block the UI.
struct SelectionReader {
    func read(pid: pid_t, appName: String, bundleID: String, anchor: CGPoint, includeContext: Bool) throws -> CapturedSelection {
        // A system-wide element sets the default for subsequently created AX objects.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let focus = element(app, kAXFocusedUIElementAttribute) else { throw SelectionReadError.noSelection }
        var candidate: AXUIElement? = focus
        for _ in 0..<6 {
            guard let current = candidate else { break }
            if string(current, kAXSubroleAttribute) == "AXSecureTextField" { throw SelectionReadError.secureField }
            if let selected = string(current, kAXSelectedTextAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty {
                guard selected.count <= 5_000 else { throw SelectionReadError.tooLong }
                let context = includeContext ? surroundingText(current) : ""
                let title = includeContext ? element(app, kAXFocusedWindowAttribute).flatMap { string($0, kAXTitleAttribute) } ?? "" : ""
                return CapturedSelection(text: selected, context: context, appName: appName, bundleID: bundleID,
                                         documentTitle: String(title.prefix(250)), anchor: anchor)
            }
            candidate = element(current, kAXParentAttribute)
        }
        throw SelectionReadError.noSelection
    }

    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? { value(element, name) as? String }

    private func element(_ source: AXUIElement, _ name: String) -> AXUIElement? {
        guard let result = value(source, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    private func surroundingText(_ source: AXUIElement) -> String {
        guard let rawRange = value(source, kAXSelectedTextRangeAttribute), CFGetTypeID(rawRange) == AXValueGetTypeID() else { return "" }
        var selectedRange = CFRange()
        guard AXValueGetValue(rawRange as! AXValue, .cfRange, &selectedRange), selectedRange.location >= 0,
              selectedRange.length > 0, selectedRange.length <= 20_000 else { return "" }
        // Prefer a bounded range rather than retrieving the entire document.
        if let number = value(source, kAXNumberOfCharactersAttribute) as? NSNumber {
            let count = number.intValue
            guard selectedRange.location <= count, selectedRange.length <= count - selectedRange.location else { return "" }
            let start = max(0, selectedRange.location - 600)
            let end = min(count, selectedRange.location + selectedRange.length + 600)
            var range = CFRange(location: start, length: end - start)
            if let parameter = AXValueCreate(.cfRange, &range) {
                var result: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(source, kAXStringForRangeParameterizedAttribute as CFString,
                                                             parameter, &result) == .success, let text = result as? String {
                    return String(text.prefix(6_200))
                }
            }
        }
        if let text = string(source, kAXValueAttribute) {
            return String(TextContext.surroundingText(in: text, selection: NSRange(location: selectedRange.location, length: selectedRange.length)).prefix(6_200))
        }
        return ""
    }
}
