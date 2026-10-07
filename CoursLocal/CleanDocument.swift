import Foundation

// MARK: - Stored document

struct CleanParagraph: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var text: String
    var references: [UUID]
}

struct CleanSection: Codable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var theme: String
    var paragraphs: [CleanParagraph]
    var fallback: Bool? = nil // Only the deterministic filter ran: the model failed twice on this block.
    var edited: Bool? = nil
    var fallbackReason: String? = nil
}

struct TranscriptFix: Codable, Hashable, Sendable {
    var from: String
    var to: String
}

struct CleanResult: Codable, Sendable {
    var sections: [CleanSection]
    var fixes: [TranscriptFix] = []
}

/// A slice of the transcript sent in one request. Line `n` of the prompt comes from `sourceIDs[n - 1]`.
struct CleanBlock: Codable, Identifiable, Sendable {
    var id: Int
    var sourceIDs: [UUID]
    var lines: [String]
    var result: CleanResult? = nil
    var prompt: String { lines.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n") }
    var characterCount: Int { lines.reduce(0) { $0 + $1.count } }
}

/// Maps the theme names detected block by block to the harmonized names.
struct ThemeIndex: Codable, Sendable, Equatable {
    var aliases: [String: String] = [:]
    var tags: [String] = []
    func canonical(_ name: String) -> String { aliases[name] ?? aliases.first { $0.key.folded == name.folded }?.value ?? name }
}

/// A section as displayed: adjacent sections sharing title and theme across block boundaries are merged.
struct DocumentSection: Identifiable, Sendable {
    var ids: [UUID]
    var title: String
    var theme: String
    var paragraphs: [CleanParagraph]
    var fallback: Bool
    var edited: Bool
    var fallbackReason: String? = nil
    var start: Double?
    var end: Double?
    var id: UUID { ids[0] }
    var text: String { paragraphs.map(\.text).joined(separator: "\n\n") }
    var references: [UUID] { var seen = Set<UUID>(); return paragraphs.flatMap(\.references).filter { seen.insert($0).inserted } }
}

struct ThemeGroup: Identifiable, Sendable {
    var name: String
    var sections: [DocumentSection]
    var id: String { name }
    var start: Double? { sections.compactMap(\.start).min() }
}

extension String {
    var folded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Course {
    var hasDocument: Bool { cleanBlocks.contains { $0.result != nil } }
    var documentComplete: Bool { !cleanBlocks.isEmpty && cleanBlocks.allSatisfy { $0.result != nil } }
    var documentSections: [DocumentSection] {
        let times = Dictionary(sources.map { ($0.id, ($0.start, $0.end)) }, uniquingKeysWith: { a, _ in a })
        let index = themeIndex ?? ThemeIndex()
        var output: [DocumentSection] = []
        for section in cleanBlocks.flatMap({ $0.result?.sections ?? [] }) {
            let theme = index.canonical(section.theme)
            let refs = section.paragraphs.flatMap(\.references).compactMap { times[$0] }
            let start = refs.map(\.0).min(), end = refs.map(\.1).max()
            if var last = output.last, last.title.folded == section.title.folded, last.theme == theme {
                last.ids.append(section.id); last.paragraphs += section.paragraphs
                last.fallback = last.fallback || section.fallback == true; last.edited = last.edited || section.edited == true
                last.fallbackReason = last.fallbackReason ?? section.fallbackReason
                last.start = [last.start, start].compactMap { $0 }.min(); last.end = [last.end, end].compactMap { $0 }.max()
                output[output.count - 1] = last
            } else {
                output.append(DocumentSection(ids: [section.id], title: section.title, theme: theme, paragraphs: section.paragraphs,
                                              fallback: section.fallback == true, edited: section.edited == true, fallbackReason: section.fallbackReason, start: start, end: end))
            }
        }
        return output
    }
    /// Themes in order of first appearance; a theme revisited later in the course keeps all its sections.
    var themeGroups: [ThemeGroup] {
        var groups: [ThemeGroup] = []
        for section in documentSections {
            if let i = groups.firstIndex(where: { $0.name == section.theme }) { groups[i].sections.append(section) }
            else { groups.append(ThemeGroup(name: section.theme, sections: [section])) }
        }
        return groups
    }
    var transcriptFixes: [TranscriptFix] {
        var seen = Set<String>()
        return cleanBlocks.flatMap { $0.result?.fixes ?? [] }.filter { seen.insert($0.from.folded + "→" + $0.to.folded).inserted }
    }
    var documentText: String { documentSections.map { "\($0.title)\n\($0.text)" }.joined(separator: "\n\n") }
    var wordCount: Int { (hasDocument ? documentText : sources.map(\.text).joined(separator: " ")).split(whereSeparator: \.isWhitespace).count }
}

// MARK: - Deterministic filter

/// Removes unambiguous hesitations and stutters before the text reaches the model.
/// Context-dependent tics ("du coup", "en fait", "voilà"…) are left to the model.
enum FillerFilter {
    private static let hesitation = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}'’-])(?:[eE]+u+h+|[hH]e+u+|[eE]uh+|[hH]u+m+|[hH]m+|[mM]+h+|[bB]a+h|[bB]eh|ben|hein)(?![\\p{L}\\p{N}'’-])(?:\\s*[,…]+|\\.{3})?")
    private static let stutter = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}'’])(\\p{L}+(?:['’]\\p{L}+)?)(?:(?:\\s*,\\s*|\\s+)\\1)+(?![\\p{L}\\p{N}'’])", options: [.caseInsensitive])
    private static let keptRepetitions: Set<String> = ["nous", "vous", "très", "si", "non", "oui", "beaucoup", "plus"]

    // Whisper annotations such as [Musique] or (rires) are not part of the course.
    private static let annotation = try! NSRegularExpression(
        pattern: "\\[[\\p{L} '’-]{1,40}\\]|\\((?:rires?|musique|applaudissements|inaudible|silence|bruit)[^)\\n]{0,30}\\)|\\*(?:rires?|musique)\\*", options: [.caseInsensitive])
    // Phrases Whisper is known to invent on silence in French and English.
    private static let hallucination = try! NSRegularExpression(
        pattern: "^(?:sous-titr(?:age|es?)\\b.*|.*amara\\.org.*|merci d['’]avoir regard[ée] (?:cette|la) vid[ée]o.*|thanks? (?:you )?for watching.*|abonnez-vous.*)$", options: [.caseInsensitive])

    static func isHallucination(_ text: String) -> Bool {
        hallucination.firstMatch(in: text.trimmed, range: NSRange(text.trimmed.startIndex..., in: text.trimmed)) != nil
    }

    static func clean(_ text: String) -> String {
        var value = annotation.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        value = hesitation.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
        for match in stutter.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let whole = Range(match.range, in: value), let word = Range(match.range(at: 1), in: value) else { continue }
            let token = String(value[word])
            if keptRepetitions.contains(token.lowercased()) { continue }
            value.replaceSubrange(whole, with: token)
        }
        value = value.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+([,.…])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "([,;])(?:\\s*[,;])+", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "[,;]\\s*([.!?…])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "^[\\s,;.…]+", with: "", options: .regularExpression)
            .trimmed
        if let first = value.first, first.isLowercase, text.trimmed.first?.isUppercase == true {
            value = first.uppercased() + value.dropFirst()
        }
        return value
    }

    /// Used when the model fails twice: the content is never lost, only less polished.
    static func fallback(_ block: CleanBlock, theme: String, reason: String? = nil) -> CleanResult {
        var paragraphs: [CleanParagraph] = []; var text = ""; var refs: [UUID] = []
        for (line, id) in zip(block.lines, block.sourceIDs) {
            let cleaned = clean(line); guard !cleaned.isEmpty else { continue }
            text += (text.isEmpty ? "" : " ") + cleaned
            if refs.last != id { refs.append(id) }
            if text.count > 700 { paragraphs.append(CleanParagraph(text: text, references: refs)); text = ""; refs = [] }
        }
        if !text.isEmpty { paragraphs.append(CleanParagraph(text: text, references: refs)) }
        let section = CleanSection(title: "Passage non structuré", theme: theme, paragraphs: paragraphs, fallback: true, fallbackReason: reason)
        return CleanResult(sections: paragraphs.isEmpty ? [] : [section])
    }
}

