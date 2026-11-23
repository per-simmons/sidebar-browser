import SwiftUI

/// ⌘Y: History in the sidebar, grouped by day, with search. Replaces the tab list while open.
struct HistoryPanel: View {
    @ObservedObject var b: Browser
    @ObservedObject var history: History
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private struct Day: Identifiable {
        let id: Date
        let label: String
        let entries: [HistoryEntry]
    }

    private var days: [Day] {
        // Without a query, show the most recent 1,500 visits; searching covers everything.
        let list = history.search(query, limit: query.isEmpty ? 1500 : 500)
        let cal = Calendar.current
        var out: [Day] = []
        for e in list {
            let d = cal.startOfDay(for: e.date)
            if out.last?.id == d {
                out[out.count - 1] = Day(id: d, label: out[out.count - 1].label, entries: out[out.count - 1].entries + [e])
            } else {
                out.append(Day(id: d, label: Self.label(for: d), entries: [e]))
            }
        }
        return out
    }

    private static func label(for day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(day, equalTo: Date(), toGranularity: .year) ? "EEEE, MMM d" : "MMM d, yyyy"
        return f.string(from: day)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { b.closeHistory() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).opacity(0.6).help("Back to tabs (⌘Y)")
            }
            .padding(.horizontal, 14).padding(.bottom, 6)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).opacity(0.5)
                TextField("Search history", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { b.closeHistory() }
                    .onSubmit { if let first = days.first?.entries.first { b.openFromHistory(first, background: false) } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).opacity(0.45)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
            .padding(.horizontal, 10).padding(.bottom, 8)

            let groups = days
            if groups.isEmpty {
                Text(query.isEmpty ? "No history yet" : "No matches")
                    .font(.system(size: 12)).opacity(0.45)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { day in
                            Section {
                                ForEach(day.entries) { HistoryRow(entry: $0, b: b, history: history) }
                            } header: {
                                Text(day.label)
                                    .font(.system(size: 11, weight: .semibold)).opacity(0.5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 4)
                                    .background(b.hidden ? AnyView(SidebarBackground()) : AnyView(Color.clear))
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 10)
                }
            }

            if !history.entries.isEmpty {
                Button("Clear History…") { confirmClear() }
                    .buttonStyle(.plain).font(.system(size: 11.5)).opacity(0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
            }
        }
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    private func confirmClear() {
        let a = NSAlert()
        a.messageText = "Clear all browsing history?"
        a.informativeText = "Your open tabs stay. This can't be undone."
        a.addButton(withTitle: "Clear History")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { history.clear() }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    @ObservedObject var b: Browser
    let history: History
    @State private var hover = false

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        HStack(spacing: 9) {
            if let img = b.favicon(forHost: entry.host) {
                Image(nsImage: img).resizable().interpolation(.high)
                    .frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "globe").font(.system(size: 12)).frame(width: 16, height: 16).opacity(0.5)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayTitle).lineLimit(1).truncationMode(.tail)
                Text(entry.host).font(.system(size: 10.5)).opacity(0.45).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Self.time.string(from: entry.date)).font(.system(size: 10.5)).opacity(hover ? 0.6 : 0.35)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            b.openFromHistory(entry, background: NSEvent.modifierFlags.contains(.command))
        }
        .help(entry.url)
        .contextMenu {
            Button("Open in New Tab") { b.openFromHistory(entry, background: false) }
            Button("Open in Background") { b.openFromHistory(entry, background: true) }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url, forType: .string)
            }
            Divider()
            Button("Delete from History") { history.remove(entry) }
            if !entry.host.isEmpty {
                Button("Delete All from \(entry.host)") { history.removeAll(host: entry.host) }
            }
        }
    }
}
