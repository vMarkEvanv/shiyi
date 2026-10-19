import AppKit
import SwiftUI
import Combine

final class OverlayPanel: NSPanel {
    var allowsSystemInteraction = false
    override var canBecomeKey: Bool { allowsSystemInteraction }
    override var canBecomeMain: Bool { false }
}

private final class OperationPointButton: NSButton {
    var contextMenuProvider: (() -> NSMenu)?
    var onScroll: ((Int) -> Void)?
    var onDrag: ((CGPoint, CGPoint) -> Void)?
    var onDragStart: (() -> Void)?
    private var lastScroll: TimeInterval = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?() }
    override func mouseDown(with event: NSEvent) {
        onDragStart?()
        let start = NSEvent.mouseLocation
        var dragged = false
        isHighlighted = true
        defer { isHighlighted = false }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let current = NSEvent.mouseLocation
            if !dragged, hypot(current.x - start.x, current.y - start.y) >= 4 { dragged = true }
            if dragged { onDrag?(start, current) }
            if next.type == .leftMouseUp {
                if !dragged, bounds.contains(convert(next.locationInWindow, from: nil)) {
                    sendAction(action, to: target)
                }
                break
            }
        }
    }
    override func scrollWheel(with event: NSEvent) {
        guard event.timestamp - lastScroll > 0.15, abs(event.scrollingDeltaY) > 0.1 else { return }
        lastScroll = event.timestamp
        onScroll?(event.scrollingDeltaY < 0 ? 1 : -1)
    }
}

@MainActor
final class OverlayWindowController: NSObject {
    let panel: OverlayPanel
    let operationPanel: OverlayPanel
    private let button = OperationPointButton()
    private let store: AppStore
    private var observers = Set<AnyCancellable>()
    private var dragStart: CGPoint?
    private var dragOrigin: CGPoint = .zero

