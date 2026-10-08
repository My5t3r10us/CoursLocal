import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Checks the AI provider so the sidebar and welcome screen can show whether processing will work.
@MainActor
final class ServerMonitor: ObservableObject {
    enum State: Equatable { case unknown, checking, unconfigured, needsKey, online(String), offline(String) }
    @Published private(set) var state: State = .unknown
    @Published private(set) var provider: AIProvider = .current
    var ready: Bool { if case .online = state { return true }; return false }
    /// Automatic checks never read the keychain, which may show a macOS password prompt:
    /// they use a key already read during this launch. ↻ is the only check allowed to read it.
    func refresh(interactive: Bool = false) async {
        let d = UserDefaults.standard; provider = .current
        let model = d.string(forKey: provider.modelKey) ?? ""
        guard !model.isEmpty else { state = .unconfigured; return }
        var key = APIKeyStore.cached(provider)
        if key == nil && interactive { key = try? APIKeyStore.read(provider) }
        if provider == .openRouter && (key ?? "").isEmpty {
            state = APIKeyStore.isStored(provider) ? .needsKey : .offline("Ajoute ta clé OpenRouter dans les réglages."); return
        }
        state = .checking
        let settings = AISettings(baseURL: provider == .local ? d.string(forKey: "rapidMLXURL") ?? "http://127.0.0.1:7659/v1" : AIProvider.openRouterBase.absoluteString,
                                  model: model, whisperModel: "", language: "", apiKey: key ?? "", provider: provider)
        do { try await RapidMLXClient().checkModel(settings: settings); state = .online(model) }
        catch CourseError.unauthorized(let message) { state = key == nil ? .needsKey : .offline(message) }
        catch { state = .offline(error.localizedDescription) }
    }
    var color: Color {
        switch state { case .online: return .green; case .offline: return .red; case .unconfigured, .needsKey: return .orange; default: return .gray }
    }
    var title: String {
        let name = provider == .local ? "IA locale" : "OpenRouter"
        switch state {
        case .online: return "\(name) prête"; case .offline: return "\(name) indisponible"; case .unconfigured: return "\(name) à configurer"
        case .needsKey: return "\(name) : clé à vérifier"; case .checking: return "Vérification…"; case .unknown: return name
        }
    }
    var detail: String {
        switch state {
        case .online(let model): return provider == .local ? model : "\(model) · cloud"
        case .offline(let message): return message
        case .unconfigured: return "Choisis un modèle dans les réglages"; case .needsKey: return "Clique sur ↻ pour vérifier avec ta clé API"
        default: return provider.name
        }
    }
}

