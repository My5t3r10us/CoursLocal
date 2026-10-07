import Foundation
import AppKit
import UniformTypeIdentifiers

enum DocumentLayout: String, CaseIterable, Identifiable, Sendable {
    case themes, chronological
    var id: String { rawValue }
    var label: String { self == .themes ? "Par thème" : "Chronologique" }
}

/// Builds a Markdown note that Obsidian reads natively: YAML properties, tags, heading links and callouts.
enum ObsidianMarkdown {
    /// The note with the person's export preferences.
    static func current(_ course: Course) -> String {
        let d = UserDefaults.standard
        return build(course, layout: DocumentLayout(rawValue: d.string(forKey: "documentLayout") ?? "") ?? .themes,
                     includeTranscript: d.object(forKey: "exportTranscript") as? Bool ?? true,
                     includeText: d.object(forKey: "exportCleanText") as? Bool ?? true)
    }

    static func build(_ course: Course, layout: DocumentLayout = .themes, includeTranscript: Bool = true, includeText: Bool = true) -> String {
        let groups = course.themeGroups
        let hasSheet = !(course.sheet?.themes.isEmpty ?? true)
        // Below a sheet, the cleaned text moves one heading level down.
        let (themeLevel, sectionLevel, chronoLevel) = hasSheet ? ("###", "####", "###") : ("##", "###", "##")
        var out = frontmatter(course, themes: groups.map(\.name))
        out += "# \(ThemeName.sanitize(course.title).nonEmpty ?? "Cours")\n\n"
        if course.incomplete { out += callout("warning", "Cours incomplet", "Certaines portions audio sont indisponibles ou exclues.") }
        if course.resultsObsolete { out += callout("warning", "Résultats obsolètes", "La transcription ou les sources ont été modifiées depuis la génération.") }
        if course.hasDocument && !course.documentComplete { out += callout("warning", "Document partiel", "Le nettoyage n’est pas terminé pour toutes les parties du cours.") }
        if hasSheet { out += sheet(course) }
        if course.hasDocument && (includeText || !hasSheet) {
            if hasSheet { out += "## Texte nettoyé\n\n" }
            switch layout {
            case .themes:
                if groups.count > 1 && !hasSheet {
                    out += "## Sommaire\n\n" + groups.map { "- [[#\($0.name)]]" + ($0.start.map { " · `\(timestamp($0))`" } ?? "") }.joined(separator: "\n") + "\n\n"
                }
                for group in groups {
                    out += "\(themeLevel) \(group.name)\n\n"
                    for section in group.sections { out += self.section(section, level: sectionLevel, showTheme: false) }
                }
            case .chronological:
                for section in course.documentSections { out += self.section(section, level: chronoLevel, showTheme: true) }
            }
        }
        if course.hasDocument {
            let fixes = course.transcriptFixes
            if !fixes.isEmpty {
                let rows = ["| Transcrit | Corrigé |", "| --- | --- |"] + fixes.map { "| \(cell($0.from)) | \(cell($0.to)) |" }
                out += foldable("info", "Corrections de transcription (\(fixes.count))", rows.joined(separator: "\n"))
            }
        } else {
            out += callout("todo", "Document à générer", "Lance « Nettoyer et structurer » dans CoursLocal.")
        }
        if let legacy = course.legacyMarkdown { out += foldable("note", "Anciens résultats (notes et fiches)", legacy) }
        if includeTranscript && !course.sources.isEmpty {
            out += foldable("quote", "Transcription brute", course.sources.map { "`\(timestamp($0.start))` \($0.text)" }.joined(separator: "\n"))
        }
        return out.trimmingCharacters(in: .newlines) + "\n"
    }

    private static func frontmatter(_ course: Course, themes: [String]) -> String {
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.dateFormat = "yyyy-MM-dd"
        var tags = ["cours"] + (course.themeIndex?.tags ?? []) + themes.compactMap { ThemeName.tag($0) }
        var seen = Set<String>(); tags = tags.filter { seen.insert($0).inserted }
        var lines = ["---", "title: \(yaml(course.title))", "date: \(date.string(from: course.createdAt))",
                     "duration: \(yaml(timestamp(course.duration)))", "source: CoursLocal"]
        if let language = course.language { lines.append("language: \(language)") }
        lines.append("tags:"); lines += tags.map { "  - \($0)" }
        if !themes.isEmpty { lines.append("themes:"); lines += themes.map { "  - \(yaml($0))" } }
        if course.incomplete || course.resultsObsolete { lines.append("status: \(course.incomplete ? "incomplet" : "obsolète")") }
        return (lines + ["---", "", ""]).joined(separator: "\n")
    }

