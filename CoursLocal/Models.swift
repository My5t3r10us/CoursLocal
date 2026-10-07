import Foundation
import Combine

enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case microphone, application, combined
    var id: String { rawValue }
    var label: String { switch self { case .microphone: return "Microphone"; case .application: return "Application"; case .combined: return "Micro + application" } }
    var usesMicrophone: Bool { self != .application }
    var usesApplication: Bool { self != .microphone }
}

enum CourseState: String, Codable {
    case new, recording, paused, audioReady, importing, importIncomplete, transcribing, generating, ready, interrupted, failed
    static func legacy(_ status: String) -> Self {
        if status == "Enregistrement" { return .recording }
        if status == "En pause" { return .paused }
        if status.hasPrefix("Import incomplet") { return .importIncomplete }
        if status.hasPrefix("Import en cours") { return .importing }
        if status.hasPrefix("Traitement") { return .interrupted }
        if status.hasPrefix("Prêt") { return .ready }
        if status.hasPrefix("Audio") { return .audioReady }
        return .interrupted
    }
}

struct Passage: Codable, Identifiable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
}

struct AudioPart: Codable, Identifiable, Sendable {
    var id = UUID()
    var filename: String
    var duration: Double = 0
    var passages: [Passage]? = nil
    var excluded: Bool? = nil
    var problem: String? = nil
}

struct SourcePassage: Identifiable, Sendable {
    var id: UUID
    var start: Double
    var end: Double
    var text: String
    var promptLine: String { "[\(id.uuidString)] [\(timestamp(start))] \(text)" }
}

struct StudyCard: Codable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var explanation: String
    var question: String
    var answer: String
    var examples: [String] = []
    var references: [UUID]
    enum CodingKeys: String, CodingKey { case id, title, explanation, question, answer, examples, references }
    init(title: String, explanation: String, question: String, answer: String, examples: [String] = [], references: [UUID]) {
        self.title = title; self.explanation = explanation; self.question = question; self.answer = answer
        self.examples = examples; self.references = references
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title); explanation = try c.decode(String.self, forKey: .explanation)
        question = try c.decode(String.self, forKey: .question); answer = try c.decode(String.self, forKey: .answer)
        examples = try c.decodeIfPresent([String].self, forKey: .examples) ?? []
        references = try c.decode([UUID].self, forKey: .references)
    }
    var duplicateKey: String { ([title, explanation, question, answer] + examples).joined(separator: "\n").folding(options: [.caseInsensitive], locale: Locale(identifier: "fr")).split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    var markdown: String {
        "### \(title)\n\n\(explanation)\n\n" + examples.map { "- \($0)" }.joined(separator: "\n") + "\n\n**Question :** \(question)\n\n**Réponse :** \(answer)"
    }
}

// Notes, cards and summaries were produced by version 0.2. They are kept read-only so nothing is lost.
struct StudyResult: Codable, Sendable {
    var notes: String
    var references: [UUID]
    var cards: [StudyCard]
}

struct StudyBlock: Codable, Identifiable, Sendable {
    var id: Int
    var source: String
    var notes: String? = nil
    var cards: String? = nil // Historical Markdown is kept during migration.
    var sourceIDs: [UUID]? = nil
    var result: StudyResult? = nil
}

struct ProcessingConfiguration: Codable, Equatable, Sendable {
    var whisperModel: String
    var language: String
    var studyModel: String
    var baseURL: String
    var promptVersion = 3
    var transcriptRevision: Int
}

/// One turn of the questions panel. Kept with the course, never exported.
struct ChatMessage: Codable, Identifiable, Sendable, Equatable {
    enum Role: String, Codable, Sendable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
}

