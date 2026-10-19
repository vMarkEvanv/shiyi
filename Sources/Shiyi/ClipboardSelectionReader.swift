import AppKit
import ApplicationServices

/// WPS PDF/document surfaces may not expose a text selection through AX.
/// Ask the frontmost WPS process to copy, then restore the pasteboard only if
/// no subsequent user copy has replaced this operation's result.
@MainActor
struct ClipboardSelectionReader {
    static let eventTag: Int64 = 0x53485949

    func read(pid: pid_t) async throws -> String {
        guard AXIsProcessTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw SelectionReadError.noSelection
        }
        let board = NSPasteboard.general
        let originalCount = board.changeCount
        var saved: [NSPasteboardItem] = []
        var size = 0
        for item in board.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else { throw SelectionReadError.noSelection }
                size += data.count
                guard size <= 16_000_000 else { throw SelectionReadError.noSelection }
                copy.setData(data, forType: type)
            }
            saved.append(copy)
        }
        guard board.changeCount == originalCount else { throw SelectionReadError.noSelection }
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else { throw SelectionReadError.noSelection }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
            event.postToPid(pid)
        }
        // Wait for WPS's asynchronous copy while allowing normal app events.
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                throw SelectionReadError.noSelection
            }
            if board.changeCount != originalCount {
                let copiedCount = board.changeCount
                let text = board.string(forType: .string)
                if board.changeCount == copiedCount {
                    board.clearContents()
                    if !saved.isEmpty { board.writeObjects(saved) }
                }
                guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw SelectionReadError.noSelection }
                guard text.count <= 5_000 else { throw SelectionReadError.tooLong }
                return text
            }
        }
        throw SelectionReadError.noSelection
    }
}
