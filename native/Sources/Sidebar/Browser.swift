import AppKit
import WebKit

// MARK: - Model

struct SavedTab: Codable {
    var url: String
    var title: String
    var pinned: Bool
    var favicon: String?
}

struct SavedState: Codable {
    var tabs: [SavedTab]
    var active: Int
    var hidden: Bool
}

enum InputMode { case url, newTab, find }

@MainActor
final class Tab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String
    @Published var url: URL?
    @Published var favicon: NSImage?
    @Published var isLoading = false
    var faviconURL: URL?
    var pinned: Bool
    var webView: WKWebView?
    var observations: [NSKeyValueObservation] = []

    init(url: URL?, title: String, pinned: Bool) {
        self.url = url
        self.title = title
        self.pinned = pinned
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.host() ?? "New Tab"
    }
}

// MARK: - Browser

@MainActor
final class Browser: NSObject, ObservableObject {
    static let shared = Browser()
    static let home = URL(string: "https://www.google.com")!

    @Published var tabs: [Tab] = []
    @Published var activeID: UUID?
    @Published var hidden = false
    @Published var peeking = false
    @Published var inputMode: InputMode?
    @Published var inputText = ""
    @Published var findNoMatch = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var downloadStatus: String?
    var dragging: Tab?

    /// Hooks wired up by the window controller.
    var onLayoutChange: (() -> Void)?
    var onActiveChange: (() -> Void)?
    var focusSidebar: (() -> Void)?
    var focusPage: (() -> Void)?

    private var closedStack: [(SavedTab, Int)] = []
    private var faviconCache: [URL: NSImage] = [:]
    private var downloads: [ObjectIdentifier: (URL, NSKeyValueObservation?)] = [:]
    private var saveWork: DispatchWorkItem?

    var active: Tab? { tabs.first { $0.id == activeID } }
    var pinnedTabs: [Tab] { tabs.filter(\.pinned) }
    var todayTabs: [Tab] { tabs.filter { !$0.pinned } }
    var sidebarVisible: Bool { !hidden || peeking }

    // MARK: Web views

