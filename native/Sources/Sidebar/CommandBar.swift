import SwiftUI

/// Arc-style command bar: a centered pop-up over the page for ⌘T.
/// Type a URL to go there, anything else searches Google, or pick an open tab to switch to it.
struct CommandBarView: View {
    @ObservedObject var b: Browser
    @FocusState private var focused: Bool
    @State private var selection = 0

    struct Suggestion: Identifiable {
        enum Kind { case go(URL), tab(Tab) }
        let id: String
        let kind: Kind
        let icon: String
        let title: String
        let detail: String
    }

    private var suggestions: [Suggestion] {
        let text = b.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var out: [Suggestion] = []
        if let url = Browser.resolve(text) {
            let isSearch = url.host() == "www.google.com" && url.path() == "/search"
            out.append(Suggestion(id: "go", kind: .go(url),
                                  icon: isSearch ? "magnifyingglass" : "globe",
                                  title: isSearch ? text : (url.host() ?? url.absoluteString),
                                  detail: isSearch ? "Search Google" : "Open"))
        }
        let q = text.lowercased()
        let matches = b.tabs.filter {
            $0.displayTitle.lowercased().contains(q) || ($0.url?.absoluteString.lowercased().contains(q) ?? false)
        }
        for t in matches.prefix(6) {
            out.append(Suggestion(id: t.id.uuidString, kind: .tab(t), icon: "square.on.square",
                                  title: t.displayTitle, detail: "Switch to Tab"))
        }
        return out
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { b.closeInput() }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .medium)).opacity(0.5)
                    TextField("Search or enter URL…", text: $b.inputText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 19))
                        .focused($focused)
                        .onSubmit { submit() }
                        .onExitCommand { b.closeInput() }
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.tab) { move(1); return .handled }
                }
                .padding(.horizontal, 18)
                .frame(height: 58)

                let items = suggestions
                if !items.isEmpty {
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, s in
                            row(s, selected: i == selection)
                                .contentShape(Rectangle())
                                .onTapGesture { run(s) }
                                .onHover { if $0 { selection = i } }
                        }
                    }
                    .padding(6)
                }
            }
            .frame(width: 640)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.13, green: 0.12, blue: 0.16).opacity(0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 40, y: 18)
            .padding(.top, 150)
        }
        .foregroundStyle(Color(white: 0.94))
        .environment(\.colorScheme, .dark)
        .onAppear { selection = 0; DispatchQueue.main.async { focused = true } }
        .onChange(of: b.inputText) { _, _ in selection = 0 }
        .onChange(of: b.inputMode) { _, m in
            if m == .newTab { selection = 0; DispatchQueue.main.async { focused = true } }
        }
    }

    private func row(_ s: Suggestion, selected: Bool) -> some View {
        HStack(spacing: 12) {
            if case .tab(let t) = s.kind, let img = t.favicon {
                Image(nsImage: img).resizable().interpolation(.high)
                    .frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 3))
                    .frame(width: 22)
            } else {
                Image(systemName: s.icon).font(.system(size: 14, weight: .medium)).frame(width: 22).opacity(0.7)
            }
            Text(s.title).font(.system(size: 14)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text(s.detail).font(.system(size: 12)).opacity(selected ? 0.75 : 0.45)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(selected ? Color(red: 0.63, green: 0.55, blue: 1).opacity(0.32) : .clear))
    }

    private func move(_ d: Int) {
        let n = suggestions.count
        guard n > 0 else { return }
        selection = (selection + d + n) % n
    }

    private func submit() {
        let items = suggestions
        if items.indices.contains(selection) { run(items[selection]) } else { b.closeInput() }
    }

    private func run(_ s: Suggestion) {
        switch s.kind {
        case .go: b.submitInput()
        case .tab(let t): b.closeInput(); b.activate(t)
        }
    }
}
