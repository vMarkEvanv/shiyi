import AppKit
import Carbon

struct CopySequence {
    private(set) var baseline: Int?
    private(set) var pid: pid_t?
    private(set) var deadline: TimeInterval = 0

    mutating func arm(changeCount: Int, pid: pid_t, now: TimeInterval) {
        baseline = changeCount
        self.pid = pid
        deadline = now + 3
    }
    mutating func cancel() { baseline = nil; pid = nil; deadline = 0 }
    func accepts(changeCount: Int, pid: pid_t, now: TimeInterval) -> Bool {
        guard let baseline, self.pid == pid else { return false }
        return now <= deadline && changeCount != baseline
    }
}

/// Register plain T only during an explicit copy sequence. Carbon consumes the
/// trigger so it is not inserted into the source document.
@MainActor
final class CopyTranslationShortcut {
    var onText: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    private let preferences: Preferences
    private var monitors: [Any] = []
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var timeout: Task<Void, Never>?
    private var sequence = CopySequence()
    private var commandBaseline: Int?
    private var commandPID: pid_t?

    init(preferences: Preferences) { self.preferences = preferences }

    func start() {
        guard monitors.isEmpty else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let data, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard identifier.signature == 0x53484350 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<CopyTranslationShortcut>.fromOpaque(data).takeUnretainedValue()
            Task { @MainActor in owner.trigger() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.observe($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.observe(event)
            return event
        }) { monitors.append(local) }
    }

    func cancel() {
        timeout?.cancel()
        timeout = nil
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        sequence.cancel()
    }

    private func observe(_ event: NSEvent) {
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != ClipboardSelectionReader.eventTag else { return }
        guard preferences.copyThenTranslate else { cancel(); return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if event.type == .flagsChanged {
            if event.modifierFlags.contains(.command), commandBaseline == nil || commandPID != pid {
                commandBaseline = NSPasteboard.general.changeCount
                commandPID = pid
            } else if !event.modifierFlags.contains(.command) {
                commandBaseline = nil
                commandPID = nil
            }
            return
        }
        guard event.type == .keyDown else { cancel(); return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == UInt16(kVK_ANSI_C), flags == .command, !event.isARepeat {
            let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            guard !TextContext.excludedApps(from: preferences.excludedBundleIDs).contains(bundle) else { cancel(); return }
            cancel()
            sequence.arm(changeCount: commandPID == pid ? commandBaseline ?? NSPasteboard.general.changeCount : NSPasteboard.general.changeCount,
                         pid: pid, now: ProcessInfo.processInfo.systemUptime)
            let id = EventHotKeyID(signature: 0x53484350, id: 2)
            guard RegisterEventHotKey(UInt32(kVK_ANSI_T), 0, id, GetApplicationEventTarget(), 0, &reference) == noErr else {
                cancel(); onFailure?("无法注册复制翻译的 T 键，请检查其他软件的快捷键占用。")
                return
            }
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                self?.cancel()
            }
        } else if event.keyCode != UInt16(kVK_ANSI_T) || !flags.isEmpty {
            cancel()
        }
    }

    private func trigger() {
        let board = NSPasteboard.general
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let valid = preferences.copyThenTranslate && sequence.accepts(changeCount: board.changeCount, pid: pid,
                                                                        now: ProcessInfo.processInfo.systemUptime)
        cancel()
        guard valid else { onFailure?("未检测到新复制的文字，请重新按 ⌘C，再在 3 秒内松开 ⌘ 并按 T。"); return }
        guard let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            onFailure?("剪贴板没有可翻译的文字，请复制文字后重试。")
            return
        }
        guard text.count <= 5_000 else { onFailure?("复制的文字过长，请控制在 5,000 字以内。"); return }
        onText?(text)
    }
}
