import SwiftUI
import AppKit
import Combine

@main
struct ShiyiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
        copyShortcut.start()
        store.preferences.$copyThenTranslate.dropFirst().sink { [weak self] enabled in
            if !enabled { self?.copyShortcut.cancel() }
        }.store(in: &observers)
        monitor.start()
        store.$permissionGranted.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.monitor.restart()
        }.store(in: &observers)
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
        permissionTimer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refreshPermission() }
        }
        if let permissionTimer { RunLoop.main.add(permissionTimer, forMode: .common) }
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
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = menu.addItem(withTitle: "拾译 · 语境划词翻译", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(.separator())
        addItem("显示浮窗 · " + store.preferences.overlayShortcut.title, action: #selector(showOverlay), to: menu)
        addItem("翻译选中文字", action: #selector(translateSelection), to: menu)
        addItem("语音实时翻译 · " + store.preferences.voiceShortcut.title, action: #selector(showVoice), to: menu)
        addItem("语音翻译设置…", action: #selector(openVoiceSettings), to: menu)
        menu.addItem(.separator())
        addItem("打开拾译…", action: #selector(openControlCenter), to: menu)
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

    @objc private func showVoice() { voiceWindow.show() }
    @objc private func openVoiceSettings() {
        showControlCenter()
        NotificationCenter.default.post(name: Notification.Name("ShiyiOpenVoice"), object: nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        voiceStore.stop(cancelPending: true)
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
            window.minSize = NSSize(width: 760, height: 620)
            window.contentViewController = NSHostingController(rootView: ControlCenterView(store: store, voiceStore: voiceStore))
            window.center()
            window.setFrameAutosaveName("ShiyiControlCenter")
            controlWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        controlWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
