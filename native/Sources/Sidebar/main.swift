import AppKit
import SwiftUI
import WebKit

private let inset: CGFloat = 8

// MARK: - Window content: page + sidebar

@MainActor
final class ContainerView: NSView {
    let b: Browser
    let webHost = NSView()
    let sidebarHost: NSHostingView<SidebarView>
    let commandHost: NSHostingView<CommandBarView>
    private let gradient = CAGradientLayer()

    init(browser: Browser) {
        b = browser
        sidebarHost = NSHostingView(rootView: SidebarView(b: browser))
        commandHost = NSHostingView(rootView: CommandBarView(b: browser))
        super.init(frame: .zero)
        wantsLayer = true
        gradient.colors = [NSColor(red: 0.165, green: 0.149, blue: 0.208, alpha: 1).cgColor,
                           NSColor(red: 0.114, green: 0.106, blue: 0.141, alpha: 1).cgColor,
                           NSColor(red: 0.094, green: 0.090, blue: 0.114, alpha: 1).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(gradient)

        webHost.wantsLayer = true
        webHost.layer?.masksToBounds = true
        webHost.layer?.backgroundColor = NSColor.white.cgColor
        addSubview(webHost)

        sidebarHost.wantsLayer = true
        sidebarHost.sizingOptions = []
        sidebarHost.appearance = NSAppearance(named: .darkAqua)
        addSubview(sidebarHost) // above the page, so it can float over it when peeking

        commandHost.sizingOptions = []
        commandHost.appearance = NSAppearance(named: .darkAqua)
        commandHost.isHidden = true
        addSubview(commandHost) // topmost: the ⌘T pop-up covers page and sidebar
    }

    /// Show or hide the centered ⌘T command bar.
    func updateCommandBar() {
        let open = b.commandBarOpen
        commandHost.frame = bounds
        // Rebuild the SwiftUI tree on each open so the field starts focused and selection resets.
        if open && commandHost.isHidden { commandHost.rootView = CommandBarView(b: b) }
        commandHost.isHidden = !open
        if open { window?.makeFirstResponder(commandHost) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        apply(animated: false)
    }

    func apply(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        commandHost.frame = bounds

        let w = bounds.width, h = bounds.height
        let docked = !b.hidden
        webHost.frame = docked
            ? NSRect(x: sidebarWidth, y: inset, width: max(0, w - sidebarWidth - inset), height: max(0, h - inset * 2))
            : bounds
        webHost.layer?.cornerRadius = docked ? 8 : 0

        let show = b.sidebarVisible
        let target = NSRect(x: show ? 0 : -sidebarWidth - 20, y: 0, width: sidebarWidth, height: h)
        if let l = sidebarHost.layer {
            l.shadowOpacity = b.hidden ? 0.35 : 0
            l.shadowRadius = 14
            l.shadowOffset = .zero
            l.masksToBounds = false
        }
        if show { sidebarHost.isHidden = false }
        if animated && b.hidden {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                sidebarHost.animator().frame = target
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !self.b.sidebarVisible { self.sidebarHost.isHidden = true }
                }
            })
        } else {
            sidebarHost.frame = target
            sidebarHost.isHidden = !show
        }

        // Traffic lights only when the sidebar is on screen: a clean frame for streaming.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = !show
        }
    }

    func showActiveTab() {
        for v in webHost.subviews where v !== b.active?.webView { v.removeFromSuperview() }
        if let wv = b.active?.webView, wv.superview !== webHost {
            wv.frame = webHost.bounds
            webHost.addSubview(wv)
        }
    }
}

// MARK: - Menu helper

@MainActor
final class ClosureItem: NSMenuItem {
    private var handler: (() -> Void)?
    convenience init(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = mods
        target = self
        self.handler = handler
    }
    @objc private func run() { handler?() }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let b = Browser.shared
    var window: NSWindow!
    var container: ContainerView!
    var peekTimer: Timer?
    var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Sidebar"
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.minSize = NSSize(width: 600, height: 400)
        window.backgroundColor = NSColor(red: 0.11, green: 0.10, blue: 0.13, alpha: 1)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("SidebarMainWindow")

        container = ContainerView(browser: b)
        window.contentView = container