// MARK: - Model responses

/// The JSON returned by the model for one block. Indices refer to the numbered lines of the prompt.
struct CleanResponse: Decodable {
    struct Paragraph: Decodable { var text: String; var sources: [Int]? }
    struct Section: Decodable { var title: String?; var theme: String?; var paragraphs: [Paragraph] }
    struct Fix: Decodable { var from: String; var to: String }
    var sections: [Section]
    var corrections: [Fix]?

    /// Repairs what can be repaired safely (missing or out-of-range sources, empty titles) and rejects
    /// what indicates lost or invented content.
    func result(for block: CleanBlock, fallbackTheme: String) throws -> CleanResult {
        var sections: [CleanSection] = []; var previous: [UUID] = [block.sourceIDs.first].compactMap { $0 }
        var covered = Set<Int>(); var characters = 0
        for raw in self.sections {
            var paragraphs: [CleanParagraph] = []
            for paragraph in raw.paragraphs {
                let text = paragraph.text.trimmed; guard !text.isEmpty else { continue }
                let valid = (paragraph.sources ?? []).filter { $0 >= 1 && $0 <= block.sourceIDs.count }
                covered.formUnion(valid)
                var seen = Set<UUID>(); let refs = valid.map { block.sourceIDs[$0 - 1] }.filter { seen.insert($0).inserted }
                if !refs.isEmpty { previous = [refs.last!] }
                paragraphs.append(CleanParagraph(text: text, references: refs.isEmpty ? previous : refs)); characters += text.count
            }
            guard !paragraphs.isEmpty else { continue }
            let theme = ThemeName.sanitize(raw.theme ?? "").nonEmpty ?? sections.last?.theme ?? fallbackTheme
            let title = ThemeName.sanitize(raw.title ?? "").nonEmpty ?? theme
            sections.append(CleanSection(title: title, theme: theme, paragraphs: paragraphs))
        }
        let source = block.characterCount
        guard !sections.isEmpty else { throw CourseError.invalidOutput("Aucun paragraphe nettoyé.") }
        // Removing tics rarely shortens a passage by half; a shorter answer is a summary, a longer one adds content.
        guard source < 200 || (Double(characters) >= Double(source) * 0.45 && Double(characters) <= Double(source) * 1.6) else {
            throw CourseError.invalidOutput("Le texte nettoyé ne conserve pas le contenu de la source.")
        }
        guard block.sourceIDs.count < 4 || Double(covered.count) >= Double(block.sourceIDs.count) * 0.5 else {
            throw CourseError.invalidOutput("Trop de passages de la source ne sont pas référencés.")
        }
        let haystack = block.lines.joined(separator: " ").folded
        let fixes = (corrections ?? []).map { TranscriptFix(from: $0.from.trimmed, to: $0.to.trimmed) }
            .filter { !$0.from.isEmpty && !$0.to.isEmpty && $0.from.folded != $0.to.folded && haystack.contains($0.from.folded) }
        return CleanResult(sections: sections, fixes: Array(fixes.prefix(40)))
    }
}

