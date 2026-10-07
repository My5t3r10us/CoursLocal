import SwiftUI

func clock(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.isFinite ? seconds : 0))
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60)
}

@MainActor
struct MobileContentView: View {
    @ObservedObject var library: RecordingLibrary
    @ObservedObject var recorder: MobileRecorder
    @ObservedObject var link: MacLink
    @ObservedObject var remote: MacRemote
    @State private var title = ""
    @State private var settings = false
    @State private var confirmStop = false
    @State private var renaming: MobileRecording?
    @State private var newTitle = ""
    @State private var pendingDelete: MobileRecording?
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section { recorderCard }
                Section { MacStatusRow(link: link, remote: remote, pending: library.pending.count, openSettings: { settings = true }) }
                Section("Enregistrements") {
                    if library.recordings.filter({ $0.state != .recording }).isEmpty {
                        Text("Tes cours enregistrés apparaîtront ici, puis partiront vers le Mac.").foregroundStyle(.secondary).font(.callout)
                    }
                    ForEach(library.recordings.filter { $0.state != .recording }) { recording in
                        RecordingRow(recording: recording, sending: link.sendingID == recording.id, progress: link.progress)
                            .swipeActions {
                                Button("Supprimer", role: .destructive) { pendingDelete = recording }
                            }
                            .contextMenu {
                                Button { link.send(recording.id) } label: { Label(recording.state == .sent ? "Renvoyer au Mac" : "Envoyer au Mac", systemImage: "laptopcomputer.and.arrow.down") }
                                    .disabled(link.sendingID != nil)
                                Button { newTitle = recording.title; renaming = recording } label: { Label("Renommer", systemImage: "pencil") }
                                Button(role: .destructive) { pendingDelete = recording } label: { Label("Supprimer", systemImage: "trash") }
                            }
                    }
                }
            }
            .navigationTitle("CoursLocal")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Réglages")
                }
            }
            .sheet(isPresented: $settings) { MobileSettingsView(link: link, library: library, recorder: recorder) }
            .alert("Renommer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Titre du cours", text: $newTitle)
                Button("Annuler", role: .cancel) {}
                Button("Renommer") {
                    if let id = renaming?.id { try? library.update(id) { $0.title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines) } }
                }
            } message: { Text("Le nouveau titre sera utilisé lors de l’envoi au Mac.") }
            .confirmationDialog("Supprimer « \(pendingDelete?.displayTitle ?? "") » ?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible, presenting: pendingDelete) { recording in
                Button("Supprimer l’audio de l’iPhone", role: .destructive) { try? library.delete(recording.id) }
            } message: { recording in
                Text(recording.state == .sent ? "Le cours reste sur le Mac." : "Cet enregistrement n’a pas encore été envoyé au Mac : il sera définitivement perdu.")
            }
            .alert("CoursLocal", isPresented: Binding(get: { recorder.error != nil || link.error != nil }, set: { if !$0 { recorder.error = nil; link.error = nil } })) {
                Button("OK") { recorder.error = nil; link.error = nil }
            } message: { Text(recorder.error ?? link.error ?? "") }
        }
    }

    @ViewBuilder private var recorderCard: some View {
        if let recording = recorder.recording {
            VStack(spacing: 14) {
                Text(recording.displayTitle).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                Text(clock(recorder.elapsed)).font(.system(size: 56, weight: .light, design: .rounded)).monospacedDigit()
                LevelBar(level: recorder.level).frame(height: 6).opacity(recorder.paused ? 0.3 : 1)
                Text(recorder.notice ?? (recorder.paused ? "En pause — rien n’est enregistré" : remote.connectedTo != nil ? "Enregistrement en cours · suivi depuis le Mac" : "Enregistrement en cours · écran verrouillable"))
                    .font(.footnote).foregroundStyle(recorder.notice == nil ? .secondary : Color.orange).multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    Button { recorder.paused ? recorder.resume() : recorder.pause() } label: {
                        Label(recorder.paused ? "Reprendre" : "Pause", systemImage: recorder.paused ? "play.fill" : "pause.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).controlSize(.large)
                    Button(role: .destructive) { confirmStop = true } label: {
                        Label("Terminer", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                }
            }
            .padding(.vertical, 8)
            .confirmationDialog("Terminer l’enregistrement ?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Terminer et envoyer au Mac") { Task { await recorder.stop() } }
            } message: { Text("Un enregistrement terminé ne peut plus être prolongé.") }
        } else {
            VStack(spacing: 18) {
                TextField("Titre du cours (facultatif)", text: $title)
                    .textFieldStyle(.roundedBorder).submitLabel(.done).focused($titleFocused)
                Button {
                    titleFocused = false
                    let value = title
                    Task { await recorder.start(title: value); if recorder.recording != nil { title = "" } }
                } label: {
                    ZStack {
                        Circle().fill(.red).frame(width: 96, height: 96).shadow(color: .red.opacity(0.35), radius: 12, y: 4)
                        Image(systemName: "mic.fill").font(.system(size: 38, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain).accessibilityLabel("Enregistrer")
                Text("Pose l’iPhone près de l’enseignant. Tu peux verrouiller l’écran.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
    }
}

private struct LevelBar: View {
    let level: Double
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level > 0.9 ? Color.orange : Color.green).frame(width: proxy.size.width * level)
            }
        }
        .animation(.linear(duration: 0.2), value: level)
    }
}

private struct MacStatusRow: View {
    @ObservedObject var link: MacLink
    @ObservedObject var remote: MacRemote
    let pending: Int
    let openSettings: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: link.target == nil ? "laptopcomputer.slash" : "laptopcomputer")
                .font(.title2).foregroundStyle(link.target == nil ? Color.secondary : Color.accentColor).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                if let mac = link.target {
                    Text(mac.name).font(.headline).lineLimit(1)
                    if !link.paired {
                        Text("Code d’appairage requis").font(.footnote).foregroundStyle(.orange)
                    } else if link.sendingID != nil {
                        Text("Envoi en cours… \(link.progress.formatted(.percent.precision(.fractionLength(0))))").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text(pending == 0 ? "Tout est envoyé" : "\(pending) à envoyer").font(.footnote).foregroundStyle(.secondary)
                    }
                    if remote.connectedTo != nil {
                        Label("Contrôlable depuis le Mac", systemImage: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(.green)
                    }
                } else {
                    Text("Recherche du Mac…").font(.headline)
                    Text(link.browserProblem ?? "Ouvre CoursLocal sur le Mac, sur le même Wi-Fi ou à proximité.")
                        .font(.footnote).foregroundStyle(link.browserProblem == nil ? Color.secondary : Color.orange)
                }
            }
            Spacer(minLength: 8)
            if link.target != nil && !link.paired {
                Button("Saisir", action: openSettings).buttonStyle(.borderedProminent)
            } else if link.target != nil && pending > 0 && link.sendingID == nil {
                Button("Envoyer") { link.sendPending(force: true) }.buttonStyle(.borderedProminent)
            } else if link.sendingID != nil {
                ProgressView()
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RecordingRow: View {
    let recording: MobileRecording
    let sending: Bool
    let progress: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(recording.displayTitle).font(.body.weight(.medium)).lineLimit(2)
                Spacer()
                Text(clock(recording.duration)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                if sending {
                    Text("Envoi \(progress.formatted(.percent.precision(.fractionLength(0))))").foregroundStyle(.tint)
                } else if recording.state == .sent {
                    Label("Sur le Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("À envoyer", systemImage: "arrow.up.circle").foregroundStyle(.orange)
                }
            }
            .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            if sending { ProgressView(value: progress) }
            if let note = recording.note { Text(note).font(.caption).foregroundStyle(.orange) }
        }
        .padding(.vertical, 2)
    }
}

@MainActor
struct MobileSettingsView: View {
    @ObservedObject var link: MacLink
    @ObservedObject var library: RecordingLibrary
    @ObservedObject var recorder: MobileRecorder
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("123456", text: $code)
                        .keyboardType(.numberPad).font(.system(.title2, design: .monospaced))
                        .onChange(of: code) { _, value in
                            let digits = String(value.filter(\.isNumber).prefix(6))
                            if digits != value { code = digits }
                            if PhoneTransfer.isValidCode(digits) && digits != link.code { link.code = digits; if link.autoSend { link.sendPending(force: true) } }
                        }
                } header: { Text("Code d’appairage") } footer: {
                    Text("Affiché sur le Mac dans CoursLocal → Réglages → iPhone. Il n’est demandé qu’une fois.")
                }
                Section {
                    if link.macs.count > 1 {
                        Picker("Mac", selection: Binding(get: { link.target?.name ?? "" }, set: { link.preferredMac = $0 })) {
                            ForEach(link.macs) { Text($0.name).tag($0.name) }
                        }
                    } else {
                        LabeledContent("Mac", value: link.target?.name ?? "Aucun trouvé")
                    }
                    Toggle("Envoyer automatiquement", isOn: $link.autoSend)
                    Toggle("Supprimer de l’iPhone après l’envoi", isOn: $link.deleteAfterSend)
                } header: { Text("Envoi") } footer: {
                    Text("L’envoi part dès que le Mac est visible, app ouverte. Le Mac ne confirme qu’après avoir enregistré et vérifié l’audio.")
                }
                Section {
                    Toggle("Rester joignable en arrière-plan", isOn: $recorder.keepAlive)
                } header: { Text("Contrôle depuis le Mac") } footer: {
                    Text("App ouverte ou pendant un enregistrement, le Mac peut toujours démarrer, mettre en pause et terminer l’enregistrement. iOS n’ouvre pas le micro d’une app en arrière-plan : avec cette option, le micro reste ouvert (point orange) sans rien enregistrer, pour que le Mac puisse démarrer un cours iPhone verrouillé. Consomme un peu de batterie.")
                }
                Section {
                    LabeledContent("Espace utilisé", value: ByteCountFormatter.string(fromByteCount: library.storageUsed, countStyle: .file))
                } header: { Text("Stockage") } footer: {
                    Text("Environ 115 Mo par heure. Les fichiers WAV sont aussi accessibles dans l’app Fichiers et dans le Finder, iPhone branché.")
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .onAppear { code = link.code }
        }
    }
}
