import Carbon

@MainActor
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private(set) var currentShortcut: OverlayShortcut?
    var onPress: (() -> Void)?

    @discardableResult
    func register(_ shortcut: OverlayShortcut = .optionCommandT) -> Bool {
        if currentShortcut == shortcut, reference != nil { return true }
        if eventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard identifier.signature == 0x53485949, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in hotKey.onPress?() }
                return noErr
            }, 1, &eventType, pointer, &eventHandler)
            guard status == noErr else { return false }
        }
        let modifiers: UInt32
        switch shortcut {
        case .optionCommandT: modifiers = UInt32(cmdKey | optionKey)
        case .controlOptionT: modifiers = UInt32(controlKey | optionKey)
        case .controlShiftT: modifiers = UInt32(controlKey | shiftKey)
        }
        var candidate: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x53485949, id: 1)
        guard RegisterEventHotKey(UInt32(kVK_ANSI_T), modifiers, identifier,
                                  GetApplicationEventTarget(), 0, &candidate) == noErr else { return false }
        if let reference { UnregisterEventHotKey(reference) }
        reference = candidate
        currentShortcut = shortcut
        return true
    }
}
