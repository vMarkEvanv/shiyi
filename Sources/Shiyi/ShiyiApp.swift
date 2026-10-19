import SwiftUI
import AppKit
import Combine

@main
struct ShiyiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let store = AppStore()
    private lazy var monitor = SelectionMonitor(preferences: store.preferences)
    private let hotKey = GlobalHotKey()
    private var statusItem: NSStatusItem!
    private var controlWindow: NSWindow?
    private var panel: TranslationPanel?
    private var permissionTimer: Timer?
    private var localKeyMonitor: Any?
    private var observers = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        store.onShowPanel = { [weak self] anchor in self?.showPanel(at: anchor) }
        store.onDismissPanel = { [weak self] in
            self?.panel?.orderOut(nil)
            self?.monitor.clearLastSelection()
        }
        store.onOpenSettings = { [weak self] in
            self?.showControlCenter()
            NotificationCenter.default.post(name: Notification.Name("ShiyiOpenPreferences"), object: nil)
        }
        store.onSystemDownloadNeeded = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.panel?.makeKeyAndOrderFront(nil)
        }
        monitor.onSelection = { [weak self] selection in self?.store.translate(selection) }
        monitor.onFailure = { [weak self] message in self?.store.captureFailed(message) }
        monitor.onOutsideClick = { [weak self] in
            guard let self, !self.store.isPinned, !self.store.isPreparingSystemLanguages else { return }
            self.store.dismiss()
        }
        monitor.onEscape = { [weak self] in self?.store.dismiss() }
        monitor.shouldSkipAutomatic = { [weak self] in self?.store.isPinned ?? false }
        monitor.start()
        store.$permissionGranted.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.monitor.restart()
        }.store(in: &observers)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.panel?.isVisible == true {
                self?.store.dismiss()
                return nil
            }
            return event
        }
        hotKey.onPress = { [weak self] in self?.monitor.captureManually() }
        let registered = hotKey.register()
        permissionTimer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.refreshPermission()
            }
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
            // Preference changes invalidate an in-flight capture before it can send data.
            self?.monitor.invalidate()
            self?.store.dismiss()
        }.store(in: &observers)
        showControlCenter()
        if !registered { store.phase = .failed("⌥⌘T 已被其他应用占用。可以使用自动划词、菜单栏取词或手动粘贴翻译。") }
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
        addItem("翻译选中文字", action: #selector(translateSelection), to: menu)
        let toggle = addItem("自动划词翻译", action: #selector(toggleAutomatic), to: menu)
        toggle.state = store.preferences.autoTranslate ? .on : .off
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

    @objc private func translateSelection() { monitor.captureManually() }
    @objc private func toggleAutomatic() { store.preferences.autoTranslate.toggle() }
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
            window.contentViewController = NSHostingController(rootView: ControlCenterView(store: store))
            window.center()
            window.setFrameAutosaveName("ShiyiControlCenter")
            controlWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        controlWindow?.makeKeyAndOrderFront(nil)
    }

    private func showPanel(at anchor: CGPoint) {
        if panel == nil {
            let panel = TranslationPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 330),
                                         styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.delegate = self
            panel.contentViewController = NSHostingController(rootView:
                TranslationCardView(store: store, onHeightChange: { [weak self] height in
                    self?.resizePanel(to: height)
                }).background { SystemTranslationHost(store: store).accessibilityHidden(true) }
            )
            self.panel = panel
        }
        guard let panel else { return }
        let screen = NSScreen.screens.first(where: { NSMouseInRect(anchor, $0.frame, false) }) ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(anchor.x + 16, area.minX + 12), area.maxX - panel.frame.width - 12)
        let y = min(max(anchor.y - panel.frame.height - 16, area.minY + 12), area.maxY - panel.frame.height - 12)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }

    private func resizePanel(to contentHeight: CGFloat) {
        guard let panel, contentHeight.isFinite else { return }
        let height = min(490, max(180, ceil(contentHeight)))
        guard abs(panel.frame.height - height) > 1 else { return }
        let area = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let y = max(area.minY + 12, min(panel.frame.maxY - height, area.maxY - height - 12))
        panel.setFrame(NSRect(x: panel.frame.minX, y: y, width: 400, height: height), display: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel { store.dismiss(); return false }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