struct ThemeResponse: Decodable {
    struct Theme: Decodable { var name: String; var includes: [String]? }
    var themes: [Theme]
    var tags: [String]?

    /// Every detected name maps to exactly one harmonized theme; unknown names are ignored, forgotten ones kept.
    func index(for detected: [String]) -> ThemeIndex {
        var aliases: [String: String] = [:]
        let byFolded = Dictionary(detected.map { ($0.folded, $0) }, uniquingKeysWith: { a, _ in a })
        for theme in themes {
            guard let name = ThemeName.sanitize(theme.name).nonEmpty else { continue }
            for raw in (theme.includes ?? []) + [theme.name] {
                if let original = byFolded[raw.folded], aliases[original] == nil { aliases[original] = name }
            }
        }
        for name in detected where aliases[name] == nil { aliases[name] = name }
        let canonical = Set(aliases.values)
        var tags = (tags ?? []).compactMap { ThemeName.tag($0) }
        if tags.isEmpty { tags = detected.compactMap { aliases[$0] }.filter { canonical.contains($0) }.compactMap { ThemeName.tag($0) } }
        var seen = Set<String>()
        return ThemeIndex(aliases: aliases, tags: tags.filter { seen.insert($0).inserted }.prefix(10).map { $0 })
    }
}

enum ThemeName {
    /// Removes characters that break Obsidian headings, links and tags.
    static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "[#\\[\\]|^\\n\\r\\t*_`]", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .:;,-–—"))
    }
    /// Obsidian tag: no spaces, not purely numeric.
    static func tag(_ value: String) -> String? {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr")).lowercased()
        let slug = folded.replacingOccurrences(of: "[^a-z0-9/_-]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-/_"))
        guard !slug.isEmpty else { return nil }
        return slug.allSatisfy(\.isNumber) ? "t-" + slug : slug
    }
}

extension String {
    var nonEmpty: String? { trimmed.isEmpty ? nil : self }
}
