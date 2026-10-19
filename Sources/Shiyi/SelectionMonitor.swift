import AppKit
import ApplicationServices

@MainActor
final class SelectionMonitor {
    var onSelection: ((CapturedSelection) -> Void)?
    var onFailure: ((String) -> Void)?
    var onOutsideClick: (() -> Void)?
    var onEscape: (() -> Void)?
    var shouldSkipAutomatic: (() -> Bool)?
    private let preferences: Preferences
    private let queue = DispatchQueue(label: "com.shiyi.selection", qos: .userInitiated)
    private let browserAccessibility = BrowserAccessibility()
    private var monitors: [Any] = []
    private var pending: Task<Void, Never>?
    private var generation = UUID()
    private var lastSelection: CapturedSelection?
    private var lastExternalApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init(preferences: Preferences) { self.preferences = preferences }

    func start() {
        guard monitors.isEmpty else { return }
        rememberFrontApp()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.invalidate()
                self?.lastSelection = nil
                self?.rememberFrontApp()
            }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp], handler: { [weak self] event in
            self?.handle(event)
        }) { monitors.append(monitor) }
    }

    func restart() {
        invalidate()
        clearLastSelection()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        if let observer = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        activationObserver = nil
        start()
    }

    func invalidate() { generation = UUID(); pending?.cancel(); pending = nil }
    func clearLastSelection() { lastSelection = nil }

    func captureManually(reportFailure: Bool = true) {
        schedule(manual: true, delay: 0.08, reportFailure: reportFailure)
    }

    private func handle(_ event: NSEvent) {
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != ClipboardSelectionReader.eventTag else { return }
        switch event.type {
        case .leftMouseDown:
            invalidate()
            clearLastSelection()
            onOutsideClick?()
        case .leftMouseUp:
            if preferences.autoTranslate { schedule(manual: false, delay: 0.35) }
        case .keyDown:
            clearLastSelection()
            if event.keyCode == 53 { invalidate(); onEscape?() }
            else { invalidate() }
        case .keyUp:
            if event.modifierFlags.contains(.shift), preferences.autoTranslate { schedule(manual: false, delay: 0.35) }
        default: break
        }
    }

    private func rememberFrontApp() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApp = app
            browserAccessibility.prepare(app)
        }
    }

    private func schedule(manual: Bool, delay: TimeInterval, reportFailure: Bool = true) {
        invalidate()
        let token = generation
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, token == self.generation else { return }
            guard manual || (self.preferences.autoTranslate && !(self.shouldSkipAutomatic?() ?? false)) else { return }
            guard AXIsProcessTrusted() else {
                if manual && reportFailure { self.onFailure?("请先在系统设置中允许拾译使用“辅助功能”，才能读取其他应用的选中文字。") }
                return
            }
            self.rememberFrontApp()
            let front = NSWorkspace.shared.frontmostApplication
            guard manual || front?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            guard let app = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? self.lastExternalApp : front,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !app.isTerminated else { return }
            let browserDelay = self.browserAccessibility.prepare(app)
            if browserDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(browserDelay * 1_000_000_000))
                guard !Task.isCancelled, token == self.generation else { return }
            }
            let bundleID = app.bundleIdentifier ?? ""
            guard !TextContext.excludedApps(from: self.preferences.excludedBundleIDs).contains(bundleID) else {
                if manual && reportFailure { self.onFailure?("这个应用已被排除。你可以在偏好设置中将它移出排除列表。") }
                return
            }
            let includeContext = self.preferences.engine == .contextual && self.preferences.sendContext
            let anchor = NSEvent.mouseLocation
            let pid = app.processIdentifier
            let appName = app.localizedName ?? "当前应用"
            var result: Result<CapturedSelection, Error> = await withCheckedContinuation { continuation in
                self.queue.async {
                    continuation.resume(returning: Result { try SelectionReader().read(pid: pid, appName: appName, bundleID: bundleID, anchor: anchor, includeContext: includeContext) })
                }
            }
            guard !Task.isCancelled, token == self.generation else { return }
            if bundleID == "com.kingsoft.wpsoffice.mac", case .failure(let error) = result,
               let reason = error as? SelectionReadError, case .noSelection = reason {
                do {
                    let text = try await ClipboardSelectionReader().read(pid: pid)
                    result = .success(CapturedSelection(text: text, context: "", appName: appName, bundleID: bundleID,
                                                        documentTitle: "", anchor: anchor))
                } catch { result = .failure(error) }
            }
            guard !Task.isCancelled, token == self.generation else { return }
            guard manual || (self.preferences.autoTranslate && !(self.shouldSkipAutomatic?() ?? false)) else { return }
            switch result {
            case .success(let selection):
                if !manual, let last = self.lastSelection, last.text == selection.text,
                   last.bundleID == selection.bundleID, last.context == selection.context,
                   last.documentTitle == selection.documentTitle { return }
                self.lastSelection = selection
                self.onSelection?(selection)
            case .failure(let error):
                self.lastSelection = nil
                if manual && reportFailure { self.onFailure?(error.localizedDescription) }
            }
        }
    }
}
