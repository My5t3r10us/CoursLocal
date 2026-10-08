import Foundation

// MARK: - Stored sheet

/// The course sheet, written freely in Markdown by the model from the cleaned text: the model chooses the titles,
/// the parts and the form. A long course is written in several requests, each continuing the previous ones;
/// each part is saved so a run can resume.
struct CourseSheet: Codable, Sendable {
    var sourceCount = 0
    var parts: [String] = []
    var markdown: String { parts.joined(separator: "\n\n") }
    var complete: Bool { sourceCount > 0 && parts.count >= sourceCount }

    init(sourceCount: Int = 0, parts: [String] = []) { self.sourceCount = sourceCount; self.parts = parts }

    private enum CodingKeys: String, CodingKey { case sourceCount, parts, themes, overview, takeaways, questions, chapters, introduction, conclusion }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let parts = try c.decodeIfPresent([String].self, forKey: .parts) {
            self.parts = parts; sourceCount = try c.decodeIfPresent(Int.self, forKey: .sourceCount) ?? parts.count
            return
        }
        // Earlier sheets had a fixed form; finished ones are kept as Markdown, unfinished ones are started again.
        var text: [String] = []
        if let overview = try c.decodeIfPresent(String.self, forKey: .overview) {
            text.append("## L’essentiel\n\n" + overview)
            let takeaways = try c.decodeIfPresent([String].self, forKey: .takeaways) ?? []
            if !takeaways.isEmpty { text.append("## À retenir\n\n" + takeaways.map { "- " + $0 }.joined(separator: "\n")) }
            text += (try c.decodeIfPresent([LegacyTheme].self, forKey: .themes) ?? []).map(\.markdown)
        } else if let introduction = try c.decodeIfPresent(String.self, forKey: .introduction) {
            text.append("## Introduction\n\n" + introduction)
            text += (try c.decodeIfPresent([LegacyChapter].self, forKey: .chapters) ?? []).map(\.markdown)
            if let conclusion = try c.decodeIfPresent(String.self, forKey: .conclusion), !conclusion.isEmpty { text.append("## Conclusion\n\n" + conclusion) }
        }
        let questions = try c.decodeIfPresent([LegacyQuestion].self, forKey: .questions) ?? []
        if !text.isEmpty && !questions.isEmpty {
            text.append("## Questions de révision\n\n" + questions.map { "**\($0.question)**\n\n\($0.answer)" }.joined(separator: "\n\n"))
        }
        parts = text.isEmpty ? [] : [text.joined(separator: "\n\n")]; sourceCount = parts.count
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceCount, forKey: .sourceCount); try c.encode(parts, forKey: .parts)
    }
}

private struct LegacyQuestion: Decodable { var question: String; var answer: String }