    static func makeConfiguration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.setValue(true, forKey: "developerExtrasEnabled")
        c.mediaTypesRequiringUserActionForPlayback = []
        c.allowsAirPlayForMediaPlayback = true
        // Present as regular Safari so sites don't serve a degraded "unknown browser" page.
        c.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        return c
    }

    private func makeWebView(for tab: Tab, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: configuration ?? Self.makeConfiguration())
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.isInspectable = true
        wv.autoresizingMask = [.width, .height]
        tab.webView = wv
        tab.observations = [
            wv.observe(\.title, options: [.new]) { [weak self, weak tab] wv, _ in
                MainActor.assumeIsolated {
                    if let t = wv.title, !t.isEmpty { tab?.title = t }
                    self?.save()
                }
            },
            wv.observe(\.url, options: [.new]) { [weak self, weak tab] wv, _ in
                MainActor.assumeIsolated {
                    if let u = wv.url { tab?.url = u }
                    self?.save()
                }
            },
            wv.observe(\.isLoading, options: [.new]) { [weak tab] wv, _ in
                MainActor.assumeIsolated { tab?.isLoading = wv.isLoading }
            },
            wv.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.syncNav(wv) }
            },
            wv.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.syncNav(wv) }
            },
        ]
        return wv
    }

    private func syncNav(_ wv: WKWebView) {
        guard wv === active?.webView else { return }
        canGoBack = wv.canGoBack
        canGoForward = wv.canGoForward
    }

    @discardableResult
    func ensureWebView(_ tab: Tab) -> WKWebView {
        if let wv = tab.webView { return wv }
        let wv = makeWebView(for: tab)
        wv.load(URLRequest(url: tab.url ?? Self.home))
        return wv
    }

    func tab(for wv: WKWebView) -> Tab? { tabs.first { $0.webView === wv } }

    // MARK: Tabs

    @discardableResult
    func newTab(_ url: URL?, background: Bool = false, after: Tab? = nil, pinned: Bool = false,
                configuration: WKWebViewConfiguration? = nil) -> Tab {
        let tab = Tab(url: url, title: "", pinned: pinned)
        var idx = after.flatMap { a in tabs.firstIndex { $0 === a } }.map { $0 + 1 } ?? tabs.count
        if !pinned { idx = max(idx, pinnedTabs.count) }
        tabs.insert(tab, at: min(idx, tabs.count))
        if let configuration {
            _ = makeWebView(for: tab, configuration: configuration) // WebKit loads the popup itself
        } else if background {
            ensureWebView(tab)
        }
        if !background { activate(tab) } else { save() }
        return tab
    }

    func activate(_ tab: Tab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        activeID = tab.id
        let wv = ensureWebView(tab)
        canGoBack = wv.canGoBack
        canGoForward = wv.canGoForward
        if inputMode == .find { closeInput() }
        onActiveChange?()
        save()
    }

    func close(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        closedStack.append((saved(tab), i))
        if closedStack.count > 50 { closedStack.removeFirst() }
        let wasActive = tab.id == activeID
        tabs.remove(at: i)
        tab.observations = []
        tab.webView?.stopLoading()
        tab.webView?.removeFromSuperview()
        tab.webView = nil
        if wasActive {
            activeID = nil
            if let next = tabs.indices.contains(i) ? tabs[i] : tabs.last { activate(next) }
            else { onActiveChange?(); openInput(.newTab) }
        }
        save()
    }

    func reopenClosed() {
        guard let (s, i) = closedStack.popLast() else { return }
        let tab = Tab(url: URL(string: s.url), title: s.title, pinned: s.pinned)
        tabs.insert(tab, at: min(i, tabs.count))
        activate(tab)
    }

    func cycle(_ dir: Int) {
        guard !tabs.isEmpty else { return }
        let i = tabs.firstIndex { $0.id == activeID } ?? 0
        activate(tabs[(i + dir + tabs.count) % tabs.count])
    }

    func setPinned(_ tab: Tab, _ pinned: Bool) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: i)
        tab.pinned = pinned
        tabs.insert(tab, at: pinnedTabs.count)
        save()
    }

    /// Live reorder while dragging: move `tab` to `target`'s slot and adopt its section.
    func move(_ tab: Tab, to target: Tab) {
        guard tab !== target, let from = tabs.firstIndex(where: { $0 === tab }),
              let to = tabs.firstIndex(where: { $0 === target }) else { return }
        tabs.remove(at: from)
        tab.pinned = target.pinned
        tabs.insert(tab, at: to)
        save()
    }

    func closeUnpinned() { todayTabs.forEach(close) }

    // MARK: Sidebar visibility

    func toggleSidebar() {
        hidden.toggle()
        peeking = false
        onLayoutChange?()
        save()
    }

    func setPeeking(_ on: Bool) {
        guard hidden, peeking != on else { return }
        if !on && inputMode != nil { return } // keep it open while typing
        peeking = on
        onLayoutChange?()
    }

    // MARK: Address / find box

    func openInput(_ mode: InputMode) {
        inputMode = mode
        findNoMatch = false
        switch mode {
        case .url: inputText = active?.url?.absoluteString ?? ""
        case .newTab, .find: inputText = ""
        }
        if hidden && !peeking { peeking = true; onLayoutChange?() }
        focusSidebar?()
    }

    func closeInput() {
        guard let mode = inputMode else { return }
        inputMode = nil
        if mode == .find { active?.webView?.evaluateJavaScript("window.getSelection().removeAllRanges()") }
        focusPage?()
        if hidden && peeking { peeking = false; onLayoutChange?() }
    }

    func submitInput() {
        guard let mode = inputMode else { return }
        if mode == .find { find(backwards: false); return }
        let text = inputText
        inputMode = nil
        if let url = Self.resolve(text) {
            if mode == .newTab || active == nil { newTab(url) }
            else if let tab = active {
                tab.url = url
                ensureWebView(tab).load(URLRequest(url: url))
            }
        }
        focusPage?()
        if hidden && peeking { peeking = false; onLayoutChange?() }
    }

    func find(backwards: Bool) {
        guard let wv = active?.webView, !inputText.isEmpty else { findNoMatch = false; return }
        let cfg = WKFindConfiguration()
        cfg.backwards = backwards
        cfg.wraps = true
        cfg.caseSensitive = false
        wv.find(inputText, configuration: cfg) { [weak self] result in
            MainActor.assumeIsolated { self?.findNoMatch = !result.matchFound }
        }
    }

    static func resolve(_ input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil
            || s.hasPrefix("about:") || s.hasPrefix("file:") { return URL(string: s) }
        if s.range(of: #"^(localhost|\d{1,3}(\.\d{1,3}){3})(:\d+)?(/.*)?$"#, options: .regularExpression) != nil {
            return URL(string: "http://" + s)
        }
        if !s.contains(" "), s.range(of: #"^[^/\s]+\.[a-zA-Z]{2,}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil {
            return URL(string: "https://" + s)
        }
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: s)]
        return c.url
    }

    // MARK: Favicons

    private static let faviconJS = """
    (() => {
      const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="shortcut icon"]')];
      const pick = links.find(l => /32|16/.test(l.sizes?.value || '')) || links[0];
      return pick ? pick.href : location.origin + '/favicon.ico';
    })()
    """

    private func loadFavicon(_ tab: Tab, from wv: WKWebView) {
        wv.evaluateJavaScript(Self.faviconJS) { [weak self, weak tab] result, _ in
            MainActor.assumeIsolated {
                guard let self, let tab, let s = result as? String, let url = URL(string: s) else { return }
                self.setFavicon(tab, url)
            }
        }
    }

    func setFavicon(_ tab: Tab, _ url: URL) {
        tab.faviconURL = url
        if let img = faviconCache[url] { tab.favicon = img; return }
        Task { [weak self, weak tab] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = NSImage(data: data) else { return }
            self?.faviconCache[url] = img
            if tab?.faviconURL == url { tab?.favicon = img }
            self?.save()
        }
    }

    // MARK: Persistence

    static var stateURL: URL {
        let base = ProcessInfo.processInfo.environment["SB_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Sidebar")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("state.json")
    }

    private func saved(_ t: Tab) -> SavedTab {
        SavedTab(url: t.url?.absoluteString ?? Self.home.absoluteString, title: t.title,
                 pinned: t.pinned, favicon: t.faviconURL?.absoluteString)
    }

    func save() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func saveNow() {
        let state = SavedState(tabs: tabs.map(saved), active: tabs.firstIndex { $0.id == activeID } ?? 0, hidden: hidden)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: Self.stateURL, options: .atomic) }
    }

    func restore() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data), !state.tabs.isEmpty else {
            newTab(Self.home)
            return
        }
        hidden = state.hidden
        // Lazy: only the active tab loads now; the rest load when clicked.
        tabs = state.tabs.map { Tab(url: URL(string: $0.url), title: $0.title, pinned: $0.pinned) }
        for (t, s) in zip(tabs, state.tabs) { if let f = s.favicon.flatMap(URL.init(string:)) { setFavicon(t, f) } }
        activate(tabs[min(max(state.active, 0), tabs.count - 1)])
    }
}