struct Course: Codable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var parts: [AudioPart] = []
    var blocks: [StudyBlock] = []
    var summary: String? = nil
    var status = "Nouveau cours"
    var whisperModel: String? = nil
    var language: String? = nil
    var studyModel: String? = nil
    var formatVersion = Course.currentFormat
    var state: CourseState = .new
    var captureMode: CaptureMode = .microphone
    var applicationName: String? = nil
    var transcriptRevision = 0
    var resultsObsolete = false
    var configuration: ProcessingConfiguration? = nil
    var lastError: String? = nil
    var synthesis: [String: String] = [:]
    var editedNotes: String? = nil
    var editedCards: [StudyCard]? = nil
    var summaryReferences: [UUID]? = nil
    var cleanBlocks: [CleanBlock] = []
    var themeIndex: ThemeIndex? = nil
    var sheet: CourseSheet? = nil
    var chat: [ChatMessage] = []
    static let currentFormat = 3
    var duration: Double { parts.reduce(0) { $0 + $1.duration } }
    var incomplete: Bool { parts.contains { $0.excluded == true || $0.problem != nil } }
    var sources: [SourcePassage] {
        var offset = 0.0
        return parts.flatMap { part -> [SourcePassage] in
            defer { offset += part.duration }
            guard part.excluded != true else { return [] }
            return (part.passages ?? []).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
                SourcePassage(id: $0.id, start: offset + $0.start, end: offset + $0.end, text: $0.text)
            }
        }
    }
    var transcript: String { sources.map { "[\(timestamp($0.start))] \($0.text)" }.joined(separator: "\n") }
    var notes: String {
        editedNotes ?? blocks.compactMap { block in (block.result?.notes ?? block.notes).map { "## Partie \(block.id + 1)\n\n\($0)" } }.joined(separator: "\n\n")
    }
    var studyCards: [StudyCard] {
        if let editedCards { return editedCards }
        let times = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.start) })
        var cards: [StudyCard] = []; var indexByKey: [String: Int] = [:]
        for card in blocks.flatMap({ $0.result?.cards ?? [] }) {
            if let index = indexByKey[card.duplicateKey] {
                for id in card.references where !cards[index].references.contains(id) { cards[index].references.append(id) }
            } else { indexByKey[card.duplicateKey] = cards.count; cards.append(card) }
        }
        return cards.sorted {
            ($0.references.compactMap { times[$0] }.min() ?? .infinity) < ($1.references.compactMap { times[$0] }.min() ?? .infinity)
        }
    }
    func referenceText(_ ids: [UUID]) -> String {
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        return ids.compactMap { byID[$0].map { "[\(timestamp($0.start))]" } }.joined(separator: " · ")
    }
    var cards: String {
        let current = studyCards.map { $0.markdown + "\n\nSources : " + referenceText($0.references) }.joined(separator: "\n\n")
        if !current.isEmpty { return current }
        return blocks.compactMap { $0.cards }.joined(separator: "\n\n")
    }
    func validateStoredData() throws {
        let passageIDs = parts.flatMap { ($0.passages ?? []).map(\.id) }
        guard Set(parts.map(\.id)).count == parts.count, Set(passageIDs).count == passageIDs.count,
              parts.allSatisfy({ $0.duration.isFinite && $0.duration >= 0 && ($0.passages ?? []).allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start } }) else {
            throw CourseError.message("Métadonnées incohérentes : identifiants dupliqués ou durées invalides.")
        }
    }
    var markdown: String { ObsidianMarkdown.build(self) }
    var legacyMarkdown: String? {
        var parts: [String] = []
        if let summary, !summary.trimmed.isEmpty { parts.append("### Résumé\n\n\(summary)") }
        if !notes.trimmed.isEmpty { parts.append("### Notes\n\n" + notes.replacingOccurrences(of: "\n## ", with: "\n#### ").replacingOccurrences(of: "^## ", with: "#### ", options: .regularExpression)) }
        if !cards.trimmed.isEmpty { parts.append("### Fiches\n\n" + cards.replacingOccurrences(of: "### ", with: "#### ")) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
    /// Everything the library search looks into.
    var searchText: String { [title, transcript, documentText, sheetText, themeGroups.map(\.name).joined(separator: " "), legacyMarkdown ?? ""].joined(separator: "\n") }
    init(title: String, parts: [AudioPart] = [], blocks: [StudyBlock] = []) { self.title = title; self.parts = parts; self.blocks = blocks }
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, parts, blocks, summary, status, whisperModel, language, studyModel, formatVersion, state, captureMode, applicationName, transcriptRevision, resultsObsolete, configuration, lastError, synthesis, editedNotes, editedCards, summaryReferences, cleanBlocks, themeIndex, sheet, chat
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        parts = try c.decodeIfPresent([AudioPart].self, forKey: .parts) ?? []
        blocks = try c.decodeIfPresent([StudyBlock].self, forKey: .blocks) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "Audio disponible"
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        studyModel = try c.decodeIfPresent(String.self, forKey: .studyModel)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        state = try c.decodeIfPresent(CourseState.self, forKey: .state) ?? .legacy(status)
        captureMode = try c.decodeIfPresent(CaptureMode.self, forKey: .captureMode) ?? .microphone
        applicationName = try c.decodeIfPresent(String.self, forKey: .applicationName)
        transcriptRevision = try c.decodeIfPresent(Int.self, forKey: .transcriptRevision) ?? 0
        resultsObsolete = try c.decodeIfPresent(Bool.self, forKey: .resultsObsolete) ?? false
        configuration = try c.decodeIfPresent(ProcessingConfiguration.self, forKey: .configuration)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        synthesis = try c.decodeIfPresent([String: String].self, forKey: .synthesis) ?? [:]
        editedNotes = try c.decodeIfPresent(String.self, forKey: .editedNotes)
        editedCards = try c.decodeIfPresent([StudyCard].self, forKey: .editedCards)
        summaryReferences = try c.decodeIfPresent([UUID].self, forKey: .summaryReferences)
        cleanBlocks = try c.decodeIfPresent([CleanBlock].self, forKey: .cleanBlocks) ?? []
        themeIndex = try c.decodeIfPresent(ThemeIndex.self, forKey: .themeIndex)
        sheet = try c.decodeIfPresent(CourseSheet.self, forKey: .sheet)
        chat = try c.decodeIfPresent([ChatMessage].self, forKey: .chat) ?? []
    }
}

