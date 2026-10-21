import SwiftUI
import AppKit
import Combine

@main
struct ShiyiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let store = AppStore()
    private lazy var monitor = SelectionMonitor(preferences: store.preferences)
    private lazy var overlay = OverlayWindowController(store: store)
    private lazy var copyShortcut = CopyTranslationShortcut(preferences: store.preferences)
    private lazy var voiceStore = VoiceTranslationStore(preferences: store.preferences)
    private lazy var voiceWindow = VoiceWindowController(store: voiceStore)
    private let voiceHotKey = VoiceHotKey()
    private var revertingVoiceShortcut: VoiceShortcut?
    private let hotKey = GlobalHotKey()
    private var statusItem: NSStatusItem!
    private var controlWindow: NSWindow?
    private var controlWindowOpen = false
    private var permissionTimer: Timer?
    private var localKeyMonitor: Any?
    private var observers = Set<AnyCancellable>()
    private var revertingShortcut: OverlayShortcut?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = overlay
        installStatusItem()
        voiceStore.onShowWindow = { [weak self] in self?.voiceWindow.show() }
        voiceStore.onPreviewWindow = { [weak self] in self?.voiceWindow.preview() }
        voiceHotKey.onPress = { [weak self] in self?.voiceWindow.toggle() }
        Task { [weak self] in await self?.voiceStore.model.refresh() }
        configureVoiceShortcut(store.preferences.voiceShortcut)
        store.preferences.$voiceShortcut.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] in
            self?.configureVoiceShortcut($0)
        }.store(in: &observers)
        store.onShowPanel = { [weak self] in self?.overlay.show() }
        store.onDismissPanel = { [weak self] in
            self?.overlay.hide()
            self?.monitor.invalidate()
            self?.monitor.clearLastSelection()
        }
        store.onOpenSettings = { [weak self] in
            self?.showControlCenter()
            NotificationCenter.default.post(name: Notification.Name("ShiyiOpenPreferences"), object: nil)
        }
        store.onSystemDownloadNeeded = { [weak self] in
            guard let self else { return }
            if self.store.isOverlayVisible { self.overlay.prepareSystemUI() }
            else { self.showControlCenter() }
        }
        monitor.onSelection = { [weak self] selection in self?.store.translate(selection) }
        monitor.onFailure = { [weak self] message in self?.store.captureFailed(message) }
        monitor.onEscape = { [weak self] in self?.store.collapseOverlay() }
        monitor.shouldSkipAutomatic = { [weak self] in
            guard let self else { return true }
            return !self.store.isOverlayVisible || self.store.isPreparingSystemLanguages
        }
        copyShortcut.onText = { [weak self] text in
            guard let self else { return }
            self.monitor.invalidate()
            self.store.showOverlay()
            self.store.translate(CapturedSelection(text: text, context: "", appName: "复制翻译", bundleID: "",
                                                   documentTitle: "", anchor: NSEvent.mouseLocation))
        }
        copyShortcut.onFailure = { [weak self] message in
            self?.store.showOverlay()
            self?.store.captureFailed(message)
        }
        store.preferences.$copyThenTranslate.removeDuplicates().sink { [weak self] enabled in
            if enabled { self?.copyShortcut.start() } else { self?.copyShortcut.stop() }
        }.store(in: &observers)
        store.$phase.receive(on: DispatchQueue.main).sink { [weak self] phase in
            guard let self, !self.controlWindowOpen, phase != .loading else { return }
            self.controlWindow?.contentViewController = nil
        }.store(in: &observers)
        monitor.trackApplications()
        Publishers.CombineLatest4(store.$permissionGranted, store.$isOverlayVisible,
                                  store.preferences.$autoTranslate, store.$isPreparingSystemLanguages)
            .map { granted, visible, automatic, preparing in granted && visible && automatic && !preparing }
            .removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] enabled in
                if enabled { self?.monitor.start() } else { self?.monitor.stop() }
            }.store(in: &observers)
        store.$permissionGranted.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updatePermissionChecks()
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.store.refreshPermission(); self?.updatePermissionChecks() }.store(in: &observers)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.store.isOverlayExpanded == true {
                self?.store.collapseOverlay()
                return nil
            }
            return event
        }
        hotKey.onPress = { [weak self] in
            guard let self else { return }
            if self.store.isOverlayVisible {
                self.store.dismiss()
            } else {
                self.store.showOverlay()
                self.monitor.captureManually(reportFailure: false)
            }
        }
        configureShortcut(store.preferences.overlayShortcut)
        store.preferences.$overlayShortcut.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] shortcut in
            self?.configureShortcut(shortcut)
        }.store(in: &observers)
        Publishers.MergeMany([
            store.preferences.$engine.map { _ in () }.eraseToAnyPublisher(),
            store.preferences.$source.map { _ in () }.eraseToAnyPublisher(),
            store.preferences.$target.map { _ in () }.eraseToAnyPublisher(),
            store.preferences.$sendContext.map { _ in () }.eraseToAnyPublisher(),
            store.preferences.$autoTranslate.map { _ in () }.eraseToAnyPublisher(),
            store.preferences.$excludedBundleIDs.map { _ in () }.eraseToAnyPublisher()
        ]).dropFirst(6).sink { [weak self] in
            self?.monitor.invalidate()
            self?.monitor.clearLastSelection()
            self?.store.invalidateTranslation()
        }.store(in: &observers)
        showControlCenter()
    }

    private func updatePermissionChecks() {
        permissionTimer?.invalidate(); permissionTimer = nil
        guard !store.permissionGranted, controlWindow?.isVisible == true else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.refreshPermission()
                if self.store.permissionGranted || self.controlWindow?.isVisible != true {
                    self.permissionTimer?.invalidate(); self.permissionTimer = nil
                }
            }
        }
        timer.tolerance = 1
        permissionTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func windowWillClose(_ notification: Notification) {
        permissionTimer?.invalidate(); permissionTimer = nil
        controlWindowOpen = false
        if store.phase != .loading || store.isOverlayVisible { controlWindow?.contentViewController = nil }
    }
    func windowDidMiniaturize(_ notification: Notification) { permissionTimer?.invalidate(); permissionTimer = nil }
    func windowDidDeminiaturize(_ notification: Notification) { updatePermissionChecks() }

    private func configureVoiceShortcut(_ shortcut: VoiceShortcut) {
        if revertingVoiceShortcut == shortcut { revertingVoiceShortcut = nil; return }
        if voiceHotKey.register(shortcut) { voiceStore.shortcutError = nil }
        else {
            voiceStore.shortcutError = "语音快捷键已被占用，请选择其他组合；仍可用主窗口打开。"
            if let previous = voiceHotKey.current, previous != shortcut {
                revertingVoiceShortcut = previous
                store.preferences.voiceShortcut = previous
            }
        }
    }

    private func configureShortcut(_ shortcut: OverlayShortcut) {
        if revertingShortcut == shortcut { revertingShortcut = nil; return }
        if hotKey.register(shortcut) {
            store.shortcutError = nil
        } else {
            store.shortcutError = "这个快捷键已被占用，请选择其他组合。仍可用主窗口的“显示浮窗”按钮。"
            if let previous = hotKey.currentShortcut, previous != shortcut {
                revertingShortcut = previous
                store.preferences.overlayShortcut = previous
            }
        }
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "拾译")
        statusItem.button?.toolTip = "拾译 · 划词翻译"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        Publishers.CombineLatest(voiceStore.$listening, voiceStore.$starting)
            .receive(on: DispatchQueue.main).sink { [weak self] listening, starting in
                let active = listening || starting
                self?.statusItem.button?.image = NSImage(systemSymbolName: active ? "mic.fill" : "character.bubble", accessibilityDescription: active ? "拾译：正在收听麦克风" : "拾译：麦克风已停止")
                self?.statusItem.button?.toolTip = active ? "拾译 · 正在收听麦克风" : "拾译 · 麦克风已停止"
            }.store(in: &observers)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = menu.addItem(withTitle: "拾译 · 语境划词翻译", action: nil, keyEquivalent: "")
        title.isEnabled = false
        let microphone = menu.addItem(withTitle: voiceStore.listening || voiceStore.starting ? "麦克风：正在收听" : "麦克风：已停止", action: nil, keyEquivalent: "")
        microphone.isEnabled = false
        if voiceStore.listening || voiceStore.starting { addItem("停止收听", action: #selector(stopVoice), to: menu) }
        menu.addItem(.separator())
        addItem("显示浮窗 · " + store.preferences.overlayShortcut.title, action: #selector(showOverlay), to: menu)
        addItem("翻译选中文字", action: #selector(translateSelection), to: menu)
        addItem("语音实时翻译 · " + store.preferences.voiceShortcut.title, action: #selector(showVoice), to: menu)
        addItem("语音翻译设置…", action: #selector(openVoiceSettings), to: menu)
        menu.addItem(.separator())
        addItem("打开拾译…", action: #selector(openControlCenter), to: menu)
        let settings = addItem("设置…", action: #selector(openSettings), to: menu)
        settings.keyEquivalent = ","
        if !store.permissionGranted { addItem("开启辅助功能权限…", action: #selector(requestAccessibility), to: menu) }
        menu.addItem(.separator())
        let quit = addItem("退出拾译", action: #selector(quit), to: menu)
        quit.keyEquivalent = "q"
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func showVoice() { voiceWindow.toggle() }
    @objc private func stopVoice() { voiceStore.stop() }
    @objc private func openSettings() {
        showControlCenter()
        NotificationCenter.default.post(name: Notification.Name("ShiyiOpenPreferences"), object: nil)
    }
    @objc private func openVoiceSettings() {
        showControlCenter()
        NotificationCenter.default.post(name: Notification.Name("ShiyiOpenVoice"), object: nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        monitor.stop(); copyShortcut.stop()
        voiceStore.stop(cancelPending: true)
        voiceStore.archive.flush()
        voiceStore.model.shutdown()
    }

    @objc private func showOverlay() { store.showOverlay() }
    @objc private func translateSelection() { store.showOverlay(); monitor.captureManually() }
    @objc private func openControlCenter() { showControlCenter() }
    @objc private func requestAccessibility() { store.requestPermission() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showControlCenter() {
        if controlWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "拾译"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.minSize = NSSize(width: 760, height: 620)
            window.contentViewController = NSHostingController(rootView: ControlCenterView(store: store, voiceStore: voiceStore))
            window.center()
            window.setFrameAutosaveName("ShiyiControlCenter")
            controlWindow = window
        }
        if controlWindow?.contentViewController == nil {
            controlWindow?.contentViewController = NSHostingController(rootView: ControlCenterView(store: store, voiceStore: voiceStore))
        }
        controlWindowOpen = true
        NSApp.activate(ignoringOtherApps: true)
        controlWindow?.makeKeyAndOrderFront(nil)
        store.refreshPermission(); updatePermissionChecks()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
