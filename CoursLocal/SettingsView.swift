import SwiftUI
import AppKit

@MainActor
struct PreferencesView: View {
    var body: some View {
        TabView {
            TranscriptionSettings().tabItem { Label("Transcription", systemImage: "waveform") }
            AISettingsView().tabItem { Label("IA", systemImage: "cpu") }
            ObsidianSettings().tabItem { Label("Obsidian", systemImage: "doc.richtext") }
            PhoneSettings().tabItem { Label("iPhone", systemImage: "iphone") }
            GeneralSettings().tabItem { Label("Général", systemImage: "gearshape") }
        }
        .frame(width: 640, height: 560)
    }
}

private struct TranscriptionSettings: View {
    @AppStorage("whisperModel") private var whisperModel = "large-v3-v20240930_626MB"
    @AppStorage("language") private var language = "fr"
    var body: some View {
        Form {
            Section {
                Picker("Modèle Whisper", selection: $whisperModel) {
                    Text("Whisper large-v3 Turbo (précis)").tag("large-v3-v20240930_626MB")
                    Text("Whisper medium (équilibré)").tag("medium")
                    Text("Whisper small (rapide)").tag("small")
                }
                Picker("Langue du cours", selection: $language) {
                    Text("Français").tag("fr"); Text("Anglais").tag("en"); Text("Détection automatique").tag("auto")
                }
            } footer: {
                Text("Whisper est intégré à l’application. Le premier traitement peut télécharger le modèle ; ensuite, la transcription fonctionne hors ligne.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct SettingsStatus: Equatable {
    var text: String
    var ok: Bool
    var view: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill").font(.caption).foregroundStyle(ok ? .green : .red)
    }
}

private struct AISettingsView: View {
    @AppStorage("aiProvider") private var provider: AIProvider = .local
    var body: some View {
        Form {
            Section {
                Picker("Fournisseur", selection: $provider) { ForEach(AIProvider.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented)
                Text("Le modèle relit la transcription bloc par bloc : il retire les tics de langage et hésitations, corrige les erreurs de transcription évidentes, puis découpe le texte en paragraphes et en sections thématiques. Il ne résume pas et n’ajoute rien. La transcription Whisper reste toujours locale.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if provider == .local { LocalAISection() } else { OpenRouterSection() }
        }
        .formStyle(.grouped)
    }
}

/// Shows whether a key is stored without reading it: the secret is only read when it is used.
private struct KeyEditor: View {
    let provider: AIProvider
    let placeholder: String
    @Binding var draft: String
    @Binding var status: SettingsStatus?
    @AppStorage("apiKeyRevision") private var revision = 0
    @State private var stored = false
    var body: some View {
        SecureField("Clé API", text: $draft, prompt: Text(stored ? "Enregistrée — saisis-en une nouvelle pour la remplacer" : placeholder))
        HStack {
            if stored { Label("Clé enregistrée dans le trousseau", systemImage: "key.fill").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if stored { Button("Supprimer", role: .destructive) { save("") } }
            Button("Enregistrer la clé") { save(draft.trimmed) }.disabled(draft.trimmed.isEmpty)
        }
        .onAppear { stored = APIKeyStore.isStored(provider) }
    }
    func save(_ value: String) {
        do {
            try APIKeyStore.save(value, for: provider)
            stored = !value.isEmpty; draft = ""; revision += 1
            status = SettingsStatus(text: value.isEmpty ? "Clé supprimée." : "Clé enregistrée dans le trousseau.", ok: true)
        } catch { status = SettingsStatus(text: error.localizedDescription, ok: false) }
    }
}

private struct LocalAISection: View {
    @AppStorage("rapidMLXModel") private var model = ""
    @AppStorage("rapidMLXURL") private var baseURL = "http://127.0.0.1:7659/v1"
    @State private var draft = ""
    @State private var models: [RapidModel] = []
    @State private var checking = false
    @State private var status: SettingsStatus?
    var body: some View {
        Section {
            TextField("Adresse locale", text: $baseURL)
            KeyEditor(provider: .local, placeholder: "Facultative, si ton serveur en exige une", draft: $draft, status: $status)
            HStack {
                Picker("Modèle texte", selection: $model) {
                    Text("Choisir un modèle local").tag("")
                    if !model.isEmpty && !models.contains(where: { $0.id == model }) { Text(model + " — à vérifier").tag(model) }
                    ForEach(models) { Text($0.id).tag($0.id) }
                }
                Button { test() } label: {
                    HStack(spacing: 6) { if checking { ProgressView().controlSize(.small) }; Text(checking ? "Connexion…" : "Tester et actualiser") }
                }.disabled(checking)
            }
            if let status { status.view }
        } header: { Text("Rapid MLX Desktop") } footer: {
            Text("Démarre le serveur dans Rapid MLX Desktop et choisis un modèle local. CoursLocal ne contacte que l’adresse de boucle locale et refuse toute redirection. Un modèle d’instruction de 7 B ou plus donne de meilleurs résultats en français.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func test() {
        checking = true; let url = baseURL; let typed = draft.trimmed
        Task {
            do {
                if !typed.isEmpty { try APIKeyStore.save(typed, for: .local); draft = "" }
                models = try await RapidMLXClient().discover(baseURL: url, key: try APIKeyStore.read(.local))
                status = SettingsStatus(text: models.isEmpty ? "Serveur connecté, aucun modèle texte exposé." : "Serveur connecté : \(models.count) modèle(s) texte.", ok: !models.isEmpty)
            } catch { status = SettingsStatus(text: error.localizedDescription, ok: false) }
            checking = false
        }
    }
}

private struct OpenRouterSection: View {
    @AppStorage("openRouterModel") private var model = ""
    @AppStorage("openRouterDenyDataCollection") private var deny = true
    @State private var draft = ""
    @State private var status: SettingsStatus?
    @State private var models: [CloudModel] = []
    @State private var loading = false
    @State private var browsing = false
    private var selected: CloudModel? { models.first { $0.id == model } }
    var body: some View {
        Section {
            NoticeView(symbol: "icloud.and.arrow.up", tint: .orange, title: "Le texte des cours quitte ce Mac",
                       message: "En mode cloud, la transcription (jamais l’audio) est envoyée à OpenRouter puis au fournisseur du modèle choisi. Ses conditions d’utilisation et de conservation des données s’appliquent.")
        }
        Section {
            KeyEditor(provider: .openRouter, placeholder: "sk-or-v1-…", draft: $draft, status: $status)
            HStack {
                Link("Créer une clé sur openrouter.ai", destination: URL(string: "https://openrouter.ai/settings/keys")!).font(.callout)
                Spacer()
                Button { verify() } label: {
                    HStack(spacing: 6) { if loading { ProgressView().controlSize(.small) }; Text("Vérifier la clé") }
                }.disabled(loading)
            }
            if let status { status.view }
        } header: { Text("Clé OpenRouter") }
        Section {
            HStack {
                TextField("Modèle", text: $model, prompt: Text("ex. google/gemini-2.5-flash"))
                Button { browse() } label: { Text("Parcourir…") }.disabled(loading)
            }
            if let selected {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.displayName).font(.callout.weight(.medium))
                    Text(ModelBrowser.summary(selected)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Exclure les fournisseurs qui conservent ou réutilisent les données", isOn: $deny)
        } header: { Text("Modèle") } footer: {
            Text("Un cours de 2 h représente environ 60 000 tokens envoyés et 40 000 reçus. Le filtre de confidentialité réduit le nombre de modèles et de fournisseurs utilisables ; désactive-le si une requête est refusée faute de fournisseur.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $browsing) { ModelBrowser(models: models, selection: $model) }
    }
    /// Reading the stored key may show the keychain prompt, but only after this explicit click.
    private func key() throws -> String {
        let typed = draft.trimmed
        if !typed.isEmpty { try APIKeyStore.save(typed, for: .openRouter); draft = "" }
        return try APIKeyStore.read(.openRouter)
    }
    private func verify() {
        loading = true
        Task {
            do {
                let info = try await RapidMLXClient().openRouterKey(try key())
                var text = "Clé valide" + (info.label.map { " (\($0))" } ?? "")
                if let remaining = info.limit_remaining { text += String(format: " · crédit restant : %.2f $", remaining) }
                else if let usage = info.usage { text += String(format: " · utilisé : %.2f $", usage) }
                status = SettingsStatus(text: text, ok: true)
            } catch { status = SettingsStatus(text: error.localizedDescription, ok: false) }
            loading = false
        }
    }
    private func browse() {
        guard models.isEmpty else { browsing = true; return }
        loading = true
        Task {
            do { models = try await RapidMLXClient().openRouterModels(try key()); browsing = true }
            catch { status = SettingsStatus(text: error.localizedDescription, ok: false) }
            loading = false
        }
    }
}

struct ModelBrowser: View {
    let models: [CloudModel]
    @Binding var selection: String
    @State private var query = ""
    @State private var freeOnly = false
    @State private var sortByPrice = false
    @State private var highlighted: String?
    @Environment(\.dismiss) private var dismiss
    private var filtered: [CloudModel] {
        let q = query.trimmed
        let list = models.filter { (!freeOnly || $0.isFree) && (q.isEmpty || $0.displayName.localizedStandardContains(q) || $0.id.localizedStandardContains(q)) }
        return sortByPrice ? list.sorted { ($0.twoHourCost ?? .infinity) < ($1.twoHourCost ?? .infinity) } : list
    }
    static func summary(_ model: CloudModel) -> String {
        var parts = [model.id]
        if model.isFree { parts.append("gratuit") }
        else if let p = model.promptPrice, let c = model.completionPrice { parts.append(String(format: "%.2f $ / %.2f $ par M tokens", p * 1e6, c * 1e6)) }
        if let cost = model.twoHourCost, !model.isFree { parts.append(String(format: "≈ %.2f $ pour 2 h de cours", cost)) }
        if let context = model.context_length { parts.append("\(context / 1000)k de contexte") }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Modèles OpenRouter").font(.title3.bold())
            HStack {
                TextField("Rechercher (nom ou identifiant)", text: $query).textFieldStyle(.roundedBorder)
                Toggle("Gratuits", isOn: $freeOnly).toggleStyle(.checkbox)
                Picker("Tri", selection: $sortByPrice) { Text("Nom").tag(false); Text("Prix").tag(true) }.pickerStyle(.segmented).fixedSize()
            }
            List(filtered, id: \.id, selection: $highlighted) { model in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(model.displayName).fontWeight(.medium)
                        if model.isFree { Text("Gratuit").font(.caption2.weight(.semibold)).foregroundStyle(.green).padding(.horizontal, 5).background(Capsule().fill(.green.opacity(0.12))) }
                    }
                    Text(Self.summary(model)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 2).tag(model.id)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let id = ids.first { selection = id; dismiss() }
            }
            HStack {
                Text("\(filtered.count) modèle(s) · double-clic pour choisir").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choisir") { if let highlighted { selection = highlighted }; dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(highlighted == nil)
            }
        }
        .padding(20).frame(width: 680, height: 540)
        .onAppear { highlighted = models.contains { $0.id == selection } ? selection : nil }
    }
}

private struct ObsidianSettings: View {
    @AppStorage("obsidianSubfolder") private var subfolder = "Cours"
    @AppStorage("openInObsidian") private var openInObsidian = true
    @AppStorage("exportTranscript") private var exportTranscript = true
    @AppStorage("exportCleanText") private var exportCleanText = true
    @AppStorage("documentLayout") private var layout: DocumentLayout = .themes
    @State private var vault: URL?
    @State private var problem: String?
    var body: some View {
        Form {
            Section {
                LabeledContent("Coffre") {
                    HStack {
                        if let vault {
                            Label(vault.lastPathComponent, systemImage: "folder.fill").help(vault.path)
                        } else { Text("Aucun").foregroundStyle(.secondary) }
                        Spacer()
                        Button(vault == nil ? "Choisir…" : "Changer…") {
                            do { if let url = try ObsidianVault.choose() { vault = url; problem = nil } } catch { problem = error.localizedDescription }
                        }
                        if vault != nil { Button("Oublier") { ObsidianVault.forget(); vault = nil } }
                    }
                }
                TextField("Sous-dossier", text: $subfolder, prompt: Text("Cours"))
                Toggle("Ouvrir la note dans Obsidian après l’export", isOn: $openInObsidian).disabled(vault == nil)
                if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            } header: { Text("Destination") } footer: {
                Text(vault == nil ? "Sans coffre, chaque export demande où enregistrer le fichier." : "Les notes sont écrites dans « \(vault!.lastPathComponent)/\(subfolder.trimmed.isEmpty ? "" : subfolder.trimmed + "/")Titre du cours.md ». Une note existante n’est remplacée qu’après confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Contenu de la note") {
                Picker("Organisation", selection: $layout) { ForEach(DocumentLayout.allCases) { Text($0.label).tag($0) } }
                Toggle("Inclure le texte nettoyé sous la fiche", isOn: $exportCleanText)
                Toggle("Inclure la transcription brute (bloc repliable)", isOn: $exportTranscript)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chaque note contient :").font(.callout)
                    Text("• des propriétés YAML (titre, date, durée, tags, thèmes)\n• la fiche de cours : l’essentiel, à retenir, fiche par thème, questions de révision repliables\n• le texte nettoyé par thème, avec horodatage\n• les corrections de transcription dans un encadré repliable")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .onAppear { vault = ObsidianVault.folder }
    }
}

private struct GeneralSettings: View {
    @AppStorage("autoProcess") private var autoProcess = true
    @AppStorage("aiProvider") private var provider: AIProvider = .local
    @AppStorage("generateSheet") private var generateSheet = true
    @AppStorage("recordingHotKeyEnabled") private var hotKeyEnabled = true
    @AppStorage("hotKeyCaptureMode") private var hotKeyMode: CaptureMode = .microphone
    @AppStorage("recordingPill") private var pill = true
    var body: some View {
        Form {
            Section {
                Toggle("Raccourci global pour démarrer / terminer", isOn: $hotKeyEnabled)
                    .onChange(of: hotKeyEnabled) { _, _ in HotKeyCenter.shared.reload() }
                if hotKeyEnabled {
                    LabeledContent("Raccourci") { HotKeyRecorder() }
                    Picker("Source audio", selection: $hotKeyMode) { ForEach(CaptureMode.allCases) { Text($0.label).tag($0) } }
                }
                Toggle("Afficher la pastille flottante pendant l’enregistrement", isOn: $pill)
            } header: { Text("Enregistrement rapide") } footer: {
                Text("Le raccourci fonctionne même quand CoursLocal est en arrière-plan. Avec une source « Application », c’est l’application au premier plan qui est capturée. Dans la pastille, le point met en pause et ✕ termine l’enregistrement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Traiter automatiquement après l’enregistrement ou l’import", isOn: $autoProcess)
                Toggle("Créer une fiche de cours après le nettoyage", isOn: $generateSheet)
            } footer: {
                Text("La fiche résume le texte nettoyé : l’essentiel, les points à retenir, les points clés, définitions et exemples de chaque thème, les remarques du professeur et des questions de révision. Elle demande quelques requêtes de plus au modèle. Une régénération explicite remplace le document et ses modifications. Un changement de modèle Whisper ou de langue remplace aussi les corrections de transcription.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Confidentialité") {
                Label("Audio, transcriptions et documents sont stockés sur ce Mac.", systemImage: "lock.fill")
                if provider == .local { Label("Aucun service externe n’est contacté pour le traitement.", systemImage: "network.slash") }
                else { Label("Mode cloud : le texte des transcriptions est envoyé à OpenRouter pour le nettoyage.", systemImage: "icloud.and.arrow.up") }
            }
        }.formStyle(.grouped)
    }
}

private struct PhoneSettings: View {
    @EnvironmentObject private var receiver: PhoneReceiver
    @AppStorage(PhoneReceiver.enabledKey) private var enabled = true
    var body: some View {
        Form {
            Section {
                Toggle("Recevoir les enregistrements de l’iPhone", isOn: $enabled)
                LabeledContent("État") {
                    switch receiver.status {
                    case .off: Text("Désactivé").foregroundStyle(.secondary)
                    case .starting: Text("Démarrage…").foregroundStyle(.secondary)
                    case .listening: Label("Visible par l’iPhone", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                LabeledContent("Télécommande") { PhoneRemoteStatus(remote: receiver.remote) }
                if let event = receiver.lastEvent { LabeledContent("Dernière réception", value: event) }
            } footer: {
                Text("L’app CoursLocal de l’iPhone trouve ce Mac sur le même Wi-Fi, ou directement à proximité comme AirDrop. CoursLocal doit être ouvert sur le Mac pendant l’envoi. Chaque enregistrement reçu devient un cours, traité automatiquement si l’option est activée dans Général. Quand l’app iPhone est ouverte (ou en veille joignable), tu peux démarrer, mettre en pause et terminer l’enregistrement de l’iPhone depuis ce Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Code d’appairage") {
                    Text(receiver.code.prefix(3) + " " + receiver.code.suffix(3))
                        .font(.system(.title, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                }
                Button("Générer un nouveau code") { receiver.regenerateCode() }
            } footer: {
                Text("Saisis ce code une seule fois dans l’app iPhone. Seuls les appareils qui le connaissent peuvent envoyer de l’audio à ce Mac. Un nouveau code oblige l’iPhone à le saisir de nouveau.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: enabled) { _, on in receiver.setEnabled(on) }
    }
}

private struct PhoneRemoteStatus: View {
    @ObservedObject var remote: PhoneRemote
    var body: some View {
        if remote.connected, let device = remote.device {
            Label("\(device) connecté", systemImage: "iphone.gen3").foregroundStyle(.green)
        } else {
            Text("Aucun iPhone connecté — ouvre CoursLocal sur l’iPhone").foregroundStyle(.secondary)
        }
    }
}
