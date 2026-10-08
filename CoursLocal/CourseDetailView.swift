import SwiftUI
import AppKit

enum ProcessMode { case normal, regenerate, retryFallbacks, regenerateSheet }

enum CourseTab: String, CaseIterable, Identifiable {
    case sheet = "Fiche", document = "Texte nettoyé", transcript = "Transcription", markdown = "Markdown", archive = "Archives"
    var id: String { rawValue }
}

private enum CourseModal: Identifiable {
    case rename, passage(SourcePassage), section(DocumentSection), theme(String)
    var id: String {
        switch self {
        case .rename: return "rename"; case .passage(let p): return "p" + p.id.uuidString
        case .section(let s): return "s" + s.id.uuidString; case .theme(let name): return "t" + name
        }
    }
}

@MainActor
struct CourseView: View {
    let course: Course
    @ObservedObject var store: CourseStore
    @ObservedObject var player: CourseAudioPlayer
    @ObservedObject var gate: OperationGate
    let assistant: CourseAssistant
    let process: (ProcessMode) -> Void
    let reimport: () -> Void
    var delete: () -> Void = {}
    @AppStorage("documentLayout") private var layout: DocumentLayout = .themes
    @AppStorage("exportTranscript") private var exportTranscript = true
    @AppStorage("showOutline") private var showOutline = true
    @AppStorage("generateSheet") private var generateSheet = true
    @AppStorage("exportCleanText") private var exportCleanText = true
    @AppStorage("showChat") private var showChat = false
    @State private var tab: CourseTab
    @State private var sheet: CourseModal?
    @State private var showRegenerate = false
    @State private var showRecovery = false
    @State private var transcriptFilter = ""
    @State private var scrollTarget: String?
    @State private var toast: String?
    @State private var columnWidth: CGFloat = 1000

    init(course: Course, store: CourseStore, player: CourseAudioPlayer, gate: OperationGate, assistant: CourseAssistant, process: @escaping (ProcessMode) -> Void, reimport: @escaping () -> Void, delete: @escaping () -> Void = {}) {
        self.course = course; self.store = store; self.player = player; self.gate = gate; self.assistant = assistant
        self.process = process; self.reimport = reimport; self.delete = delete
        _tab = State(initialValue: course.hasSheet ? .sheet : course.hasDocument || course.sources.isEmpty ? .document : .transcript)
    }

