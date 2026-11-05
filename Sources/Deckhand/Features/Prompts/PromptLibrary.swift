import Foundation

/// Pure rules for the prompt list: categories, sorting, search. Kept apart from the store and the
/// view model so the self-test can check them without a database or UI.
enum PromptLibrary {
    /// The category of a prompt saved without one. Distinct from the Settings word "General".
    static var defaultCategory: String { String(localized: "prompts.category.general", defaultValue: "General") }

    /// Trims and collapses spaces; a blank category becomes the default one.
    static func normalizedCategory(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? defaultCategory : collapsed
    }

    /// Trimmed, lowercased tags without blanks or duplicates, in their first order.
    static func normalizedTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Tags typed as "a, b, c".
    static func tags(fromText text: String) -> [String] {
        normalizedTags(text.split(separator: ",").map(String.init))
    }

    /// Categories for the chips: one per name regardless of case or extra spaces, spelled the way
    /// most prompts spell it, sorted by name.
    static func categories(of prompts: [Prompt]) -> [String] {
        var spellings: [String: [String: Int]] = [:]
        for p in prompts {
            let name = normalizedCategory(p.category)
            spellings[foldKey(name), default: [:]][name, default: 0] += 1
        }
        return spellings.values
            .compactMap { counts in counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The existing spelling of a category typed in another case, so "code" joins "Code".
    static func canonicalCategory(_ raw: String, existing: [String]) -> String {
        let name = normalizedCategory(raw)
        return existing.first { foldKey($0) == foldKey(name) } ?? name
    }

    static func sameCategory(_ a: String, _ b: String) -> Bool {
        foldKey(normalizedCategory(a)) == foldKey(normalizedCategory(b))
    }

    private static func foldKey(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Prompts in the chosen category (nil for all) that match the search in title, text, tags or category.
    static func filter(_ prompts: [Prompt], category: String?, search: String) -> [Prompt] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompts.filter { p in
            if let category, !sameCategory(p.category, category) { return false }
            guard !query.isEmpty else { return true }
            return p.title.localizedStandardContains(query)
                || p.body.localizedStandardContains(query)
                || p.category.localizedStandardContains(query)
                || p.tags.contains { $0.localizedStandardContains(query) }
        }
    }

    static func sorted(_ prompts: [Prompt], by sort: PromptSort) -> [Prompt] {
        prompts.sorted { a, b in
            switch sort {
            case .favoritesAndUsage:
                if a.favorite != b.favorite { return a.favorite }
                if a.usageCount != b.usageCount { return a.usageCount > b.usageCount }
                return a.updatedAt > b.updatedAt
            case .name:
                let order = a.title.localizedStandardCompare(b.title)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            case .recentlyEdited:
                return a.updatedAt == b.updatedAt ? a.id > b.id : a.updatedAt > b.updatedAt
            }
        }
    }

    /// Keeps rows where they are on screen and appends new ones, so clicking a prompt (which
    /// bumps its use count) doesn't move it under the pointer. The full sort runs on the next open.
    static func keepingOrder(of shown: [Prompt], fresh: [Prompt]) -> [Prompt] {
        let byId = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = shown.compactMap { byId[$0.id] }
        let keptIds = Set(kept.map(\.id))
        return kept + fresh.filter { !keptIds.contains($0.id) }
    }

    /// A title for a prompt saved without one: its first line, shortened.
    static func title(fromBody body: String) -> String {
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if line.isEmpty { return String(localized: "New Prompt") }
        return line.count > 48 ? String(line.prefix(47)).trimmingCharacters(in: .whitespaces) + "…" : line
    }
}

/// `{{name}}` placeholders in a prompt that are filled in before copying.
enum PromptTemplate {
    /// Variable names in order of first appearance, without duplicates. Names are trimmed;
    /// empty braces and names with braces or line breaks are not variables.
    static func variables(in body: String) -> [String] {
        var names: [String] = []
        for match in matches(in: body) where !names.contains(match.name) {
            names.append(match.name)
        }
        return names
    }

    /// Replaces each `{{name}}` with its value. Variables without a value are left as typed.
    static func fill(_ body: String, values: [String: String]) -> String {
        var out = ""
        var index = body.startIndex
        for match in matches(in: body) {
            out += body[index..<match.range.lowerBound]
            out += values[match.name] ?? String(body[match.range])
            index = match.range.upperBound
        }
        out += body[index...]
        return out
    }

    private struct Match {
        let name: String
        let range: Range<String.Index>
    }

    private static func matches(in body: String) -> [Match] {
        var result: [Match] = []
        var search = body.startIndex..<body.endIndex
        while let open = body.range(of: "{{", range: search) {
            guard let close = body.range(of: "}}", range: open.upperBound..<body.endIndex) else { break }
            let inner = body[open.upperBound..<close.lowerBound]
            // "{{{x}}}" or a stray "{{" before a real variable: start again at the innermost "{{"
            if let nested = inner.range(of: "{{", options: .backwards) {
                search = nested.lowerBound..<body.endIndex
                continue
            }
            let name = inner.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !name.contains(where: { $0.isNewline || $0 == "{" || $0 == "}" }), name.count <= 40 {
                result.append(Match(name: name, range: open.lowerBound..<close.upperBound))
            }
            search = close.upperBound..<body.endIndex
        }
        return result
    }
}

/// The order of the prompt list.
enum PromptSort: String, CaseIterable, Identifiable {
    case favoritesAndUsage, name, recentlyEdited
    var id: String { rawValue }
}

/// What a click (or Return) on a prompt does.
enum PromptClickAction: String, CaseIterable, Identifiable {
    case copy, paste
    var id: String { rawValue }
}
