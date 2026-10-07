import Foundation

// MARK: - Stored sheet

struct SheetDefinition: Codable, Hashable, Sendable {
    var term: String
    var definition: String
}

struct SheetQuestion: Codable, Hashable, Sendable {
    var question: String
    var answer: String
}

/// The course sheet of one theme, written from the cleaned text of its sections.
struct ThemeSheet: Codable, Identifiable, Sendable {
    var id = UUID()
    var theme: String
    var summary: String
    var keyPoints: [String]
    var definitions: [SheetDefinition] = []
    var examples: [String] = []
    var examHints: [String] = []
}

/// Built theme by theme, then completed by an overview: each step is saved so a run can resume.
struct CourseSheet: Codable, Sendable {
    var themes: [ThemeSheet] = []
    var overview: String? = nil
    var takeaways: [String] = []
    var questions: [SheetQuestion] = []
    var complete: Bool { overview != nil }
}

extension Course {
    var sheetComplete: Bool { sheet?.complete == true }
    /// Theme sheets in the order of the document, whatever order they were generated in.
    var orderedThemeSheets: [ThemeSheet] {
        let order = themeGroups.map(\.name)
        return (sheet?.themes ?? []).sorted { (order.firstIndex(of: $0.theme) ?? .max) < (order.firstIndex(of: $1.theme) ?? .max) }
    }
    var sheetText: String {
        guard let sheet else { return "" }
        return ([sheet.overview ?? ""] + sheet.takeaways + sheet.themes.flatMap { [$0.theme, $0.summary] + $0.keyPoints + $0.definitions.map { "\($0.term) \($0.definition)" } + $0.examples }
                + sheet.questions.flatMap { [$0.question, $0.answer] }).joined(separator: "\n")
    }
}

// MARK: - Model responses

struct ThemeSheetResponse: Decodable {
    struct Definition: Decodable { var term: String; var definition: String }
    var summary: String
    var key_points: [String]?
    var definitions: [Definition]?
    var examples: [String]?
    var exam_hints: [String]?

    func sheet(theme: String) throws -> ThemeSheet {
        func clean(_ items: [String]?, _ limit: Int) -> [String] {
            var seen = Set<String>()
            return (items ?? []).map(\.trimmed).filter { !$0.isEmpty && seen.insert($0.folded).inserted }.prefix(limit).map { $0 }
        }
        let summary = summary.trimmed, points = clean(key_points, 12)
        guard !summary.isEmpty, !points.isEmpty else { throw CourseError.invalidOutput("Fiche sans synthèse ni points clés.") }
        var terms = Set<String>()
        let definitions = (definitions ?? []).map { SheetDefinition(term: $0.term.trimmed, definition: $0.definition.trimmed) }
            .filter { !$0.term.isEmpty && !$0.definition.isEmpty && terms.insert($0.term.folded).inserted }
        return ThemeSheet(theme: theme, summary: summary, keyPoints: points, definitions: Array(definitions.prefix(15)),
                          examples: clean(examples, 8), examHints: clean(exam_hints, 6))
    }
}

struct OverviewResponse: Decodable {
    struct Question: Decodable { var question: String; var answer: String }
    var overview: String
    var takeaways: [String]?
    var questions: [Question]?

    func apply(to sheet: inout CourseSheet) throws {
        guard !overview.trimmed.isEmpty else { throw CourseError.invalidOutput("Synthèse du cours vide.") }
        var seen = Set<String>()
        sheet.overview = overview.trimmed
        sheet.takeaways = (takeaways ?? []).map(\.trimmed).filter { !$0.isEmpty && seen.insert($0.folded).inserted }.prefix(10).map { $0 }
        sheet.questions = (questions ?? []).map { SheetQuestion(question: $0.question.trimmed, answer: $0.answer.trimmed) }
            .filter { !$0.question.isEmpty && !$0.answer.isEmpty }.prefix(8).map { $0 }
    }
}