    private var canProcess: Bool { !gate.busy && !course.parts.isEmpty && course.state != .importIncomplete }
    private var captureActive: Bool { gate.operation == "Enregistrement" }
    private var processingThis: Bool { [.transcribing, .generating].contains(course.state) && gate.busy }
    private var groups: [ThemeGroup] { course.themeGroups }
    /// Documents cleaned without themes are read in the order of the course.
    private var effectiveLayout: DocumentLayout { course.themed ? layout : .chronological }
    private var tabs: [CourseTab] { CourseTab.allCases.filter { $0 != .archive || course.legacyMarkdown != nil } }
    /// Narrow column (small window, questions or outline panel open): header and controls stack vertically.
    private var compact: Bool { columnWidth < 680 }
    private var needsSheet: Bool { generateSheet && course.documentComplete && !course.sheetComplete }
    private var needsProcessing: Bool { !course.documentComplete || course.state == .failed || course.state == .interrupted || needsSheet }
    private var processLabel: String {
        if needsSheet && course.state != .failed && course.state != .interrupted { return course.sheet == nil ? "Créer la fiche de cours" : "Terminer la fiche" }
        return course.hasDocument || course.parts.contains { $0.passages != nil } ? "Reprendre" : "Nettoyer et structurer"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            header
                            notices
                            tabBar
                            content
                        }
                        .padding(.horizontal, compact ? 22 : 36).padding(.top, compact ? 20 : 28).padding(.bottom, 48)
                        .frame(maxWidth: 860, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation(.smooth) { proxy.scrollTo(target, anchor: .top) }
                        scrollTarget = nil
                    }
                }
                if showChat {
                    Divider()
                    ChatPanel(course: course, assistant: assistant) { showChat = false }
                        .frame(width: 340)
                        .transition(.move(edge: .trailing))
                } else if tab == .document && course.hasDocument && showOutline {
                    Divider()
                    OutlineColumn(course: course, groups: groups, layout: effectiveLayout, fixes: course.transcriptFixes.count) { scrollTarget = $0 }
                        .frame(width: 250)
                        .transition(.move(edge: .trailing))
                } else if tab == .sheet, course.hasSheet, showOutline {
                    Divider()
                    SheetOutline(blocks: sheetBlocks) { scrollTarget = $0 }
                        .frame(width: 250)
                        .transition(.move(edge: .trailing))
                }
            }
            if course.duration > 0 {
                PlayerBar(course: course, player: player, folder: store.folder(course.id), disabled: captureActive) { store.error = $0 }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast { Toast(text: toast).padding(.bottom, 64).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(.smooth(duration: 0.2), value: showOutline)
        .animation(.smooth(duration: 0.2), value: showChat)
        .animation(.smooth(duration: 0.25), value: toast)
        .onAppear { player.configure(course, folder: store.folder(course.id)) }
        .onChange(of: course.duration) { _, _ in player.configure(course, folder: store.folder(course.id)) }
        .onChange(of: course.parts.map { $0.problem }) { _, _ in player.configure(course, folder: store.folder(course.id)) }
        .onChange(of: course.parts.map { $0.excluded }) { _, _ in player.configure(course, folder: store.folder(course.id)) }
        .onChange(of: course.hasDocument) { _, has in if has && tab != .sheet { tab = .document } }
        .onChange(of: course.sheetComplete) { _, complete in if complete { tab = .sheet } }
        .onChange(of: course.sources.isEmpty) { _, empty in if !empty && !course.hasDocument { tab = .transcript } }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "courslocal", url.host == "time", let seconds = Double(url.lastPathComponent) { listen(seconds); return .handled }
            return .systemAction
        })
        .confirmationDialog("Régénérer le document ?", isPresented: $showRegenerate) {
            Button("Régénérer", role: .destructive) { process(.regenerate) }
        } message: { Text("Le document nettoyé et tes modifications seront remplacés avec les réglages actuels. Un changement de modèle Whisper ou de langue remplace aussi les corrections de transcription. Les anciens résultats (notes, fiches) sont conservés.") }
        .confirmationDialog("Exclure les segments illisibles ?", isPresented: $showRecovery) {
            Button("Accepter un cours incomplet") { Task { do { try await store.excludeDamagedParts(course.id) } catch { store.error = error.localizedDescription } } }
        } message: { Text("Les fichiers sont conservés et l’export indiquera que le cours est incomplet.") }
        .sheet(item: $sheet) { sheet in sheetView(sheet) }
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        if compact {
            VStack(alignment: .leading, spacing: 14) { headerInfo; headerActions }
        } else {
            HStack(alignment: .top, spacing: 16) { headerInfo; Spacer(minLength: 16); headerActions }
        }
    }

    private var headerInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StateBadge(state: course.state)
                Text(course.createdAt.formatted(date: .complete, time: .shortened)).font(.callout).foregroundStyle(.secondary)
            }
            Text(course.title).font(.system(size: 30, weight: .bold)).textSelection(.enabled).lineLimit(3)
                .onTapGesture(count: 2) { if !gate.busy { sheet = .rename } }
                .help("Double-clique pour renommer")
            FlowLayout(spacing: 16, lineSpacing: 6) {
                MetaLabel(symbol: "clock", text: shortDuration(course.duration))
                MetaLabel(symbol: course.captureMode.symbol, text: course.applicationName.map { "\(course.captureMode.label) · \($0)" } ?? course.captureMode.label)
                if course.hasDocument {
                    if course.themed { MetaLabel(symbol: "square.stack.3d.up", text: groups.count == 1 ? "1 thème" : "\(groups.count) thèmes") }
                    MetaLabel(symbol: "text.alignleft", text: "\(course.wordCount.formatted()) mots")
                }
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            if needsProcessing {
                Button { process(.normal) } label: {
                    Label(processLabel, systemImage: needsSheet && course.documentComplete ? "list.bullet.rectangle" : "wand.and.stars")
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!canProcess)
            } else {
                Button(action: export) { Label("Exporter vers Obsidian", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            if needsProcessing { Button(action: export) { Label("Exporter vers Obsidian", systemImage: "square.and.arrow.up") } }
            Button(action: copyMarkdown) { Label("Copier le Markdown", systemImage: "doc.on.doc") }
            Divider()
            if course.hasDocument { Button { showRegenerate = true } label: { Label("Régénérer le document…", systemImage: "arrow.triangle.2.circlepath") }.disabled(!canProcess) }
            if course.sheet != nil { Button { process(.regenerateSheet) } label: { Label("Régénérer la fiche", systemImage: "list.bullet.rectangle") }.disabled(!canProcess) }
            Button { sheet = .rename } label: { Label("Renommer…", systemImage: "pencil") }.disabled(gate.busy)
            Button { NSWorkspace.shared.open(store.folder(course.id)) } label: { Label("Afficher les fichiers audio", systemImage: "folder") }
            Divider()
            Button(role: .destructive, action: delete) { Label("Supprimer le cours…", systemImage: "trash") }.disabled(gate.busy)
        } label: { Image(systemName: "ellipsis.circle").font(.title2) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Plus d’actions")
    }

    // MARK: Notices

    @ViewBuilder private var notices: some View {
        let fallbacks = course.documentSections.filter(\.fallback).count
        VStack(spacing: 8) {
            if course.state == .importIncomplete {
                NoticeView(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Import incomplet", message: course.lastError) {
                    Button("Réimporter le fichier original", action: reimport).disabled(gate.busy)
                }
            } else if let error = course.lastError, [.failed, .interrupted].contains(course.state) {
                NoticeView(symbol: "exclamationmark.octagon.fill", tint: .red, title: "Le traitement s’est arrêté", message: error + " Les étapes terminées sont conservées.") {
                    Button("Reprendre") { process(.normal) }.disabled(!canProcess)
                }
            } else if course.state == .interrupted && !processingThis {
                NoticeView(symbol: "pause.circle.fill", tint: .orange, title: "Traitement interrompu", message: course.status) {
                    Button("Reprendre") { process(.normal) }.disabled(!canProcess)
                }
            }
            if course.parts.contains(where: { $0.problem != nil && $0.excluded != true }) {
                NoticeView(symbol: "waveform.slash", tint: .orange, title: "Segments audio illisibles", message: "Vérifie les fichiers audio, ou continue avec les portions valides.") {
                    Button("Traiter les portions valides") { showRecovery = true }.disabled(gate.busy)
                }
            }
            if course.resultsObsolete && course.hasDocument {
                NoticeView(symbol: "arrow.triangle.2.circlepath", tint: .orange, title: "Document obsolète", message: "La transcription a été corrigée depuis la génération du document.") {
                    Button("Régénérer…") { showRegenerate = true }.disabled(!canProcess)
                }
            }
            if course.incomplete {
                NoticeView(symbol: "exclamationmark.triangle", tint: .orange, title: "Cours incomplet", message: "Certaines portions audio sont indisponibles ou exclues.")
            }
            if fallbacks > 0 && tab == .document {
                let reason = course.documentSections.compactMap(\.fallbackReason).first
                NoticeView(symbol: "wand.and.rays", tint: .yellow, title: fallbacks == 1 ? "1 passage simplifié" : "\(fallbacks) passages simplifiés",
                           message: "Le modèle n’a pas pu les structurer : seules les hésitations évidentes ont été retirées." + (reason.map { " Cause : \($0)" } ?? "")) {
                    Button("Réessayer") { process(.retryFallbacks) }.disabled(!canProcess).help("Renvoie seulement ces passages au modèle")
                }
            }
        }
    }

    // MARK: Tabs

    /// Everything on one line when it fits; otherwise the tab-specific controls wrap below,
    /// and in a very narrow column the segmented control becomes a menu.
    private var tabBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { tabPicker.pickerStyle(.segmented); Spacer(minLength: 12); tabTools; chatButton }
            tabBarStack(tabPicker.pickerStyle(.segmented))
            tabBarStack(tabPicker.pickerStyle(.menu))
        }
    }

    private func tabBarStack(_ picker: some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) { picker; Spacer(minLength: 12); chatButton }
            if hasTabTools { FlowLayout(spacing: 12, lineSpacing: 8) { tabTools } }
        }
    }

    private var tabPicker: some View {
        Picker("Vue", selection: $tab) { ForEach(tabs) { Text($0.rawValue).tag($0) } }
            .labelsHidden().fixedSize()
    }

    private var chatButton: some View {
        Button { showChat.toggle() } label: { Image(systemName: "bubble.left.and.text.bubble.right").symbolVariant(showChat ? .fill : .none) }
            .buttonStyle(.borderless).help(showChat ? "Fermer les questions" : "Poser une question sur le cours")
    }

    private var hasTabTools: Bool {
        switch tab {
        case .document: return course.hasDocument
        case .transcript: return !course.sources.isEmpty
        case .sheet: return course.sheet != nil
        case .markdown: return true
        case .archive: return false
        }
    }

    @ViewBuilder private var tabTools: some View {
        switch tab {
        case .document where course.hasDocument:
            if course.themed {
                Picker("Organisation", selection: $layout) { ForEach(DocumentLayout.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.menu).labelsHidden().fixedSize().help("Organisation du document et de l’export")
            }
            Button { showOutline.toggle() } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.borderless).help(showOutline ? "Masquer le plan" : "Afficher le plan")
        case .transcript where !course.sources.isEmpty:
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filtrer la transcription", text: $transcriptFilter).textFieldStyle(.plain)
                if !transcriptFilter.isEmpty { Button { transcriptFilter = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5).frame(width: 240)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
        case .sheet where course.sheet != nil:
            if course.hasSheet {
                Button { showOutline.toggle() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(.borderless).help(showOutline ? "Masquer le plan" : "Afficher le plan")
            }
            Button { process(.regenerateSheet) } label: { Label("Régénérer la fiche", systemImage: "arrow.triangle.2.circlepath") }
                .disabled(!canProcess).help("Recrée la fiche à partir du texte nettoyé actuel, y compris tes corrections")
        case .markdown:
            if course.sheet != nil { Toggle("Texte nettoyé", isOn: $exportCleanText).toggleStyle(.checkbox).help("Inclure le texte nettoyé sous la fiche") }
            Toggle("Transcription brute", isOn: $exportTranscript).toggleStyle(.checkbox).help("Inclure la transcription brute dans un bloc repliable")
            Button(action: copyMarkdown) { Label("Copier", systemImage: "doc.on.doc") }
            Button(action: export) { Label("Exporter", systemImage: "square.and.arrow.up") }
        default: EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .sheet: sheetTab
        case .document: documentTab
        case .transcript: transcriptTab
        case .markdown: markdownTab
        case .archive: archiveTab
        }
    }

    // MARK: Sheet

    private var sheetBlocks: [MarkdownBlock] { MarkdownBlock.parse(course.sheet?.markdown ?? "") }

    @ViewBuilder private var sheetTab: some View {
        if let sheet = course.sheet, course.hasSheet {
            if !sheet.complete && !processingThis {
                NoticeView(symbol: "list.bullet.rectangle", tint: .orange, title: "Fiche incomplète", message: "La fin du cours n’a pas encore été résumée.") {
                    Button("Terminer la fiche") { process(.normal) }.disabled(!canProcess)
                }
            }
            SheetMarkdownView(blocks: sheetBlocks)
        } else {
            EmptyStateView(symbol: processingThis ? "hourglass" : "list.bullet.rectangle",
                           title: processingThis ? "Traitement en cours…" : "Pas encore de fiche de cours",
                           message: !generateSheet ? "La fiche de cours est désactivée dans Réglages → Général."
                               : course.documentComplete ? "L’IA résume le texte nettoyé en petits paragraphes et organise elle-même le cours : titres, parties et forme adaptés à son contenu."
                               : "La fiche sera créée après le nettoyage du texte.") {
                if !processingThis && generateSheet && course.documentComplete {
                    Button { process(.normal) } label: { Label("Créer la fiche de cours", systemImage: "list.bullet.rectangle") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!canProcess)
                }
            }
        }
    }

    // MARK: Document

    @ViewBuilder private var documentTab: some View {
        if !course.hasDocument {
            EmptyStateView(symbol: processingThis ? "hourglass" : "wand.and.stars",
                           title: processingThis ? "Traitement en cours…" : "Aucun document pour l’instant",
                           message: course.parts.isEmpty
                               ? "Ce cours ne contient pas encore d’audio."
                               : "CoursLocal va transcrire l’audio, retirer les tics de langage, corriger les erreurs de transcription et réécrire le texte proprement, en paragraphes, sans le restructurer.") {
                if !processingThis && !course.parts.isEmpty {
                    Button { process(.normal) } label: { Label("Nettoyer le texte", systemImage: "wand.and.stars") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!canProcess)
                }
            }
        } else {
            let colors = Dictionary(groups.enumerated().map { ($0.element.name, ThemePalette.color($0.offset)) }, uniquingKeysWith: { a, _ in a })
            VStack(alignment: .leading, spacing: 34) {
                switch effectiveLayout {
                case .themes:
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 18) {
                            themeHeader(group, color: colors[group.name] ?? .accentColor)
                            VStack(alignment: .leading, spacing: 26) {
                                ForEach(group.sections) { section in sectionView(section, color: colors[section.theme] ?? .accentColor, showTheme: false) }
                            }
                            .padding(.leading, 16)
                            .overlay(alignment: .leading) { Rectangle().fill((colors[group.name] ?? .accentColor).opacity(0.25)).frame(width: 2) }
                        }.id("theme:" + group.name)
                    }
                case .chronological:
                    ForEach(course.documentSections) { section in sectionView(section, color: colors[section.theme] ?? .accentColor, showTheme: true) }
                }
                if !course.transcriptFixes.isEmpty { FixesView(fixes: course.transcriptFixes).id("fixes") }
            }
        }
    }

    private func themeHeader(_ group: ThemeGroup, color: Color) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 5, height: 24)
            Text(group.name).font(.system(size: 22, weight: .bold))
            Text(group.sections.count == 1 ? "1 section" : "\(group.sections.count) sections")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(.quaternary.opacity(0.6)))
            Spacer()
            Button { sheet = .theme(group.name) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Renommer le thème").disabled(gate.busy)
        }
        .contextMenu { Button("Renommer le thème…") { sheet = .theme(group.name) }.disabled(gate.busy) }
    }

    private func sectionView(_ section: DocumentSection, color: Color, showTheme: Bool) -> some View {
        let active = player.currentCourseID == course.id && player.playing && (section.start ?? .infinity) <= player.position && player.position <= (section.end ?? -1)
        return SectionView(section: section, color: color, showTheme: showTheme && !section.theme.isEmpty, active: active, editable: !gate.busy, canPlay: !captureActive,
                           play: listen, edit: { sheet = .section(section) })
            .id("section:" + section.id.uuidString)
    }

    // MARK: Transcript

    @ViewBuilder private var transcriptTab: some View {
        if course.sources.isEmpty {
            EmptyStateView(symbol: "text.bubble", title: "Pas encore de transcription",
                           message: course.parts.isEmpty ? "Ce cours ne contient pas encore d’audio." : "La transcription Whisper apparaîtra ici, horodatée et cliquable.") { EmptyView() }
        } else {
            let query = transcriptFilter.trimmed
            let passages = course.sources.filter { query.isEmpty || $0.text.localizedStandardContains(query) }
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(passages) { passage in
                    TranscriptRow(passage: passage,
                                  active: player.currentCourseID == course.id && player.playing && passage.start <= player.position && player.position < passage.end,
                                  canPlay: !captureActive, editable: !gate.busy,
                                  play: { listen(passage.start) }, edit: { sheet = .passage(passage) })
                }
                if passages.isEmpty { Text("Aucun passage ne contient « \(query) ».").foregroundStyle(.secondary).padding(.top, 8) }
            }
            Text("Corriger un passage marque le document comme obsolète ; tes modifications du document sont conservées jusqu’à la régénération.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: Markdown & archives

    private var markdownTab: some View {
        let text = ObsidianMarkdown.build(course, layout: layout, includeTranscript: exportTranscript, includeText: exportCleanText)
        let limit = 60_000
        return VStack(alignment: .leading, spacing: 8) {
            Text("Aperçu exact du fichier exporté : propriétés YAML, tags, sommaire avec liens, encadrés repliables.")
                .font(.caption).foregroundStyle(.secondary)
            Text(text.count > limit ? String(text.prefix(limit)) + "\n\n… (aperçu tronqué, l’export est complet)" : text)
                .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineSpacing(2)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
        }
    }

    @ViewBuilder private var archiveTab: some View {
        if let legacy = course.legacyMarkdown {
            NoticeView(symbol: "archivebox", tint: .secondary, title: "Résultats de la version précédente",
                       message: "Notes, fiches et résumé générés avant la refonte. Ils restent consultables et sont ajoutés à l’export dans un bloc repliable.")
            MarkdownContent(text: legacy, duration: course.duration, validTimes: course.sources.map(\.start))
        }
    }

    // MARK: Sheets

    @ViewBuilder private func sheetView(_ sheet: CourseModal) -> some View {
        switch sheet {
        case .rename:
            TextEditorSheet(title: "Renommer le cours", subtitle: "Le titre devient aussi le nom de la note Obsidian.", singleLine: true, original: course.title) { text in
                guard !gate.busy else { throw CourseError.message("Une opération est en cours.") }
                guard !text.trimmed.isEmpty else { throw CourseError.message("Le titre ne peut pas être vide.") }
                try gate.acquire("Édition"); defer { gate.release() }
                try await store.update(course.id) { $0.title = text.trimmed }
            }
        case .passage(let passage):
            TextEditorSheet(title: "Corriger le passage · \(timestamp(passage.start))", subtitle: "Le document sera marqué obsolète jusqu’à sa régénération.", original: passage.text) { text in
                try await store.editPassage(courseID: course.id, passageID: passage.id, text: text)
            }
        case .section(let section):
            SectionEditorSheet(section: section, themes: groups.map(\.name)) { title, theme, text in
                try await store.editSection(courseID: course.id, sectionIDs: section.ids, title: title, theme: theme, text: text)
            }
        case .theme(let name):
            TextEditorSheet(title: "Renommer le thème", subtitle: "Choisir le nom d’un autre thème fusionne les deux.", singleLine: true, original: name) { text in
                try await store.renameTheme(courseID: course.id, from: name, to: text)
            }
        }
    }

    // MARK: Actions

    private func listen(_ seconds: Double) {
        guard !captureActive else { return }
        do { player.configure(course, folder: store.folder(course.id)); try player.seek(seconds, play: true) } catch { store.error = error.localizedDescription }
    }
    private func export() {
        Task {
            do { if let url = try await ObsidianVault.export(course) { show("Exporté : \(url.lastPathComponent)") } }
            catch { store.error = error.localizedDescription }
        }
    }
    private func copyMarkdown() { ObsidianVault.copy(course); show("Markdown copié dans le presse-papiers") }
    private func show(_ message: String) {
        toast = message
        Task { try? await Task.sleep(for: .seconds(2.5)); if toast == message { toast = nil } }
    }
}

// MARK: - Document pieces

struct SectionView: View {
    let section: DocumentSection
    let color: Color
    let showTheme: Bool
    let active: Bool
    let editable: Bool
    let canPlay: Bool
    let play: (Double) -> Void
    let edit: () -> Void
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if !section.title.isEmpty { Text(section.title).font(.system(size: 17, weight: .semibold)).textSelection(.enabled) }
                if section.edited { Image(systemName: "pencil.circle.fill").foregroundStyle(.secondary).help("Modifiée à la main") }
                Spacer(minLength: 8)
                Button(action: edit) { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).opacity(hovering ? 1 : 0).disabled(!editable).help(section.title.isEmpty ? "Modifier le passage" : "Modifier la section")
                if let start = section.start {
                    Button { play(start) } label: {
                        Label(timestamp(start), systemImage: active ? "speaker.wave.2.fill" : "play.fill").font(.caption.monospacedDigit())
                    }
                    .buttonStyle(.borderless).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(active ? color.opacity(0.2) : Color.secondary.opacity(0.1)))
                    .disabled(!canPlay).help("Écouter ce passage")
                }
            }
            if showTheme { ThemeChip(name: section.theme, color: color) }
            if section.fallback {
                Label("Nettoyage simplifié : à relire.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .help(section.fallbackReason ?? "Le modèle n’a pas pu réécrire ce passage.")
            }
            ForEach(section.paragraphs) { paragraph in
                Text(paragraph.text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(active ? color.opacity(0.07) : .clear).padding(.horizontal, -10))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: active)
    }
}

