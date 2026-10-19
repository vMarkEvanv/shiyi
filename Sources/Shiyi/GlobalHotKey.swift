import Carbon

@MainActor
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var onPress: (() -> Void)?

    @discardableResult
    func register() -> Bool {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in hotKey.onPress?() }
            return noErr
        }, 1, &eventType, pointer, &eventHandler)
        guard handlerStatus == noErr else { return false }
        let identifier = EventHotKeyID(signature: 0x53485949, id: 1)
        return RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(cmdKey | optionKey), identifier,
                                   GetApplicationEventTarget(), 0, &reference) == noErr
    }
}