@MainActor
struct ContentView: View {
    @ObservedObject var store: CourseStore
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var pipeline: Pipeline
    @ObservedObject var player: CourseAudioPlayer
    @ObservedObject var gate: OperationGate
    @ObservedObject var phoneReceiver: PhoneReceiver
    @ObservedObject var remote: PhoneRemote
    @StateObject private var server = ServerMonitor()
    @StateObject private var assistant: CourseAssistant
    @AppStorage("rapidMLXModel") private var model = ""
    @AppStorage("rapidMLXURL") private var baseURL = "http://127.0.0.1:7659/v1"
    @AppStorage("aiProvider") private var provider: AIProvider = .local
    @AppStorage("openRouterModel") private var cloudModel = ""
    @AppStorage("apiKeyRevision") private var keyRevision = 0
    @State private var selection: UUID?
    @State private var search = ""
    @State private var newCourse = false
    @State private var phoneStart = false
    @State private var pendingDelete: Course?
    init(store: CourseStore, recorder: AudioRecorder, pipeline: Pipeline, player: CourseAudioPlayer, phoneReceiver: PhoneReceiver) {
        self.store = store; self.recorder = recorder; self.pipeline = pipeline; self.player = player; gate = store.gate; self.phoneReceiver = phoneReceiver; remote = phoneReceiver.remote
        _assistant = StateObject(wrappedValue: CourseAssistant(store: store))
    }
    private var filtered: [Course] {
        let query = search.trimmed
        return store.courses.filter { query.isEmpty || $0.searchText.localizedStandardContains(query) }
    }
    private var groups: [(title: String, courses: [Course])] {
        let calendar = Calendar.current, now = Date()
        let titles = ["Aujourd’hui", "Hier", "7 derniers jours", "Ce mois-ci", "Plus ancien"]
        func bucket(_ date: Date) -> Int {
            if calendar.isDateInToday(date) { return 0 }
            if calendar.isDateInYesterday(date) { return 1 }
            if (calendar.dateComponents([.day], from: date, to: now).day ?? 99) < 7 { return 2 }
            return calendar.isDate(date, equalTo: now, toGranularity: .month) ? 3 : 4
        }
        let sorted = filtered.sorted { $0.createdAt > $1.createdAt }
        return titles.indices.compactMap { i in
            let courses = sorted.filter { bucket($0.createdAt) == i }
            return courses.isEmpty ? nil : (titles[i], courses)
        }
    }
    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if recorder.courseID != nil { RecordingBanner(store: store, recorder: recorder) }
                        if pipeline.busy { ProcessingBanner(store: store, pipeline: pipeline, selection: selection) }
                        PhoneRecordingBanner(remote: remote)
                        if let activity = phoneReceiver.activity { PhoneTransferBanner(activity: activity) }
                    }
                }
                .animation(.smooth(duration: 0.25), value: phoneReceiver.activity == nil)
                .animation(.smooth(duration: 0.25), value: remote.recording)
                .animation(.smooth(duration: 0.25), value: pipeline.busy)
                .animation(.smooth(duration: 0.25), value: recorder.courseID)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: startNewCourse) { Label("Enregistrer", systemImage: "record.circle") }
                    .help("Enregistrer un nouveau cours").disabled(gate.busy || !store.ready)
                Button(action: importAudio) { Label("Importer", systemImage: "square.and.arrow.down") }
                    .help("Importer un fichier audio").disabled(gate.busy || !store.ready)
                if remote.connected {
                    Button { phoneStart = true } label: { Label("Enregistrer sur l’iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right") }
                        .help("Démarrer l’enregistrement sur \(remote.device ?? "l’iPhone")").disabled(remote.recording)
                }
            }
        }
        .sheet(isPresented: $phoneStart) { PhoneStartSheet(remote: remote) }
        .sheet(isPresented: $newCourse) {
            NewCourseSheet { title, mode, pid in
                player.stop()
                Task {
                    do { selection = try await recorder.start(title: title, mode: mode, applicationPID: pid) }
                    catch { store.error = error.localizedDescription }
                }
            }
        }
        .confirmationDialog("Supprimer « \(pendingDelete?.title ?? "") » ?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { course in
            Button("Supprimer le cours et son audio", role: .destructive) { delete(course) }
        } message: { _ in Text("Le cours, sa transcription, son document et ses fichiers audio seront définitivement supprimés de ce Mac.") }
        .onChange(of: pipeline.courseID) { _, id in if let id { selection = id } }
        .onChange(of: recorder.courseID) { _, id in if let id { player.stop(); selection = id } }
        .onChange(of: model) { _, _ in Task { await server.refresh() } }
        .onChange(of: baseURL) { _, _ in Task { await server.refresh() } }
        .onChange(of: provider) { _, _ in Task { await server.refresh() } }
        .onChange(of: cloudModel) { _, _ in Task { await server.refresh() } }
        .onChange(of: keyRevision) { _, _ in Task { await server.refresh() } }
        .task { await server.refresh() }
        .alert("CoursLocal", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.courses) { course in
                        CourseRow(course: course, activity: activity(for: course)).tag(course.id)
                            .contextMenu {
                                Button("Exporter vers Obsidian") { export(course) }.disabled(!course.hasDocument && course.sources.isEmpty)
                                Button("Copier le Markdown") { ObsidianVault.copy(course) }
                                Button("Afficher les fichiers audio") { NSWorkspace.shared.open(store.folder(course.id)) }
                                Divider()
                                Button("Supprimer…", role: .destructive) { pendingDelete = course }.disabled(gate.busy)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Rechercher dans les cours")
        .overlay {
            if store.ready && filtered.isEmpty {
                if search.trimmed.isEmpty {
                    ContentUnavailableView("Aucun cours", systemImage: "tray", description: Text("Enregistre ou importe ton premier cours."))
                } else { ContentUnavailableView.search(text: search) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                PhoneRemoteCard(remote: remote) { phoneStart = true }
                serverFooter
            }
        }
        .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 420)
    }

    private var serverFooter: some View {
        HStack(spacing: 10) {
            Circle().fill(server.color).frame(width: 8, height: 8)
                .overlay { if case .checking = server.state { ProgressView().controlSize(.mini) } }
            VStack(alignment: .leading, spacing: 1) {
                Text(server.title).font(.caption.weight(.semibold))
                Text(server.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button { Task { await server.refresh(interactive: true) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Vérifier le serveur local")
            SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Réglages")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(10)
        .help(server.detail)
    }

    private func activity(for course: Course) -> String? {
        if recorder.courseID == course.id { return recorder.paused ? "En pause · \(timestamp(recorder.elapsed))" : "Enregistrement · \(timestamp(recorder.elapsed))" }
        if pipeline.courseID == course.id { return pipeline.progress }
        return nil
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let id = selection, let course = store.course(id) {
            CourseView(course: course, store: store, player: player, gate: gate, assistant: assistant, process: { mode in
                player.stop()
                do { pipeline.process(id: id, settings: try AISettings.current(), regenerate: mode == .regenerate, retryFallbacks: mode == .retryFallbacks, regenerateSheet: mode == .regenerateSheet) }
                catch { store.error = error.localizedDescription }
            }, reimport: importAudio, delete: { pendingDelete = course })
            .id(id)
        } else if !store.ready {
            ProgressView("Chargement de la bibliothèque").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            WelcomeView(server: server, busy: gate.busy, record: startNewCourse, importAudio: importAudio)
        }
    }

    private func startNewCourse() { guard !gate.busy else { return }; newCourse = true }
    private func importAudio() {
        guard !gate.busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.message = "Choisis l’enregistrement du cours à transcrire."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        player.stop()
        do { pipeline.importAudio(url, title: "", settings: try AISettings.current()) } catch { store.error = error.localizedDescription }
    }
    private func export(_ course: Course) {
        Task { do { try await ObsidianVault.export(course) } catch { store.error = error.localizedDescription } }
    }
    private func delete(_ course: Course) {
        if player.currentCourseID == course.id { player.stop() }
        if selection == course.id { selection = nil }
        Task { do { try await store.delete(course.id) } catch { store.error = error.localizedDescription } }
    }
}

// MARK: - Sidebar row

struct CourseRow: View {
    let course: Course
    let activity: String?
    var body: some View {
        let themes = course.themeNames
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(course.state.tint.opacity(0.15))
                Image(systemName: course.state.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(course.state.tint)
            }.frame(width: 24, height: 24).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(course.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                if let activity {
                    Text(activity).font(.caption).foregroundStyle(.tint).lineLimit(1)
                } else {
                    Text("\(course.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())) · \(shortDuration(course.duration))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !themes.isEmpty {
                    Text(themes.prefix(3).joined(separator: " · ") + (themes.count > 3 ? " +\(themes.count - 3)" : ""))
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }.padding(.vertical, 4)
    }
}

// MARK: - Activity banners

struct RecordingBanner: View {
    @ObservedObject var store: CourseStore
    @ObservedObject var recorder: AudioRecorder
    var body: some View {
        let course = recorder.courseID.flatMap { store.course($0) }
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(.red.opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: recorder.paused ? "pause.fill" : "record.circle.fill").font(.system(size: 18)).foregroundStyle(.red)
                    .symbolEffect(.pulse, isActive: !recorder.paused && !recorder.stopping)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(recorder.stopping ? "Finalisation…" : recorder.paused ? "En pause" : "Enregistrement en cours").font(.headline)
                Text(course?.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(timestamp(recorder.elapsed)).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                .padding(.leading, 8)
            VStack(alignment: .leading, spacing: 5) {
                if course?.captureMode.usesMicrophone ?? true { LevelMeter(label: "Micro", value: recorder.level) }
                if course?.captureMode.usesApplication == true { LevelMeter(label: "App", value: recorder.applicationLevel) }
            }.padding(.leading, 8)
            Spacer()
            Button { Task { await recorder.togglePause() } } label: {
                Label(recorder.paused ? "Reprendre" : "Pause", systemImage: recorder.paused ? "play.fill" : "pause.fill")
            }.controlSize(.large).disabled(recorder.stopping)
            Button { Task { await recorder.stop() } } label: { Label("Terminer", systemImage: "stop.fill") }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large).disabled(recorder.stopping)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(LinearGradient(colors: [.red.opacity(0.12), .red.opacity(0.03)], startPoint: .leading, endPoint: .trailing))
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct ProcessingBanner: View {
    @ObservedObject var store: CourseStore
    @ObservedObject var pipeline: Pipeline
    let selection: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(pipeline.progress).font(.headline)
                if let id = pipeline.courseID, id != selection, let course = store.course(id) {
                    Text("· \(course.title)").foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Interrompre") { pipeline.cancel() }.help("Les étapes terminées sont conservées ; tu pourras reprendre.")
            }
            if let phase = pipeline.phase { PhaseSteps(current: phase) }
            if pipeline.total > 0 {
                ProgressView(value: Double(pipeline.completed), total: Double(pipeline.total)).progressViewStyle(.linear)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.06))
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct PhoneTransferBanner: View {
    let activity: PhoneReceiver.Activity
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "iphone.and.arrow.forward").foregroundStyle(.tint)
                Text("Réception depuis l’iPhone").font(.headline)
                Text("· \(activity.title)").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(activity.fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: activity.fraction).progressViewStyle(.linear)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.06))
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct PhaseSteps: View {
    let current: PipelinePhase
    var body: some View {
        HStack(spacing: 6) {
            ForEach(PipelinePhase.allCases, id: \.self) { phase in
                let done = phase.rawValue < current.rawValue, active = phase == current
                HStack(spacing: 5) {
                    Image(systemName: done ? "checkmark.circle.fill" : phase.symbol)
                        .foregroundStyle(done ? AnyShapeStyle(.green) : active ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    Text(phase.label).fontWeight(active ? .semibold : .regular)
                        .foregroundStyle(active ? .primary : .secondary)
                }.font(.caption)
                if phase != PipelinePhase.allCases.last {
                    Rectangle().fill(done ? AnyShapeStyle(.green.opacity(0.5)) : AnyShapeStyle(.quaternary)).frame(width: 24, height: 1.5)
                }
            }
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @ObservedObject var server: ServerMonitor
    let busy: Bool
    let record: () -> Void
    let importAudio: () -> Void
    @State private var vaultConfigured = false
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.and.mic").font(.system(size: 54)).foregroundStyle(.tint).symbolRenderingMode(.hierarchical)
                    Text("CoursLocal").font(.system(size: 34, weight: .bold))
                    Text("Enregistre un cours et obtiens une vraie fiche de cours et un texte propre, découpé en thèmes, prêts pour Obsidian." + (server.provider == .local ? " Tout reste sur ce Mac." : " Le nettoyage passe par OpenRouter ; l’audio reste sur ce Mac."))
                        .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
                }
                HStack(spacing: 16) {
                    ActionCard(symbol: "record.circle", tint: .red, title: "Enregistrer un cours", subtitle: "Micro, application ou les deux", action: record)
                    ActionCard(symbol: "square.and.arrow.down", tint: .blue, title: "Importer un audio", subtitle: "M4A, MP3, WAV, vidéo…", action: importAudio)
                }.disabled(busy)
                HStack(alignment: .top, spacing: 0) {
                    step("waveform", "Transcription", "Whisper, en local")
                    arrow
                    step("eraser", "Filtrage", "Tics de langage, hésitations")
                    arrow
                    step("text.badge.checkmark", "Correction", "Erreurs de transcription")
                    arrow
                    step("square.stack.3d.up", "Structure", "Paragraphes et thèmes")
                    arrow
                    step("list.bullet.rectangle", "Fiche", "Résumé, notions, questions")
                    arrow
                    step("doc.richtext", "Obsidian", "Markdown, tags, sommaire")
                }.frame(maxWidth: 860)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Configuration").font(.headline)
                    setupRow(done: server.ready, title: server.title, detail: server.detail)
                    setupRow(done: vaultConfigured, title: vaultConfigured ? "Coffre Obsidian choisi" : "Coffre Obsidian (facultatif)",
                             detail: vaultConfigured ? "Les exports y sont écrits directement." : "Sans coffre, l’export demande où enregistrer le fichier.")
                }
                .padding(18).frame(maxWidth: 520, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.4)))
            }
            .padding(40).frame(maxWidth: .infinity)
        }
        .onAppear { vaultConfigured = ObsidianVault.folder != nil }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in vaultConfigured = ObsidianVault.folder != nil }
    }
    private func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(height: 28)
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }
    private var arrow: some View { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).padding(.top, 8) }
    private func setupRow(done: Bool, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed").font(.title3).foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if !done { SettingsLink { Text("Configurer") } }
        }
    }
}

