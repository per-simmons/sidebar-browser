import AppKit

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: String
    var title: String
    var date: Date

    var displayTitle: String { title.isEmpty ? (URL(string: url)?.host() ?? url) : title }
    var host: String {
        let h = URL(string: url)?.host() ?? ""
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

/// Every page visited (http/https only), newest first, kept on disk next to state.json.
/// Revisiting the same URL within 30 minutes refreshes the existing entry instead of adding one.
@MainActor
final class History: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    private var saveWork: DispatchWorkItem?
    private static let maxEntries = 20_000
    private static let maxAge: TimeInterval = 180 * 24 * 3600

    static var fileURL: URL { Browser.stateURL.deletingLastPathComponent().appendingPathComponent("history.json") }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    func record(_ url: URL, title: String) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let s = url.absoluteString
        let now = Date()
        if let i = entries.prefix(300).firstIndex(where: { $0.url == s }), now.timeIntervalSince(entries[i].date) < 1800 {
            var e = entries.remove(at: i)
            e.date = now
            if !title.isEmpty { e.title = title }
            entries.insert(e, at: 0)
        } else {
            entries.insert(HistoryEntry(url: s, title: title, date: now), at: 0)
        }
        trim()
        save()
    }

    /// Titles usually arrive after the URL; patch the recent entry for this page.
    func updateTitle(_ url: URL, _ title: String) {
        guard !title.isEmpty, let i = entries.prefix(30).firstIndex(where: { $0.url == url.absoluteString }),
              entries[i].title != title else { return }
        entries[i].title = title
        save()
    }

    func remove(_ e: HistoryEntry) {
        entries.removeAll { $0.id == e.id }
        save()
    }

    func removeAll(host: String) {
        entries.removeAll { $0.host == host }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    func search(_ query: String, limit: Int = .max) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return Array(entries.prefix(limit)) }
        let words = q.split(separator: " ").map(String.init)
        var out: [HistoryEntry] = []
        for e in entries {
            let hay = (e.title + " " + e.url).lowercased()
            if words.allSatisfy(hay.contains) {
                out.append(e)
                if out.count >= limit { break }
            }
        }
        return out
    }

    private func trim() {
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        while let last = entries.last, last.date < cutoff { entries.removeLast() }
    }

    private func save() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    /// `sync` is for quitting, when a background write could be cut off.
    func saveNow(sync: Bool = false) {
        saveWork?.cancel()
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let url = Self.fileURL
        if sync { try? data.write(to: url, options: .atomic) }
        else { DispatchQueue.global(qos: .utility).async { try? data.write(to: url, options: .atomic) } }
    }
}