    private static func sheet(_ course: Course) -> String {
        guard let sheet = course.sheet else { return "" }
        let starts = Dictionary(course.themeGroups.map { ($0.name, $0.start) }, uniquingKeysWith: { a, _ in a })
        var out = ""
        if let overview = sheet.overview { out += callout("abstract", "L’essentiel", overview) }
        else { out += callout("warning", "Fiche incomplète", "La synthèse globale n’a pas encore été générée.") }
        if !sheet.takeaways.isEmpty { out += "## À retenir\n\n" + list(sheet.takeaways) + "\n\n" }
        for theme in course.orderedThemeSheets {
            out += "## \(theme.theme)\n\n"
            if let start = starts[theme.theme] ?? nil { out += "`\(timestamp(start))`\n\n" }
            out += theme.summary + "\n\n"
            out += "**Points clés**\n\n" + list(theme.keyPoints) + "\n\n"
            if !theme.definitions.isEmpty { out += "**Définitions**\n\n" + theme.definitions.map { "- **\($0.term)** : \($0.definition)" }.joined(separator: "\n") + "\n\n" }
            if !theme.examples.isEmpty { out += "**Exemples**\n\n" + list(theme.examples) + "\n\n" }
            if !theme.examHints.isEmpty { out += callout("important", "Signalé par le professeur", list(theme.examHints)) }
        }
        if !sheet.questions.isEmpty {
            out += "## Questions de révision\n\n" + sheet.questions.map { foldable("question", $0.question, $0.answer) }.joined()
        }
        return out
    }
    private static func list(_ items: [String]) -> String { items.map { "- " + $0 }.joined(separator: "\n") }

    private static func section(_ section: DocumentSection, level: String, showTheme: Bool) -> String {
        var out = "\(level) \(section.title)\n\n"
        var meta: [String] = []
        if let start = section.start { meta.append("`\(timestamp(start))" + (section.end.map { " → \(timestamp($0))" } ?? "") + "`") }
        if showTheme, let tag = ThemeName.tag(section.theme) { meta.append("#\(tag)") }
        if !meta.isEmpty { out += meta.joined(separator: " · ") + "\n\n" }
        if section.fallback { out += callout("caution", "Nettoyage simplifié", "Le modèle n’a pas pu structurer ce passage ; seules les hésitations évidentes ont été retirées.") }
        return out + section.paragraphs.map(\.text).joined(separator: "\n\n") + "\n\n"
    }

    static func callout(_ kind: String, _ title: String, _ body: String) -> String {
        "> [!\(kind)] \(title)\n" + quoted(body) + "\n\n"
    }
    static func foldable(_ kind: String, _ title: String, _ body: String) -> String {
        "> [!\(kind)]- \(title)\n" + quoted(body) + "\n\n"
    }
    private static func quoted(_ body: String) -> String {
        body.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    }
    private static func yaml(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ") + "\""
    }
    private static func cell(_ value: String) -> String { value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }

    static func filename(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "[/\\\\:*?\"<>|#^\\[\\]]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return (cleaned.isEmpty ? "Cours" : String(cleaned.prefix(120))) + ".md"
    }
}

/// Remembers an Obsidian vault folder across launches with a security-scoped bookmark.
@MainActor
enum ObsidianVault {
    private static let bookmarkKey = "obsidianVaultBookmark"
    static var folder: URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) { UserDefaults.standard.set(fresh, forKey: bookmarkKey) }
        return url
    }
    static func choose() throws -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Choisir ce coffre"; panel.message = "Choisis le dossier de ton coffre Obsidian (ou un dossier à l’intérieur)."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(try url.bookmarkData(options: .withSecurityScope), forKey: bookmarkKey)
        return url
    }
    static func forget() { UserDefaults.standard.removeObject(forKey: bookmarkKey) }

    /// Writes the note into the vault when one is configured, otherwise asks where to save it.
    /// Returns the written file, or nil when the person cancelled.
    @discardableResult
    static func export(_ course: Course) async throws -> URL? {
        let defaults = UserDefaults.standard
        let text = ObsidianMarkdown.current(course)
        let name = ObsidianMarkdown.filename(course.title)
        if let vault = folder {
            let access = vault.startAccessingSecurityScopedResource(); defer { if access { vault.stopAccessingSecurityScopedResource() } }
            let subfolder = (defaults.string(forKey: "obsidianSubfolder") ?? "Cours").trimmed
                .split(separator: "/").map { ObsidianMarkdown.filename(String($0)).dropLast(3) }.filter { !$0.isEmpty }.joined(separator: "/")
            let directory = subfolder.isEmpty ? vault : vault.appendingPathComponent(subfolder, isDirectory: true)
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                let alert = NSAlert(); alert.messageText = "« \(name) » existe déjà dans le coffre"
                alert.informativeText = "Le remplacer effacera les modifications faites dans Obsidian sur cette note."
                alert.addButton(withTitle: "Remplacer"); alert.addButton(withTitle: "Annuler"); alert.alertStyle = .warning
                guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            }
            try await Task.detached {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }.value
            if defaults.object(forKey: "openInObsidian") as? Bool ?? true { open(url) }
            return url
        }
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.message = "Astuce : choisis ton coffre Obsidian dans les réglages pour exporter en un clic."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try await Task.detached { try text.write(to: url, atomically: true, encoding: .utf8) }.value
        return url
    }
    static func open(_ url: URL) {
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&+=?#")
        guard let path = url.path.addingPercentEncoding(withAllowedCharacters: allowed),
              let link = URL(string: "obsidian://open?path=\(path)") else { return }
        if NSWorkspace.shared.urlForApplication(toOpen: link) != nil { NSWorkspace.shared.open(link) }
    }
    static func copy(_ course: Course) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ObsidianMarkdown.current(course), forType: .string)
    }
}