struct ActionCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 26, weight: .medium)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(20).frame(width: 240, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(hovering ? 0.14 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(hovering ? 0.45 : 0.2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - New course

struct NewCourseSheet: View {
    let start: (String, CaptureMode, pid_t?) -> Void
    @State private var title = ""
    @State private var mode: CaptureMode = .microphone
    @State private var applicationPID: pid_t = 0
    @State private var applications: [NSRunningApplication] = AudioRecorder.applications
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nouveau cours").font(.title2.bold())
                Text("Le traitement démarre automatiquement à la fin de l’enregistrement.").font(.callout).foregroundStyle(.secondary)
            }
            TextField("Titre du cours (facultatif)", text: $title).textFieldStyle(.roundedBorder).font(.title3)
            VStack(alignment: .leading, spacing: 8) {
                Text("Source audio").font(.headline)
                HStack(spacing: 10) {
                    ForEach(CaptureMode.allCases) { option in
                        Button { mode = option } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: option.symbol).font(.title2).foregroundStyle(mode == option ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                Text(option.label).font(.callout.weight(.semibold))
                                Text(option.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .padding(12).frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(mode == option ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(mode == option ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: mode == option ? 2 : 1))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            if mode.usesApplication {
                HStack {
                    Picker("Application", selection: $applicationPID) {
                        Text("Choisir une application").tag(pid_t(0))
                        ForEach(applications, id: \.processIdentifier) { Text($0.localizedName ?? "Application").tag($0.processIdentifier) }
                    }
                    Button { applications = AudioRecorder.applications } label: { Image(systemName: "arrow.clockwise") }.help("Actualiser la liste")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if mode.usesApplication { hint("lock.shield", "macOS demandera l’accès à l’écran et au son système. Seul l’audio de l’application choisie est conservé, jamais l’image.") }
                if mode.usesMicrophone { hint("mic", "Micro d’entrée défini dans Réglages Système → Son.") }
                if mode == .combined { hint("headphones", "Utilise un casque pour éviter que le micro reprenne le son des haut-parleurs.") }
            }
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    dismiss(); start(title, mode, mode.usesApplication ? applicationPID : nil)
                } label: { Label("Démarrer l’enregistrement", systemImage: "record.circle") }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.red)
                    .disabled(mode.usesApplication && applicationPID == 0)
            }
        }
        .padding(24).frame(width: 560)
    }
    private func hint(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