func timestamp(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.isFinite ? max(0, min(seconds, Double(Int.max - 2048))) : 0))
    return String(format: "%02lld:%02lld:%02lld", Int64(value / 3600), Int64(value / 60 % 60), Int64(value % 60))
}

enum CourseError: LocalizedError {
    case message(String)
    /// The model answered, but its output is unusable (malformed, truncated, unfaithful).
    case invalidOutput(String)
    case unauthorized(String)
    /// The answer hit the token limit, often because a reasoning model spent it thinking.
    case truncated(String)
    var errorDescription: String? {
        switch self {
        case .message(let text), .invalidOutput(let text), .unauthorized(let text), .truncated(let text): return text
        }
    }
    static func isModelOutput(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        switch error as? CourseError { case .invalidOutput, .truncated: return true; default: return false }
    }
}

@MainActor
final class OperationGate: ObservableObject {
    @Published private(set) var operation: String?
    var busy: Bool { operation != nil }
    func acquire(_ operation: String) throws {
        guard !busy else { throw CourseError.message("Une opération est déjà en cours : \(self.operation!).") }
        self.operation = operation
    }
    func release() { operation = nil }
}

enum TextChunks {
    // Limit by UTF-8 bytes: conservative for French and for non-Latin text.
    // Keep timestamps on every slice, including unusually long passages.
    static func split(_ text: String, maxBytes: Int = 4500) -> [String] {
        precondition(maxBytes >= 512)
        var chunks: [String] = []
        var current = ""
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            let prefix: String
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                prefix = String(line[...end]) + " "
            } else { prefix = "" }
            let body = prefix.isEmpty ? line : String(line.dropFirst(prefix.count))
            var slice = prefix
            for character in body {
                let value = String(character)
                if slice.utf8.count + value.utf8.count > maxBytes {
                    if !current.isEmpty { chunks.append(current); current = "" }
                    chunks.append(slice)
                    slice = prefix
                }
                slice += value
            }
            if current.utf8.count + slice.utf8.count + 1 > maxBytes {
                if !current.isEmpty { chunks.append(current) }
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + slice
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(current) }
        return chunks
    }
}


extension TextChunks {
    /// Non-overlapping blocks for cleaning: an overlap would duplicate text in the final document.
    /// Each line keeps the identifier of its passage; long passages are cut at sentence boundaries.
    static func cleaningBlocks(_ sources: [SourcePassage], maxCharacters: Int = 3000, maxLine: Int = 800) -> [CleanBlock] {
        precondition(maxLine >= 100 && maxCharacters >= maxLine)
        var blocks: [CleanBlock] = []; var ids: [UUID] = []; var lines: [String] = []; var size = 0
        func emit() {
            guard !lines.isEmpty else { return }
            blocks.append(CleanBlock(id: blocks.count, sourceIDs: ids, lines: lines)); ids = []; lines = []; size = 0
        }
        for passage in sources {
            let text = FillerFilter.clean(passage.text)
            guard !text.isEmpty, !FillerFilter.isHallucination(text) else { continue }
            for line in slices(text, max: maxLine) {
                if size + line.count > maxCharacters { emit() }
                ids.append(passage.id); lines.append(line); size += line.count
            }
        }
        emit(); return blocks
    }
    static func slices(_ text: String, max: Int) -> [String] {
        guard text.count > max else { return [text] }
        var output: [String] = []; var current = ""
        let sentences = text.replacingOccurrences(of: "([.!?…]) ", with: "$1\n", options: .regularExpression).components(separatedBy: "\n")
        for sentence in sentences {
            var rest = Substring(sentence)
            while rest.count > max { // Unusually long sentence: cut on a space when possible.
                let head = rest.prefix(max); let cut = head.lastIndex(of: " ") ?? head.endIndex
                if !current.isEmpty { output.append(current); current = "" }
                output.append(String(rest[..<cut]).trimmed); rest = rest[cut...].drop(while: { $0 == " " })
            }
            if !current.isEmpty && current.count + rest.count + 1 > max { output.append(current); current = "" }
            current += (current.isEmpty ? "" : " ") + rest
        }
        if !current.trimmed.isEmpty { output.append(current) }
        return output.filter { !$0.isEmpty }
    }
}