private struct LegacyTheme: Decodable {
    struct Definition: Decodable { var term: String; var definition: String }
    var theme: String
    var summary: String
    var keyPoints: [String]
    var definitions: [Definition]?
    var examples: [String]?
    var examHints: [String]?
    var markdown: String {
        var out = ["## \(theme)", summary, keyPoints.map { "- " + $0 }.joined(separator: "\n")]
        out += (definitions ?? []).map { "**\($0.term)** : \($0.definition)" }
        out += (examples ?? []).map { "*Exemple :* " + $0 }
        out += (examHints ?? []).map { "**Important :** " + $0 }
        return out.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

private struct LegacyChapter: Decodable {
    struct Block: Decodable { var kind: String; var title: String?; var text: String?; var items: [String]? }
    var title: String
    var introduction: String?
    var blocks: [Block]
    var markdown: String {
        var out = ["## \(title)", introduction ?? ""]
        for block in blocks {
            let title = block.title ?? "", text = block.text ?? "", items = (block.items ?? []).map { "- " + $0 }.joined(separator: "\n")
            switch block.kind {
            case "heading": out.append("### " + text)
            case "subheading": out.append("#### " + text)
            case "definition": out.append("**\(title)** : \(text)")
            default: out += [[title.isEmpty ? "" : "**\(title)**", text].filter { !$0.isEmpty }.joined(separator: " : "), items]
            }
        }
        return out.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

extension Course {
    var sheetComplete: Bool { sheet?.complete == true }
    var hasSheet: Bool { !(sheet?.markdown.trimmed.isEmpty ?? true) }
    var sheetText: String { sheet?.markdown ?? "" }
}

enum SheetSources {
    /// Splits the cleaned text into sources that fit one request, between paragraphs and in the order of the course.
    static func chunks(_ sections: [DocumentSection], maxCharacters: Int) -> [String] {
        var chunks: [String] = []; var current = ""
        for paragraph in sections.flatMap(\.paragraphs).map(\.text) where !paragraph.trimmed.isEmpty {
            if !current.isEmpty && current.count + paragraph.count > maxCharacters { chunks.append(current); current = "" }
            current += (current.isEmpty ? "" : "\n\n") + paragraph
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Removes what the model may wrap around the Markdown and keeps level 1 free for the course title.
    static func normalize(_ text: String) -> String {
        var lines = text.trimmed.components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.trimmed == "```" { lines.removeLast() }
        if lines.contains(where: { $0.hasPrefix("# ") }) {
            lines = lines.map { $0.hasPrefix("#") && $0.drop { $0 == "#" }.hasPrefix(" ") && !$0.hasPrefix("######") ? "#" + $0 : $0 }
        }
        return lines.joined(separator: "\n").trimmed
    }

    static func headings(_ markdown: String) -> [String] {
        markdown.components(separatedBy: "\n").filter { $0.hasPrefix("#") }
    }
}

// MARK: - Requests

extension RapidMLXClient {
    static let sheetInstruction = """
    Voici le texte nettoyé d'un cours oral. Rédige la fiche de cours correspondante, en Markdown.
    - But : résumer. Écris de petits paragraphes de 2 à 4 phrases, va à l'essentiel, supprime les redites, les digressions et les tournures orales, sans perdre les notions, définitions, chiffres, exemples utiles ni ce que le professeur signale comme important.
    - Structure : c'est à toi de la choisir, selon le contenu de ce cours. Crée les titres, sous-titres et parties qui le rendent le plus clair (## pour les grandes parties, ### et #### en dessous) ; regroupe les idées liées même si elles sont dispersées dans la source. N'écris pas de titre de niveau # : le titre du cours est déjà affiché.
    - Forme : privilégie les petits paragraphes. Utilise une liste, du gras ou un tableau seulement quand c'est vraiment plus clair.
    Écris le contenu lui-même (« La mémoire de travail… »), jamais « le professeur explique que… ». N'ajoute aucune information absente de la source. Ignore les passages manifestement mal transcrits plutôt que d'inventer leur sens. Rédige dans la langue du cours.
    Réponds uniquement avec la fiche en Markdown, sans phrase d'introduction ni commentaire.
    """

    func sheetSourceLimit(_ settings: AISettings) -> Int { settings.provider == .openRouter ? 60_000 : 6000 }

    /// Writes the sheet of one source. After the first source, the model continues the sheet already written.
    func sheetPart(settings: AISettings, courseTitle: String, source: String, written: String) async throws -> String {
        var instruction = Self.sheetInstruction + "\nCours : « \(courseTitle) »."
        if !written.isEmpty {
            let headings = SheetSources.headings(written).suffix(40).joined(separator: "\n")
            instruction += "\nCette source est la suite du cours. La fiche déjà rédigée a ces titres :\n\(headings.isEmpty ? "(aucun)" : headings)\n"
                + "Elle se termine ainsi : « …\(written.suffix(400)) »\n"
                + "Écris uniquement la suite de la fiche : poursuis la partie en cours ou ouvre de nouvelles parties si le sujet change, sans répéter ce qui précède."
        }
        var tokens = settings.provider == .openRouter ? 16_000 : 4000
        var task = instruction
        for attempt in 0...1 {
            do {
                let text = SheetSources.normalize(try await generate(settings: settings, task: task, source: source, maxTokens: tokens))
                guard text.count >= min(200, source.count / 10) else { throw CourseError.invalidOutput("Fiche vide ou trop courte.") }
                return text
            } catch where CourseError.isModelOutput(error) {
                if attempt == 1 { throw CourseError.invalidOutput("La fiche n’a pas pu être générée : \(error.localizedDescription) Réessaie ou choisis un autre modèle.") }
                if case .truncated = error as? CourseError { tokens = min(settings.provider == .openRouter ? 64_000 : 8000, tokens * 2) }
                task = instruction + "\nLa tentative précédente était invalide (\(error.localizedDescription)). Réponds uniquement avec la fiche en Markdown."
            }
        }
        throw CourseError.invalidOutput("Fiche invalide.")
    }
}