enum SheetMerge {
    /// A theme too long for one request is summarized in parts; the parts are joined without another call.
    static func merge(_ parts: [ThemeSheet], theme: String) -> ThemeSheet {
        guard parts.count > 1 else { return parts.first ?? ThemeSheet(theme: theme, summary: "", keyPoints: []) }
        func unique(_ items: [String]) -> [String] { var seen = Set<String>(); return items.filter { seen.insert($0.folded).inserted } }
        var terms = Set<String>()
        return ThemeSheet(theme: theme, summary: parts.map(\.summary).joined(separator: "\n\n"),
                          keyPoints: unique(parts.flatMap(\.keyPoints)),
                          definitions: parts.flatMap(\.definitions).filter { terms.insert($0.term.folded).inserted },
                          examples: unique(parts.flatMap(\.examples)), examHints: unique(parts.flatMap(\.examHints)))
    }
    /// Splits the cleaned sections of a theme into sources that fit one request, never cutting a section.
    static func sources(for group: ThemeGroup, maxCharacters: Int) -> [String] {
        var chunks: [String] = []; var current = ""
        for section in group.sections {
            let piece = "### \(section.title)\n\n\(section.text)"
            if !current.isEmpty && current.count + piece.count > maxCharacters { chunks.append(current); current = "" }
            current += (current.isEmpty ? "" : "\n\n") + piece
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

// MARK: - Requests

extension RapidMLXClient {
    static let themeSheetInstruction = """
    Voici une partie d'un cours oral, déjà nettoyée et découpée en sections. Rédige la fiche de cours de cette partie, comme le ferait un excellent étudiant qui prépare ses révisions.
    - "summary" : une synthèse rédigée de 3 à 6 phrases qui explique les idées dans un ordre logique. Écris le contenu lui-même (« La mémoire de travail… »), jamais « le professeur explique que… ».
    - "key_points" : 3 à 8 points essentiels ; chacun est une phrase autonome, précise, avec les chiffres, noms, conditions et nuances donnés dans le cours.
    - "definitions" : les notions définies ou employées comme termes techniques, avec une définition fidèle au cours. Liste vide s'il n'y en a pas.
    - "examples" : les exemples, cas concrets ou anecdotes cités, résumés en une phrase qui dit ce qu'ils illustrent. Liste vide s'il n'y en a pas.
    - "exam_hints" : ce que le professeur signale comme important, à savoir, ou susceptible de tomber à l'examen. Liste vide s'il ne le fait pas.
    N'ajoute aucune information absente de la source. Ignore les apartés, digressions et passages manifestement mal transcrits plutôt que d'inventer leur sens. Rédige dans la langue du cours.
    Réponds uniquement avec ce JSON : {"summary":"…","key_points":["…"],"definitions":[{"term":"…","definition":"…"}],"examples":["…"],"exam_hints":["…"]}
    """
    static let overviewInstruction = """
    Voici les fiches de chaque partie d'un cours, dans l'ordre. Rédige la synthèse globale de la fiche de cours :
    - "overview" : l'essentiel du cours en 4 à 8 phrases : sujet, problématique, enchaînement des parties et conclusion.
    - "takeaways" : 5 à 10 points à retenir absolument, formulés comme des affirmations précises.
    - "questions" : 4 à 8 questions de révision variées (définition, explication, application) avec une réponse courte et exacte.
    Appuie-toi uniquement sur ces fiches ; n'ajoute aucune connaissance extérieure. Rédige dans la langue du cours.
    Réponds uniquement avec ce JSON : {"overview":"…","takeaways":["…"],"questions":[{"question":"…","answer":"…"}]}
    """
    static let themeSheetSchema = object([
        "summary": ["type": "string"], "key_points": array(["type": "string"]),
        "definitions": array(object(["term": ["type": "string"], "definition": ["type": "string"]])),
        "examples": array(["type": "string"]), "exam_hints": array(["type": "string"])
    ])
    static let overviewSchema = object([
        "overview": ["type": "string"], "takeaways": array(["type": "string"]),
        "questions": array(object(["question": ["type": "string"], "answer": ["type": "string"]]))
    ])

    /// Same retry policy as cleaning: one corrective attempt, a larger budget after a truncated answer.
    private func sheetRequest<R>(settings: AISettings, instruction: String, source: String, schema: (name: String, value: [String: Any]), parse: (Data) throws -> R) async throws -> R {
        var tokens = settings.provider == .openRouter ? 16_000 : 3000
        var task = instruction
        for attempt in 0...1 {
            do {
                let text = try await generate(settings: settings, task: task, source: source, schema: schema, maxTokens: tokens)
                return try parse(Data(Self.jsonObject(text).utf8))
            } catch where CourseError.isModelOutput(error) {
                if attempt == 1 { throw CourseError.invalidOutput("La fiche n’a pas pu être générée : \(error.localizedDescription) Réessaie ou choisis un autre modèle.") }
                if case .truncated = error as? CourseError { tokens = min(settings.provider == .openRouter ? 64_000 : 8000, tokens * 2) }
                task = instruction + "\nLa tentative précédente était invalide (\(error.localizedDescription)). Respecte exactement le JSON demandé."
            }
        }
        throw CourseError.invalidOutput("Fiche invalide.")
    }

    func themeSheet(settings: AISettings, group: ThemeGroup, courseTitle: String) async throws -> ThemeSheet {
        let limit = settings.provider == .openRouter ? 24_000 : 6000
        let instruction = Self.themeSheetInstruction + "\nCours : « \(courseTitle) ». Partie : « \(group.name) »."
        var parts: [ThemeSheet] = []
        for source in SheetMerge.sources(for: group, maxCharacters: limit) {
            parts.append(try await sheetRequest(settings: settings, instruction: instruction, source: source, schema: ("theme_sheet", Self.themeSheetSchema)) {
                try JSONDecoder().decode(ThemeSheetResponse.self, from: $0).sheet(theme: group.name)
            })
        }
        return SheetMerge.merge(parts, theme: group.name)
    }

    /// Returns the sheet completed with the overview, takeaways and revision questions.
    func overview(settings: AISettings, courseTitle: String, sheet: CourseSheet, themes: [ThemeSheet]) async throws -> CourseSheet {
        let source = themes.map { theme in
            "## \(theme.theme)\n\(theme.summary)\n" + theme.keyPoints.map { "- \($0)" }.joined(separator: "\n")
                + (theme.definitions.isEmpty ? "" : "\nDéfinitions : " + theme.definitions.map { "\($0.term) : \($0.definition)" }.joined(separator: " ; "))
        }.joined(separator: "\n\n")
        return try await sheetRequest(settings: settings, instruction: Self.overviewInstruction + "\nCours : « \(courseTitle) ».",
                                      source: source, schema: ("course_overview", Self.overviewSchema)) { data in
            var completed = sheet
            try JSONDecoder().decode(OverviewResponse.self, from: data).apply(to: &completed)
            return completed
        }
    }
}
