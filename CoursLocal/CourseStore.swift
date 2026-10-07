import Foundation
import Combine
import AVFoundation

// All metadata reads, mutations and atomic writes are serialized off the UI thread.
actor CourseRepository {
    let root: URL
    private var courses: [UUID: Course] = [:]
    init(root: URL) { self.root = root }
    func load() -> (courses: [Course], errors: [String]) {
        var errors: [String] = []
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                let metadata = folder.appendingPathComponent("course.json")
                guard FileManager.default.fileExists(atPath: metadata.path) else { continue }
                do {
                    let original = try Data(contentsOf: metadata)
                    var course = try JSONDecoder().decode(Course.self, from: original)
                    try course.validateStoredData()
                    guard course.formatVersion <= Course.currentFormat else { throw CourseError.message("Format de cours plus récent que cette application.") }
                    if course.formatVersion < Course.currentFormat {
                        // Earlier results stay in the file; the original bytes are also kept once per format.
                        let backup = folder.appendingPathComponent("course.v\(course.formatVersion).backup.json")
                        if !FileManager.default.fileExists(atPath: backup.path) { try original.write(to: backup, options: .atomic) }
                        course.formatVersion = Course.currentFormat
                    }
                    let manifest = folder.appendingPathComponent("recording-manifest.json")
                    if FileManager.default.fileExists(atPath: manifest.path) {
                        let parts = try JSONDecoder().decode([AudioPart].self, from: Data(contentsOf: manifest))
                        let known = Set(course.parts.map(\.id))
                        course.parts.append(contentsOf: parts.filter { !known.contains($0.id) })
                        course.state = .interrupted
                        course.status = "Enregistrement interrompu — vérifier l’audio"
                    }
                    if [.recording, .paused].contains(course.state) {
                        course.state = .interrupted; course.status = "Enregistrement interrompu — vérifier l’audio"
                    } else if course.state == .importing {
                        course.state = .importIncomplete; course.status = "Import incomplet — réimporter le fichier original"
                    } else if [.transcribing, .generating].contains(course.state) {
                        course.state = .interrupted; course.status = "Traitement interrompu — reprise disponible"
                    }
                    for index in course.parts.indices {
                        let url = folder.appendingPathComponent(course.parts[index].filename)
                        do {
                            guard url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { throw CourseError.message("Chemin audio invalide.") }
                            let audio = try AVAudioFile(forReading: url)
                            guard audio.length > 0, audio.processingFormat.sampleRate > 0 else { throw CourseError.message("Segment audio vide.") }
                            course.parts[index].duration = Double(audio.length) / audio.processingFormat.sampleRate
                            course.parts[index].problem = nil
                        } catch {
                            course.parts[index].problem = error.localizedDescription
                        }
                    }
                    try save(course)
                    courses[course.id] = course
                    // Remove only after recovery has been durably committed.
                    if FileManager.default.fileExists(atPath: manifest.path) { try FileManager.default.removeItem(at: manifest) }
                } catch { errors.append("Impossible de lire \(folder.lastPathComponent) : \(error.localizedDescription). Les fichiers sont conservés.") }
            }
        } catch { errors.append(error.localizedDescription) }
        return (Array(courses.values), errors)
    }
    func create(title: String) throws -> Course {
        let course = Course(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Cours du \(Date().formatted(date: .abbreviated, time: .shortened))" : title)
        try FileManager.default.createDirectory(at: folder(course.id), withIntermediateDirectories: true)
        try save(course); courses[course.id] = course; return course
    }
    func update(_ id: UUID, _ mutation: @Sendable (inout Course) -> Void) throws -> Course {
        guard var course = courses[id] else { throw CourseError.message("Cours introuvable.") }
        mutation(&course); try save(course); courses[id] = course; return course
    }
    func delete(_ id: UUID) throws {
        guard courses[id] != nil else { throw CourseError.message("Cours introuvable.") }
        try FileManager.default.removeItem(at: folder(id)); courses[id] = nil
    }
    func validateAudio(_ id: UUID) throws -> Course {
        guard var course = courses[id] else { throw CourseError.message("Cours introuvable.") }
        for i in course.parts.indices where course.parts[i].excluded != true {
            do {
                let url = folder(id).appendingPathComponent(course.parts[i].filename)
                guard url.deletingLastPathComponent().standardizedFileURL == folder(id).standardizedFileURL else { throw CourseError.message("Chemin audio invalide.") }
                let audio = try AVAudioFile(forReading: url)
                guard audio.length > 0 else { throw CourseError.message("Segment audio vide.") }
                course.parts[i].duration = Double(audio.length) / audio.processingFormat.sampleRate; course.parts[i].problem = nil
            } catch { course.parts[i].problem = error.localizedDescription }
        }
        try save(course); courses[id] = course; return course
    }
    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func save(_ course: Course) throws {
        try course.validateStoredData()
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(course).write(to: folder(course.id).appendingPathComponent("course.json"), options: .atomic)
    }
}

