import Foundation
import Combine
import AVFoundation

enum PipelinePhase: Int, CaseIterable, Sendable {
    case checking, transcribing, cleaning, sheet
    var label: String {
        switch self { case .checking: return "Vérification"; case .transcribing: return "Transcription"; case .cleaning: return "Nettoyage"; case .sheet: return "Fiche" }
    }
    var symbol: String {
        switch self { case .checking: return "checkmark.shield"; case .transcribing: return "waveform"; case .cleaning: return "wand.and.stars"; case .sheet: return "list.bullet.rectangle" }
    }
}

@MainActor
final class Pipeline: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var courseID: UUID?
    @Published private(set) var progress = ""
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var phase: PipelinePhase?
    private var task: Task<Void, Never>?
    private let store: CourseStore
    private let transcriber: any CourseTranscribing
    private let client: RapidMLXClient
    private var exporter: AVAssetExportSession?
    init(store: CourseStore, client: RapidMLXClient = RapidMLXClient(), transcriber: any CourseTranscribing = Transcriber()) { self.store = store; self.client = client; self.transcriber = transcriber }
    func process(id: UUID, settings: AISettings, regenerate: Bool = false, retryFallbacks: Bool = false, regenerateSheet: Bool = false) {
        do {
            guard !settings.model.isEmpty else { throw CourseError.message("Choisis un modèle (\(settings.provider.name)) dans CoursLocal → Réglages → IA avant de nettoyer la transcription.") }
            _ = try settings.endpoint()
            try store.gate.acquire("Traitement")
        } catch { store.error = error.localizedDescription; return }
        busy = true; courseID = id; completed = 0; total = 0
        task = Task {
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Traitement local du cours")
            defer { ProcessInfo.processInfo.endActivity(activity); busy = false; courseID = nil; task = nil; phase = nil; store.gate.release() }
            do {
                try await run(id: id, settings: settings, regenerate: regenerate, retryFallbacks: retryFallbacks, regenerateSheet: regenerateSheet)
                try Task.checkCancellation()
                let simplified = store.course(id)?.documentSections.contains(where: \.fallback) == true
                try await store.update(id) { $0.state = .ready; $0.status = simplified ? "Document prêt — passages simplifiés" : "Document prêt"; $0.lastError = nil; $0.resultsObsolete = false }
                progress = "Terminé"
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                progress = cancelled ? "Traitement interrompu — reprise disponible" : "Échec — reprise disponible"
                let status = progress; let message = cancelled ? nil : error.localizedDescription
                try? await store.update(id) { $0.state = cancelled ? .interrupted : .failed; $0.status = status; $0.lastError = message }
                if let message { store.error = message }
            }
            await transcriber.release()
        }
    }
    func cancel() { progress = "Arrêt demandé…"; task?.cancel(); exporter?.cancelExport() }
    private func checkpoint(_ id: UUID, _ text: String, state: CourseState, completed: Int, total: Int) async throws {
        progress = text; self.completed = completed; self.total = total
        try await store.update(id) { $0.state = state; $0.status = text }
    }
    private func run(id: UUID, settings: AISettings, regenerate: Bool, retryFallbacks: Bool, regenerateSheet: Bool) async throws {
        phase = .checking; progress = "Vérification de \(settings.provider.name) et de l’audio"
        try await client.checkModel(settings: settings)
        let initial = try await store.validateAudio(id)
        guard initial.state != .importIncomplete, !initial.parts.isEmpty else { throw CourseError.message("Ce cours n’a pas d’import audio complet.") }
        guard !initial.parts.contains(where: { $0.problem != nil && $0.excluded != true }) else { throw CourseError.message("Certains segments sont illisibles. Vérifie l’audio et utilise « Traiter les portions valides » pour accepter explicitement un cours incomplet.") }
        let desired = settings.configuration(revision: initial.transcriptRevision)
        let hasResults = initial.hasDocument || initial.themeIndex != nil
        if hasResults && (initial.resultsObsolete || initial.configuration != desired) && !regenerate {
            throw CourseError.message("Les sources ou les réglages ont changé. Utilise « Régénérer » pour remplacer le document et ses modifications.")
        }
        let transcriptionChanged = (initial.whisperModel != nil && initial.whisperModel != settings.whisperModel) || (initial.language != nil && initial.language != settings.language)
        try await store.update(id) { c in
            if transcriptionChanged { for i in c.parts.indices { c.parts[i].passages = nil } }
            // Earlier notes, cards and summaries are never touched: only the cleaned document is rebuilt.
            if regenerate || c.configuration != desired { c.cleanBlocks = []; c.themeIndex = nil; c.sheet = nil }
            if regenerateSheet { c.sheet = nil }
            // Only simplified, unedited passages are sent again.
            if retryFallbacks {
                for i in c.cleanBlocks.indices where c.cleanBlocks[i].result?.sections.contains(where: { $0.fallback == true }) == true {
                    c.cleanBlocks[i].result = nil; c.themeIndex = nil; c.sheet = nil
                }
            }
            c.configuration = desired; c.whisperModel = settings.whisperModel; c.language = settings.language; c.studyModel = settings.model
        }
        phase = .transcribing
        for index in initial.parts.indices {
            try Task.checkCancellation()
            guard let part = store.course(id)?.parts[index] else { throw CourseError.message("Cours introuvable.") }
            if part.excluded == true || part.passages != nil { continue }
            try await checkpoint(id, "Transcription \(index + 1)/\(initial.parts.count)", state: .transcribing, completed: index, total: initial.parts.count)
            let passages = try await transcriber.transcribe(store.folder(id).appendingPathComponent(part.filename), model: settings.whisperModel, language: settings.language)
            try Task.checkCancellation()
            try await store.update(id) { $0.parts[index].passages = passages }
        }
        await transcriber.release()
        guard let course = store.course(id), !course.sources.isEmpty else { throw CourseError.message("Aucune parole détectée. Vérifie les sources audio.") }
        if course.cleanBlocks.isEmpty {
            let blocks = TextChunks.cleaningBlocks(course.sources)
            guard !blocks.isEmpty else { throw CourseError.message("La transcription ne contient que des hésitations ou des annotations.") }
            try await store.update(id) { $0.cleanBlocks = blocks }
        }
        phase = .cleaning
        let count = store.course(id)?.cleanBlocks.count ?? 0
        for index in 0..<count {
            try Task.checkCancellation()
            guard let course = store.course(id), index < course.cleanBlocks.count else { throw CourseError.message("Partie de cours introuvable.") }
            let block = course.cleanBlocks[index]
            if block.result != nil { continue }
            try await checkpoint(id, "Nettoyage \(index + 1)/\(count)", state: .generating, completed: index, total: count)
            let result: CleanResult
            do { result = try await client.clean(settings: settings, block: block) }
            catch where CourseError.isModelOutput(error) && !Task.isCancelled {
                // Never lose a passage because the model failed on it: keep the filtered text, flagged for review.
                result = FillerFilter.fallback(block, reason: error.localizedDescription)
            }
            try Task.checkCancellation()
            try await store.update(id) { $0.cleanBlocks[index].result = result }
        }
        if store.course(id)?.themeIndex == nil {
            // Only documents partly cleaned before version 0.4 still have themes to harmonize.
            var counts: [(name: String, count: Int)] = []
            for section in store.course(id)?.cleanBlocks.flatMap({ $0.result?.sections ?? [] }) ?? [] where !section.theme.isEmpty {
                if let i = counts.firstIndex(where: { $0.name == section.theme }) { counts[i].count += 1 } else { counts.append((section.theme, 1)) }
            }
            let index = counts.isEmpty ? ThemeIndex() : try await client.harmonize(settings: settings, themes: counts)
            try Task.checkCancellation()
            try await store.update(id) { $0.themeIndex = index; $0.sheet = nil }
        }
        if settings.generateSheet, store.course(id)?.sheetComplete != true {
            phase = .sheet
            guard let course = store.course(id) else { throw CourseError.message("Cours introuvable.") }
            let sources = SheetSources.chunks(course.documentSections, maxCharacters: client.sheetSourceLimit(settings))
            guard !sources.isEmpty else { throw CourseError.message("Le texte nettoyé est vide : rien à résumer.") }
            // The written parts only fit together if the text is cut the same way: otherwise the sheet starts again.
            if course.sheet?.sourceCount != sources.count { try await store.update(id) { $0.sheet = CourseSheet(sourceCount: sources.count) } }
            for (index, source) in sources.enumerated() {
                try Task.checkCancellation()
                guard let current = store.course(id), let sheet = current.sheet else { throw CourseError.message("Cours introuvable.") }
                if index < sheet.parts.count { continue }
                try await checkpoint(id, sources.count == 1 ? "Rédaction de la fiche" : "Fiche \(index + 1)/\(sources.count)", state: .generating, completed: index, total: sources.count)
                let part = try await client.sheetPart(settings: settings, courseTitle: current.title, source: source, written: sheet.markdown)
                try Task.checkCancellation()
                try await store.update(id) { $0.sheet?.parts.append(part) }
            }
        }
        completed = 1; total = 1
    }
    func importAudio(_ url: URL, title: String, settings: AISettings? = nil) {
        do { try store.gate.acquire("Import") } catch { store.error = error.localizedDescription; return }
        busy = true; progress = "Import audio"; completed = 0; total = 0
        task = Task {
            var importedID: UUID?
            do {
                importedID = try await performImport(url, title: title)
            } catch { if !Task.isCancelled { store.error = error.localizedDescription } }
            busy = false; courseID = nil; task = nil; exporter = nil; store.gate.release()
            if !Task.isCancelled, let importedID, let settings, UserDefaults.standard.object(forKey: "autoProcess") as? Bool ?? true { process(id: importedID, settings: settings) }
        }
    }
    private func performImport(_ url: URL, title: String) async throws -> UUID {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Import audio")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url); let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CourseError.message("Fichier audio vide ou illisible.") }
        try Task.checkCancellation()
        let id = try await store.create(title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title); courseID = id
        do {
            try await store.update(id) { $0.state = .importing; $0.status = "Import en cours" }
            let count = Int(ceil(duration / 300)); total = count
            for index in 0..<count {
                try Task.checkCancellation(); completed = index; progress = "Import audio \(index + 1)/\(count)"
                guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw CourseError.message("Format audio incompatible.") }
                self.exporter = exporter
                let start = Double(index) * 300; let length = min(300, duration - start)
                let part = AudioPart(filename: "\(UUID().uuidString).m4a", duration: length)
                exporter.outputURL = store.folder(id).appendingPathComponent(part.filename); exporter.outputFileType = .m4a
                exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in exporter.exportAsynchronously { c.resume() } }
                } onCancel: { exporter.cancelExport() }
                try Task.checkCancellation()
                guard exporter.status == .completed else { throw exporter.error ?? CourseError.message("Import audio échoué.") }
                try await store.update(id) { $0.parts.append(part) }
            }
            try await store.update(id) { $0.state = .audioReady; $0.status = "Audio importé" }; completed = count; progress = "Import terminé"; return id
        } catch {
            let message = error.localizedDescription
            try? await store.update(id) { $0.state = .importIncomplete; $0.status = "Import incomplet — réimporter le fichier original"; $0.lastError = message }
            throw error
        }
    }
}