struct TranscriptRow: View {
    let passage: SourcePassage
    let active: Bool
    let canPlay: Bool
    let editable: Bool
    let play: () -> Void
    let edit: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(action: play) { Text(timestamp(passage.start)).font(.system(.caption, design: .monospaced)) }
                .buttonStyle(.borderless).disabled(!canPlay).help("Écouter à partir d’ici")
            Text(passage.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: edit) { Image(systemName: "pencil") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0).disabled(!editable).help("Corriger le passage")
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.1) : hovering ? Color.secondary.opacity(0.06) : .clear))
        .onHover { hovering = $0 }
    }
}

struct FixesView: View {
    let fixes: [TranscriptFix]
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(fixes, id: \.self) { fix in
                    GridRow {
                        Text(fix.from).strikethrough().foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                        Text(fix.to).fontWeight(.medium)
                    }
                }
            }.textSelection(.enabled).padding(.top, 8)
        } label: {
            Label("Corrections de transcription (\(fixes.count))", systemImage: "text.badge.checkmark").font(.headline)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35)))
    }
}

struct OutlineColumn: View {
    let course: Course
    let groups: [ThemeGroup]
    let layout: DocumentLayout
    let fixes: Int
    let jump: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("PLAN").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    switch layout {
                    case .themes:
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            VStack(alignment: .leading, spacing: 5) {
                                Button { jump("theme:" + group.name) } label: {
                                    HStack(spacing: 7) {
                                        Circle().fill(ThemePalette.color(index)).frame(width: 8, height: 8)
                                        Text(group.name).font(.callout.weight(.semibold)).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                ForEach(group.sections) { section in sectionLink(section) }
                            }
                        }
                    case .chronological:
                        ForEach(course.documentSections) { section in
                            HStack(spacing: 7) {
                                Circle().fill(ThemePalette.color(groups.firstIndex { $0.name == section.theme } ?? 0)).frame(width: 6, height: 6)
                                sectionLink(section)
                            }
                        }
                    }
                    if fixes > 0 {
                        Divider()
                        Button { jump("fixes") } label: { Label("\(fixes) correction\(fixes > 1 ? "s" : "")", systemImage: "text.badge.checkmark").font(.callout) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let tags = course.themeIndex?.tags, !tags.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("TAGS OBSIDIAN").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text((["cours"] + tags).map { "#" + $0 }.joined(separator: "  ")).font(.caption).foregroundStyle(.tint).textSelection(.enabled)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
    }
    private func sectionLink(_ section: DocumentSection) -> some View {
        Button { jump("section:" + section.id.uuidString) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(section.title.nonEmpty ?? String(section.text.prefix(80))).font(.callout).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if let start = section.start { Text(timestamp(start)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.leading, layout == .themes ? 15 : 0)
    }
}

struct EmptyStateView<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.tint).symbolRenderingMode(.hierarchical)
            Text(title).font(.title3.weight(.semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            actions().padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 56)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

// MARK: - Course sheet

/// One block of the Markdown written by the model.
enum MarkdownBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([(indent: Int, text: String)])
    case numbered([(number: String, text: String)])
    case quote(String)
    case table([[String]])
    case rule
    static func == (a: Self, b: Self) -> Bool { String(describing: a) == String(describing: b) }
    func hash(into hasher: inout Hasher) { hasher.combine(String(describing: self)) }

    /// Block-level Markdown: headings, paragraphs, bullet and numbered lists, quotes, tables and rules.
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []; var paragraph: [String] = []
        let bullet = try! NSRegularExpression(pattern: "^(\\s*)[-*+]\\s+(.*)$"), numbered = try! NSRegularExpression(pattern: "^\\s*(\\d+)[.)]\\s+(.*)$")
        func match(_ regex: NSRegularExpression, _ line: String) -> [String]? {
            guard let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
            return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: line).map { String(line[$0]) } ?? "" }
        }
        func flush() { if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] } }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count, title = line.dropFirst(level)
                if level <= 6, title.hasPrefix(" ") { flush(); blocks.append(.heading(level: level, text: String(title).trimmed.replacingOccurrences(of: "#+$", with: "", options: .regularExpression).trimmed)); continue }
            }
            if line.range(of: "^([-*_])\\s*(\\1\\s*){2,}$", options: .regularExpression) != nil { flush(); blocks.append(.rule); continue }
            if let parts = match(bullet, raw) {
                flush(); let item = (indent: parts[0].replacingOccurrences(of: "\t", with: "  ").count / 2, text: parts[1].trimmed)
                if case .bullets(let items) = blocks.last { blocks[blocks.count - 1] = .bullets(items + [item]) } else { blocks.append(.bullets([item])) }
                continue
            }
            if let parts = match(numbered, raw) {
                flush(); let item = (number: parts[0], text: parts[1].trimmed)
                if case .numbered(let items) = blocks.last { blocks[blocks.count - 1] = .numbered(items + [item]) } else { blocks.append(.numbered([item])) }
                continue
            }
            if line.hasPrefix(">") {
                flush(); let quoted = String(line.dropFirst()).trimmed
                if case .quote(let previous) = blocks.last { blocks[blocks.count - 1] = .quote(previous + "\n" + quoted) } else { blocks.append(.quote(quoted)) }
                continue
            }
            if line.hasPrefix("|") {
                flush()
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map(\.trimmed)
                if cells.allSatisfy({ $0.range(of: "^:?-{2,}:?$", options: .regularExpression) != nil }) { continue }
                if case .table(let rows) = blocks.last { blocks[blocks.count - 1] = .table(rows + [cells]) } else { blocks.append(.table([cells])) }
                continue
            }
            // A line that follows a list item without a blank line continues it.
            if paragraph.isEmpty, case .bullets(var items) = blocks.last, raw.hasPrefix(" ") {
                items[items.count - 1].text += " " + line; blocks[blocks.count - 1] = .bullets(items); continue
            }
            paragraph.append(line)
        }
        flush()
        return blocks
    }
}