// MARK: - Navigation

extension Browser: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        guard let url = navigationAction.request.url else { return (.allow, preferences) }
        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https", "about", "data", "blob", "file", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url) // mailto:, zoommtg:, slack: …
            return (.cancel, preferences)
        }
        // ⌘-click opens in a background tab
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) {
            newTab(url, background: true, after: tab(for: webView))
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tab = tab(for: webView) { loadFavicon(tab, from: webView) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - UI (popups, alerts, uploads, permissions)

extension Browser: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank links and window.open popups (incl. OAuth) become tabs; window.opener keeps working.
        let bg = navigationAction.modifierFlags.contains(.command)
        let tab = newTab(navigationAction.request.url, background: bg, after: tab(for: webView), configuration: configuration)
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab = tab(for: webView) { close(tab) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let a = NSAlert()
        a.messageText = frame.request.url?.host() ?? "This page says"
        a.informativeText = message
        a.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let a = NSAlert()
        a.messageText = frame.request.url?.host() ?? "This page says"
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let a = NSAlert()
        a.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.canChooseFiles = true
        return p.runModal() == .OK ? p.urls : nil
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        .grant
    }
}

// MARK: - Downloads (straight to ~/Downloads)

extension Browser: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let ext = (suggestedFilename as NSString).pathExtension
        let base = (suggestedFilename as NSString).deletingPathExtension
        var dest = dir.appendingPathComponent(suggestedFilename)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        let name = dest.lastPathComponent
        downloadStatus = "↓ \(name)"
        let obs = download.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let pct = Int(p.fractionCompleted * 100)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.downloadStatus = "↓ \(name) — \(pct)%" } }
        }
        downloads[ObjectIdentifier(download)] = (dest, obs)
        return dest
    }

    func downloadDidFinish(_ download: WKDownload) {
        let entry = downloads.removeValue(forKey: ObjectIdentifier(download))
        downloadStatus = "✓ \(entry?.0.lastPathComponent ?? "Download complete")"
        clearDownloadStatusSoon()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
        downloadStatus = "✕ Download failed"
        clearDownloadStatusSoon()
    }

    private func clearDownloadStatusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated { if self?.downloads.isEmpty == true { self?.downloadStatus = nil } }
        }
    }
}