    init(store: AppStore) {
        self.store = store
        panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        operationPanel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        configure(panel)
        configure(operationPanel)
        panel.title = "拾译 · 常驻译文"
        panel.ignoresMouseEvents = true
        panel.contentViewController = NSHostingController(rootView: OverlayContentView(store: store))
        operationPanel.title = "拾译 · 译文操作点"
        operationPanel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        operationPanel.ignoresMouseEvents = false
        button.target = self
        button.action = #selector(toggleExpansion)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(calibratedRed: 0.38, green: 0.38, blue: 0.80, alpha: 1).cgColor
        button.layer?.cornerRadius = 18
        button.toolTip = "点击展开或收起；拖动改变位置；右键复制、重试；滚动浏览长译文"
        button.contextMenuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        button.onScroll = { [weak store] direction in store?.scrollOverlay(by: direction) }
        button.onDragStart = { [weak self] in self?.dragStart = nil }
        button.onDrag = { [weak self] start, current in self?.moveOverlay(from: start, to: current) }
        operationPanel.contentView = button

        Publishers.CombineLatest4(store.preferences.$overlayOpacity, store.preferences.$overlayHorizontal,
                                  store.preferences.$overlayVertical, store.preferences.$overlayScreenID)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.layout() }.store(in: &observers)
        store.$isOverlayExpanded.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.layout() }.store(in: &observers)
        store.$isPreparingSystemLanguages.receive(on: DispatchQueue.main).sink { [weak self] preparing in
            // Only the OS language-download sheet may temporarily receive normal input.
            self?.panel.allowsSystemInteraction = preparing
            self?.panel.ignoresMouseEvents = !preparing
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.updateDisplays()
                self?.layout()
            }.store(in: &observers)
        updateDisplays()
    }

    private func configure(_ window: NSPanel) {
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.animationBehavior = .none
    }

    func show() {
        layout()
        panel.orderFrontRegardless()
        operationPanel.orderFrontRegardless()
    }

    func hide() {
        operationPanel.orderOut(nil)
        panel.orderOut(nil)
    }

    func prepareSystemUI() {
        panel.allowsSystemInteraction = true
        panel.ignoresMouseEvents = false
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func screenID(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "main"
    }

    func updateDisplays() {
        let screens = NSScreen.screens
        var options = [OverlayDisplay(id: "main", title: "主屏幕")]
        options += screens.map { OverlayDisplay(id: screenID($0), title: $0.localizedName) }
        let selected = store.preferences.overlayScreenID
        if !options.contains(where: { $0.id == selected }) {
            options.append(OverlayDisplay(id: selected, title: "已断开的显示器（暂用主屏幕）"))
        }
        store.availableDisplays = options
    }

    private func layout() {
        let screen = NSScreen.screens.first { screenID($0) == store.preferences.overlayScreenID } ?? NSScreen.screens.first ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let result = OverlayLayout.make(in: area, expanded: store.isOverlayExpanded,
                                        horizontal: store.preferences.overlayHorizontal, vertical: store.preferences.overlayVertical)
        if store.overlayWidth != result.contentFrame.width { store.overlayWidth = result.contentFrame.width }
        if store.overlayHeight != result.contentFrame.height { store.overlayHeight = result.contentFrame.height }
        panel.setFrame(result.contentFrame, display: true)
        panel.alphaValue = OverlayLayout.opacity(store.preferences.overlayOpacity)
        operationPanel.setFrame(result.controlFrame, display: true)
        operationPanel.alphaValue = 1
        button.image = NSImage(systemSymbolName: store.isOverlayExpanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
        button.setAccessibilityLabel(store.isOverlayExpanded ? "收起译文" : "展开译文")
    }

    private func moveOverlay(from start: CGPoint, to current: CGPoint) {
        if dragStart != start {
            dragStart = start
            dragOrigin = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(current) } ?? NSScreen.screens.first
        guard let screen else { return }
        let area = screen.visibleFrame
        let first = OverlayLayout.make(in: area, expanded: true, horizontal: 0, vertical: 0).contentFrame
        let last = OverlayLayout.make(in: area, expanded: true, horizontal: 1, vertical: 1).contentFrame
        let x = dragOrigin.x + current.x - start.x
        let top = dragOrigin.y + current.y - start.y
        store.preferences.overlayScreenID = screenID(screen)
        store.preferences.overlayHorizontal = OverlayLayout.unit(Double((x - first.minX) / max(1, last.minX - first.minX)))
        store.preferences.overlayVertical = OverlayLayout.unit(Double((first.maxY - top) / max(1, first.maxY - last.maxY)))
        layout()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        add(store.isOverlayExpanded ? "收起译文" : "展开译文", action: #selector(toggleExpansion), to: menu)
        menu.addItem(.separator())
        let copy = add("复制译文", action: #selector(copyResult), to: menu)
        if case .finished = store.phase { copy.isEnabled = true } else { copy.isEnabled = false }
        add("重新翻译", action: #selector(retry), to: menu).isEnabled = store.selection != nil
        if store.isOverlayExpanded {
            menu.addItem(.separator())
            add("向上浏览", action: #selector(scrollUp), to: menu).isEnabled = store.overlayScrollIndex > 0
            add("向下浏览", action: #selector(scrollDown), to: menu).isEnabled = store.overlayScrollIndex < store.overlayBlocks.count - 1
        }
        return menu
    }

    @discardableResult private func add(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func toggleExpansion() { store.toggleOverlayExpansion() }
    @objc private func copyResult() { store.copyTranslation() }
    @objc private func retry() { store.retry() }
    @objc private func scrollUp() { store.scrollOverlay(by: -1) }
    @objc private func scrollDown() { store.scrollOverlay(by: 1) }
}

/// Observe visibility at the hosting root: observing only the card does not
/// invalidate a background closure created while the overlay was hidden.
private struct OverlayContentView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        TranslationCardView(store: store)
            .background {
                if store.isOverlayVisible {
                    SystemTranslationHost(store: store).accessibilityHidden(true)
                }
            }
    }
}
