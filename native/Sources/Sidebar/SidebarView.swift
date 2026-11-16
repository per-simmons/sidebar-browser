import SwiftUI
import UniformTypeIdentifiers

let sidebarWidth: CGFloat = 248

struct SidebarView: View {
    @ObservedObject var b: Browser
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            addressBox.padding(.horizontal, 10).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 1) {
                        ForEach(b.pinnedTabs) { TabRow(tab: $0, b: b).id($0.id) }
                        divider
                        newTabRow
                        ForEach(b.todayTabs) { TabRow(tab: $0, b: b).id($0.id) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .onChange(of: b.activeID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
            if let status = b.downloadStatus {
                Text(status)
                    .font(.system(size: 11.5)).opacity(0.7)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
            }
        }
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity)
        .background {
            // Opaque only while floating over the page; docked, the window background shows through.
            if b.hidden { SidebarBackground().overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.08)).frame(width: 1) } }
        }
        .foregroundStyle(Color(white: 0.93))
        .environment(\.colorScheme, .dark)
        .onChange(of: b.inputMode) { _, mode in
            if mode != nil { DispatchQueue.main.async { inputFocused = true } } else { inputFocused = false }
        }
        .onChange(of: inputFocused) { _, focused in
            // Clicked away from the box: close it. Debounced so switching boxes (⌘L → ⌘F) doesn't close the new one.
            guard !focused else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if !inputFocused && b.inputMode != nil { b.closeInput() }
            }
        }
        .onChange(of: b.inputText) { _, _ in
            if b.inputMode == .find { b.find(backwards: false) }
        }
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack(spacing: 2) {
            Spacer()
            NavButton(symbol: "sidebar.left", help: b.hidden ? "Keep sidebar open (⌘S)" : "Hide sidebar (⌘S)") { b.toggleSidebar() }
            NavButton(symbol: "chevron.left", help: "Back (⌘[)", disabled: !b.canGoBack) { b.active?.webView?.goBack() }
            NavButton(symbol: "chevron.right", help: "Forward (⌘])", disabled: !b.canGoForward) { b.active?.webView?.goForward() }
            NavButton(symbol: "arrow.clockwise", help: "Reload (⌘R)") { b.active?.webView?.reload() }
        }
        .frame(height: 26)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private var addressBox: some View {
        let editing = b.inputMode != nil
        return ZStack(alignment: .leading) {
            if editing {
                HStack(spacing: 6) {
                    TextField(placeholder, text: $b.inputText)
                        .textFieldStyle(.plain)
                        .focused($inputFocused)
                        .onSubmit { b.submitInput() }
                        .onExitCommand { b.closeInput() }
                    if b.inputMode == .find && !b.inputText.isEmpty {
                        if b.findNoMatch { Text("No match").font(.system(size: 11)).opacity(0.5) }
                        Button { b.find(backwards: true) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).opacity(0.7)
                        Button { b.find(backwards: false) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).opacity(0.7)
                    }
                }
            } else {
                Text(prettyURL(b.active?.url) ?? "Search or enter URL")
                    .lineLimit(1).truncationMode(.tail)
                    .opacity(0.8)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(editing ? 0.14 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(red: 0.63, green: 0.55, blue: 1).opacity(editing ? 0.6 : 0), lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { if !editing { b.openInput(.url) } }
    }

    private var placeholder: String {
        switch b.inputMode {
        case .find: return "Find in page"
        case .newTab: return "Search or enter URL — new tab"
        default: return "Search or enter URL"
        }
    }

    private var divider: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            if !b.todayTabs.isEmpty {
                Button("Clear") { b.closeUnpinned() }
                    .buttonStyle(.plain).font(.system(size: 11)).opacity(0.45)
                    .help("Close all unpinned tabs")
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 4)
        .padding(.top, b.pinnedTabs.isEmpty ? 0 : 6)
    }

    private var newTabRow: some View {
        HoverRow { b.openInput(.newTab) } content: {
            HStack(spacing: 9) {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 16)
                Text("New Tab")
                Spacer()
            }
            .opacity(0.6)
        }
    }
}

private func prettyURL(_ url: URL?) -> String? {
    guard let url, let host = url.host() else { return url?.absoluteString }
    let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    let path = url.path()
    return path == "/" || path.isEmpty ? h : h + path
}

struct SidebarBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.165, green: 0.149, blue: 0.208),
                                Color(red: 0.114, green: 0.106, blue: 0.141),
                                Color(red: 0.094, green: 0.090, blue: 0.114)],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Rows

struct TabRow: View {
    @ObservedObject var tab: Tab
    @ObservedObject var b: Browser
    @State private var hover = false

    var body: some View {
        let active = tab.id == b.activeID
        HStack(spacing: 9) {
            favicon
            Text(tab.displayTitle).lineLimit(1).truncationMode(.tail)
                .opacity(tab.sleeping && !active ? 0.6 : 1)
            Spacer(minLength: 0)
            if hover {
                Button { b.close(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).opacity(0.7).help("Close (⌘W)")
            }
        }
        .font(.system(size: 13))
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(.white.opacity(active ? 0.15 : hover ? 0.06 : 0))
            .shadow(color: .black.opacity(active ? 0.25 : 0), radius: 1, y: 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .simultaneousGesture(TapGesture().onEnded { b.activate(tab) })
        .help(tab.url?.absoluteString ?? "")
        .contextMenu {
            Button(tab.pinned ? "Unpin Tab" : "Pin Tab") { b.setPinned(tab, !tab.pinned) }
            Button("Duplicate Tab") { b.newTab(tab.url, after: tab) }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.url?.absoluteString ?? "", forType: .string)
            }
            Button("Open in Default Browser") { if let u = tab.url { NSWorkspace.shared.open(u) } }
            Divider()
            Button("Close Tab") { b.close(tab) }
        }
        .onDrag {
            b.dragging = tab
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: TabDrop(target: tab, b: b))
    }

    @ViewBuilder private var favicon: some View {
        if let img = tab.favicon {
            Image(nsImage: img).resizable().interpolation(.high)
                .frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 3))
                .opacity(tab.isLoading ? 0.45 : 1)
        } else {
            RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.18)).frame(width: 16, height: 16)
        }
    }
}

struct TabDrop: DropDelegate {
    let target: Tab
    let b: Browser
    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let d = b.dragging, d !== target else { return }
            withAnimation(.easeOut(duration: 0.12)) { b.move(d, to: target) }
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { b.dragging = nil }
        return true
    }
}

struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hover = false
    var body: some View {
        content()
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hover ? 0.06 : 0)))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
    }
}

struct NavButton: View {
    let symbol: String
    let help: String
    var disabled = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(hover && !disabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.25 : (hover ? 1 : 0.75))
        .disabled(disabled)
        .onHover { hover = $0 }
        .help(help)
    }
}