@MainActor
final class CourseStore: ObservableObject {
    @Published private(set) var courses: [Course] = []
    @Published private(set) var ready = false
    @Published var error: String?
    let root: URL
    let gate: OperationGate
    private let repository: CourseRepository
    init(root: URL? = nil, gate: OperationGate? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CoursLocal", isDirectory: true)
        self.gate = gate ?? OperationGate(); repository = CourseRepository(root: self.root)
        Task {
            let result = await repository.load(); courses = result.courses.sorted { $0.createdAt > $1.createdAt }
            error = result.errors.isEmpty ? nil : result.errors.joined(separator: "\n"); ready = true
        }
    }
    func course(_ id: UUID) -> Course? { courses.first { $0.id == id } }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    @discardableResult func create(title: String) async throws -> UUID {
        guard ready else { throw CourseError.message("La bibliothèque est en cours de chargement.") }
        let course = try await repository.create(title: title); publish(course); return course.id
    }
    func update(_ id: UUID, _ mutation: @escaping @Sendable (inout Course) -> Void) async throws {
        publish(try await repository.update(id, mutation))
    }
    func validateAudio(_ id: UUID) async throws -> Course {
        let course = try await repository.validateAudio(id); publish(course); return course
    }
    func delete(_ id: UUID) async throws {
        guard !gate.busy else { throw CourseError.message("Attends la fin de l’opération avant de supprimer un cours.") }
        try gate.acquire("Suppression"); defer { gate.release() }
        try await repository.delete(id); courses.removeAll { $0.id == id }
    }
    func editPassage(courseID: UUID, passageID: UUID, text: String) async throws {
        guard !gate.busy else { throw CourseError.message("Attends la fin du traitement avant de corriger la transcription.") }
        try gate.acquire("Correction"); defer { gate.release() }
        try await update(courseID) { course in
            for p in course.parts.indices {
                if let i = course.parts[p].passages?.firstIndex(where: { $0.id == passageID }), course.parts[p].passages?[i].text != text {
                    course.parts[p].passages?[i].text = text
                    course.transcriptRevision += 1; course.resultsObsolete = true
                }
            }
        }
    }
    /// Replaces a displayed section (possibly merged from several stored ones) with the edited text.
    /// Paragraphs are separated by blank lines; their audio references survive when the count is unchanged.
    func editSection(courseID: UUID, sectionIDs: [UUID], title: String, theme: String, text: String) async throws {
        guard !gate.busy else { throw CourseError.message("Attends la fin du traitement avant de modifier le document.") }
        let title = ThemeName.sanitize(title), theme = ThemeName.sanitize(theme)
        guard !title.isEmpty, !theme.isEmpty else { throw CourseError.message("Le titre et le thème ne peuvent pas être vides.") }
        let texts = text.components(separatedBy: "\n").split(whereSeparator: { $0.trimmed.isEmpty }).map { $0.joined(separator: " ").trimmed }
        try gate.acquire("Édition"); defer { gate.release() }
        try await update(courseID) { course in
            let old = course.cleanBlocks.flatMap { $0.result?.sections ?? [] }.filter { sectionIDs.contains($0.id) }.flatMap(\.paragraphs)
            var seen = Set<UUID>(); let all = old.flatMap(\.references).filter { seen.insert($0).inserted }
            let paragraphs = texts.enumerated().map { i, text in
                CleanParagraph(text: text, references: texts.count == old.count ? old[i].references : all)
            }
            // A theme typed by hand is already the final name: map it to itself.
            if course.themeIndex != nil, course.themeIndex?.aliases[theme] == nil { course.themeIndex?.aliases[theme] = theme }
            for b in course.cleanBlocks.indices {
                guard var sections = course.cleanBlocks[b].result?.sections else { continue }
                for i in sections.indices where sections[i].id == sectionIDs.first {
                    sections[i].title = title; sections[i].theme = theme; sections[i].paragraphs = paragraphs; sections[i].edited = true; sections[i].fallback = nil
                }
                sections.removeAll { sectionIDs.dropFirst().contains($0.id) || ($0.id == sectionIDs.first && paragraphs.isEmpty) }
                course.cleanBlocks[b].result?.sections = sections
            }
        }
    }
    func renameTheme(courseID: UUID, from old: String, to new: String) async throws {
        guard !gate.busy else { throw CourseError.message("Une opération est déjà en cours.") }
        let name = ThemeName.sanitize(new)
        guard !name.isEmpty else { throw CourseError.message("Le nom du thème ne peut pas être vide.") }
        try gate.acquire("Édition"); defer { gate.release() }
        try await update(courseID) { course in
            var index = course.themeIndex ?? ThemeIndex()
            for raw in Set(course.cleanBlocks.flatMap { $0.result?.sections ?? [] }.map(\.theme)) where index.canonical(raw) == old { index.aliases[raw] = name }
            index.aliases[name] = name
            course.themeIndex = index
            for i in course.sheet?.themes.indices ?? 0..<0 where course.sheet?.themes[i].theme == old { course.sheet?.themes[i].theme = name }
        }
    }
    func excludeDamagedParts(_ id: UUID) async throws {
        guard !gate.busy else { throw CourseError.message("Une opération est déjà en cours.") }
        try gate.acquire("Récupération"); defer { gate.release() }
        try await update(id) { c in
            for i in c.parts.indices where c.parts[i].problem != nil { c.parts[i].excluded = true }
            c.transcriptRevision += 1; c.resultsObsolete = true
            c.status = "Audio incomplet — portions illisibles exclues"
        }
    }
    private func publish(_ course: Course) {
        if let index = courses.firstIndex(where: { $0.id == course.id }) { courses[index] = course }
        else { courses.insert(course, at: 0) }
    }
}