/// Text with inline Markdown (**bold**, *italic*, `code`).
struct InlineText: View {
    let value: String
    init(_ value: String) { self.value = value }
    var body: some View {
        Text((try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}

/// The course sheet as the model wrote it: whatever structure it chose is rendered as is.
struct SheetMarkdownView: View {
    let blocks: [MarkdownBlock]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(block).id("md:\(index)")
            }
        }
    }
    @ViewBuilder private func view(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            switch level {
            case ...2: InlineText(text).font(.system(size: 24, weight: .bold)).padding(.top, 18)
            case 3: InlineText(text).font(.system(size: 19, weight: .semibold)).foregroundStyle(.tint).padding(.top, 8)
            default: InlineText(text).font(.system(size: 16, weight: .semibold)).padding(.top, 4)
            }
        case .paragraph(let text):
            InlineText(text).font(.system(size: 15)).lineSpacing(5)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(item.indent > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint)).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        InlineText(item.text).font(.system(size: 15)).lineSpacing(3)
                    }.padding(.leading, CGFloat(item.indent) * 18)
                }
            }.padding(.leading, 4)
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.number + ".").font(.system(size: 15).monospacedDigit().weight(.semibold)).foregroundStyle(.tint)
                        InlineText(item.text).font(.system(size: 15)).lineSpacing(3)
                    }
                }
            }.padding(.leading, 4)
        case .quote(let text):
            InlineText(text).font(.system(size: 15)).lineSpacing(4).padding(.leading, 14).padding(.vertical, 4)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(.tint.opacity(0.5)).frame(width: 3) }
        case .table(let rows):
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in InlineText(cell).font(.system(size: 14, weight: index == 0 ? .semibold : .regular)) } }
                    if index == 0 { Divider() }
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35)))
        case .rule:
            Divider().padding(.vertical, 6)
        }
    }
}

/// The plan of the sheet, made of the titles the model chose.
struct SheetOutline: View {
    let blocks: [MarkdownBlock]
    let jump: (String) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("PLAN").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    if case .heading(let level, let text) = block, level <= 3 {
                        Button { jump("md:\(index)") } label: {
                            InlineText(text).font(level <= 2 ? .callout.weight(.semibold) : .callout).foregroundStyle(level <= 2 ? .primary : .secondary)
                                .lineLimit(2).multilineTextAlignment(.leading).textSelection(.disabled)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).padding(.leading, level <= 2 ? 0 : 14).padding(.top, level <= 2 && index > 0 ? 6 : 0)
                    }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
    }
}