        b.onLayoutChange = { [weak self] in self?.container.apply(animated: true); self?.updatePeekTimer() }
        b.onActiveChange = { [weak self] in
            guard let self else { return }
            self.container.showActiveTab()
            if self.b.inputMode == nil, let wv = self.b.active?.webView { self.window.makeFirstResponder(wv) }
        }
        b.focusSidebar = { [weak self] in
            guard let self else { return }
            self.window.makeKeyAndOrderFront(nil)
            self.window.makeFirstResponder(self.container.sidebarHost)
        }
        b.onInputModeChange = { [weak self] in self?.container.updateCommandBar() }
        b.focusPage = { [weak self] in
            guard let self, let wv = self.b.active?.webView else { return }
            self.window.makeFirstResponder(wv)
        }

        b.restore()
        container.apply(animated: false)
        for u in pendingURLs { b.newTab(u) }
        pendingURLs = []
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        installMonitors()
        b.startMemoryManagement()
        if let dir = ProcessInfo.processInfo.environment["SB_TEST"] { runSelfTest(dir) }
    }

    // Peek: reveal the hidden sidebar when the cursor touches the window's left edge.
    private func installMonitors() {
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, self.b.hidden, e.window === self.window else { return }
                let x = e.locationInWindow.x
                if !self.b.peeking && x <= 5 { self.b.setPeeking(true) }
                else if self.b.peeking && x > sidebarWidth + 24 { self.b.setPeeking(false) }
            }
            return e
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Ctrl+Tab / Ctrl+Shift+Tab cycle tabs even when the page has focus.
            if e.keyCode == 48, mods.contains(.control) {
                let back = mods.contains(.shift)
                MainActor.assumeIsolated { self?.b.cycle(back ? -1 : 1) }
                return nil
            }
            // ⌘⇧[ / ⌘⇧] previous / next tab (keyCode 33 = [, 30 = ]; matched by key so it works on any layout).
            if mods == [.command, .shift], e.keyCode == 33 || e.keyCode == 30 {
                let back = e.keyCode == 33
                MainActor.assumeIsolated { self?.b.cycle(back ? -1 : 1) }
                return nil
            }
            return e
        }
    }

    /// While peeking, notice when the cursor leaves the window entirely.
    private func updatePeekTimer() {
        peekTimer?.invalidate()
        peekTimer = nil
        guard b.peeking else { return }
        peekTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.b.peeking else { return }
                let p = NSEvent.mouseLocation
                let f = self.window.frame
                if !f.contains(p) || p.x - f.minX > sidebarWidth + 24 { self.b.setPeeking(false) }
            }
        }
    }

    // Default-browser links from other apps.
    func application(_ app: NSApplication, open urls: [URL]) {
        if b.tabs.isEmpty && window == nil { pendingURLs += urls; return }
        for u in urls { b.newTab(u) }
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ note: Notification) { b.saveNow(); b.history.saveNow(sync: true) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil) // keep tabs alive; click the Dock icon to bring it back
        return false
    }

    // MARK: Menu (every shortcut lives here so it works while a page has focus)

    private func buildMenu() {
        let b = self.b
        let wv: () -> WKWebView? = { b.active?.webView }
        let main = NSMenu()

        func sub(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            host.submenu = m
            main.addItem(host)
        }

        sub("Sidebar", [
            NSMenuItem(title: "About Sidebar", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Hide Sidebar", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            NSMenuItem(title: "Quit Sidebar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])
        sub("File", [
            ClosureItem("New Tab", "t") { b.openInput(.newTab) },
            ClosureItem("Open Location…", "l") { b.openInput(.url) },
            ClosureItem("Reopen Closed Tab", "t", [.command, .shift]) { b.reopenClosed() },
            ClosureItem("Close Tab", "w") { [weak self] in
                if let t = b.active { b.close(t) } else { self?.window.orderOut(nil) }
            },
            ClosureItem("Copy URL", "c", [.command, .shift]) {
                guard let u = b.active?.url else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(u.absoluteString, forType: .string)
            },
        ])
        sub("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            {
                let i = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
                i.keyEquivalentModifierMask = [.command, .shift]
                return i
            }(),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
            .separator(),
            ClosureItem("Find…", "f") { b.openInput(.find) },
            ClosureItem("Find Next", "g") { if b.inputMode == .find { b.find(backwards: false) } },
            ClosureItem("Find Previous", "g", [.command, .shift]) { if b.inputMode == .find { b.find(backwards: true) } },
        ])
        sub("View", [
            ClosureItem("Toggle Sidebar", "s") { b.toggleSidebar() },
            ClosureItem("Show History", "y") { b.toggleHistory() },
            .separator(),
            ClosureItem("Reload", "r") { wv()?.reload() },
            ClosureItem("Hard Reload", "r", [.command, .shift]) { wv()?.reloadFromOrigin() },
            ClosureItem("Back", "[") { wv()?.goBack() },
            ClosureItem("Forward", "]") { wv()?.goForward() },
            .separator(),
            ClosureItem("Zoom In", "=") { if let w = wv() { w.pageZoom = min(w.pageZoom + 0.1, 3) } },
            ClosureItem("Zoom Out", "-") { if let w = wv() { w.pageZoom = max(w.pageZoom - 0.1, 0.3) } },
            ClosureItem("Actual Size", "0") { wv()?.pageZoom = 1 },
            .separator(),
            ClosureItem("Enter Full Screen", "f", [.command, .control]) { [weak self] in self?.window.toggleFullScreen(nil) },
        ])
        var tabItems: [NSMenuItem] = [
            ClosureItem("Next Tab", "]", [.command, .shift]) { b.cycle(1) },
            ClosureItem("Previous Tab", "[", [.command, .shift]) { b.cycle(-1) },
            ClosureItem("Next Tab ", "\u{F701}", [.command, .option]) { b.cycle(1) },
            ClosureItem("Previous Tab ", "\u{F700}", [.command, .option]) { b.cycle(-1) },
            ClosureItem("Pin / Unpin Tab", "d") { if let t = b.active { b.setPinned(t, !t.pinned) } },
            .separator(),
        ]
        for n in 1...9 {
            tabItems.append(ClosureItem("Tab \(n)", "\(n)") {
                guard !b.tabs.isEmpty else { return }
                b.activate(n == 9 ? b.tabs[b.tabs.count - 1] : (n <= b.tabs.count ? b.tabs[n - 1] : b.tabs[b.tabs.count - 1]))
            })
        }
        sub("Tabs", tabItems)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        let wHost = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        wHost.submenu = windowMenu
        main.addItem(wHost)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    // MARK: Scripted self-test (SB_TEST=<dir>): prints the window number at each step for screencapture.

    private func runSelfTest(_ dir: String) {
        let steps: [(Double, () -> Void)] = [
            (3, { [b] in
                b.newTab(URL(string: "https://en.wikipedia.org/wiki/Web_browser"))
                b.newTab(URL(string: "https://news.ycombinator.com"), background: true)
                if let first = b.tabs.first { b.setPinned(first, true) }
            }),
            (7, { [b] in print("STEP cmdbar"); b.openInput(.newTab); b.inputText = "hacker" }),
            (8.5, { [b] in print("STEP cycled"); b.closeInput(); b.cycle(1) }),
            (9, { [b] in print("STEP hidden"); b.toggleSidebar() }),
            (11, { [b] in print("STEP peek-input"); b.openInput(.url) }),
            (13, { [b] in print("STEP find"); b.closeInput(); b.openInput(.find); b.inputText = "browser" }),
            (15, { [b] in print("STEP history"); b.closeInput(); b.toggleSidebar(); b.openHistory() }),
            (17, { [b] in print("STEP history-hidden"); b.closeHistory(); b.toggleSidebar(); b.openHistory() }),
            (19, { [b] in print("STEP cmdbar-history"); b.closeHistory(); b.toggleSidebar(); b.openInput(.newTab); b.inputText = "browser" }),
            (21, { [b] in
                print("HISTORY", b.history.entries.map { "\($0.host) | \($0.title)" })
                b.closeInput(); b.saveNow(); b.history.saveNow(sync: true)
                print("STATE", (try? String(contentsOf: Browser.stateURL, encoding: .utf8))?.prefix(240) ?? "")
                print("UA", b.active?.webView?.value(forKey: "userAgent") ?? "")
                NSApp.terminate(nil)
            }),
        ]
        print("WINDOW", window.windowNumber)
        fflush(stdout)
        for (t, f) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { f(); fflush(stdout) }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
