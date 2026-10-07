import SwiftUI

/// Shown above the course while the iPhone records, with the same controls as on the iPhone.
struct PhoneRecordingBanner: View {
    @ObservedObject var remote: PhoneRemote
    @State private var confirmStop = false
    var body: some View {
        if let status = remote.status, status.state != .idle {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(.red.opacity(0.15)).frame(width: 36, height: 36)
                    Image(systemName: status.state == .paused ? "pause.fill" : "iphone.gen3.radiowaves.left.and.right").font(.system(size: 17)).foregroundStyle(.red)
                        .symbolEffect(.pulse, isActive: status.state == .recording && remote.connected)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.state == .paused ? "iPhone en pause" : "L’iPhone enregistre").font(.headline)
                    Text(subtitle(status)).font(.caption).foregroundStyle(remote.connected && status.notice == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange)).lineLimit(1)
                }
                Text(timestamp(status.elapsed)).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit().padding(.leading, 8)
                LevelMeter(label: "Micro", value: remote.connected && status.state == .recording ? status.level : 0).padding(.leading, 8)
                Spacer()
                Button { remote.send(status.state == .paused ? .resume : .pause) } label: {
                    Label(status.state == .paused ? "Reprendre" : "Pause", systemImage: status.state == .paused ? "play.fill" : "pause.fill")
                }.controlSize(.large).disabled(!remote.connected)
                Button { confirmStop = true } label: { Label("Terminer", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large).disabled(!remote.connected)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(LinearGradient(colors: [.red.opacity(0.12), .red.opacity(0.03)], startPoint: .leading, endPoint: .trailing))
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .confirmationDialog("Terminer l’enregistrement sur l’iPhone ?", isPresented: $confirmStop) {
                Button("Terminer et envoyer au Mac") { remote.send(.stop) }
            } message: { Text("L’iPhone envoie ensuite l’audio à ce Mac, qui le traite comme un cours enregistré ici.") }
        }
    }
    private func subtitle(_ status: PhoneTransfer.Status) -> String {
        if !remote.connected { return "Connexion perdue — l’enregistrement continue sur l’iPhone" }
        let title = status.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Cours sans titre"
        return [remote.device, title, status.notice].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Sidebar card: the connected iPhone, its state and a button to start recording on it.
struct PhoneRemoteCard: View {
    @ObservedObject var remote: PhoneRemote
    let start: () -> Void
    var body: some View {
        if let device = remote.device {
            let status = remote.status
            HStack(spacing: 10) {
                Image(systemName: "iphone.gen3").font(.title3)
                    .foregroundStyle(!remote.connected ? AnyShapeStyle(.tertiary) : status?.state == .idle || status == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.red))
                VStack(alignment: .leading, spacing: 1) {
                    Text(device).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(detail(status)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if remote.connected && (status?.state ?? .idle) == .idle {
                    Button(action: start) { Image(systemName: "record.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.red).help("Démarrer l’enregistrement sur l’iPhone")
                } else if !remote.connected {
                    Button { remote.dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Masquer")
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 10).padding(.top, 10)
        }
    }
    private func detail(_ status: PhoneTransfer.Status?) -> String {
        guard remote.connected else { return "Hors de portée — l’enregistrement continue" }
        guard let status else { return "Connecté" }
        switch status.state {
        case .recording: return "Enregistre · \(timestamp(status.elapsed))"
        case .paused: return "En pause · \(timestamp(status.elapsed))"
        case .idle:
            if let sending = status.sending { return "Envoi au Mac · \(sending.formatted(.percent.precision(.fractionLength(0))))" }
            return status.pending > 0 ? "Prêt · \(status.pending) à envoyer" : "Prêt à enregistrer"
        }
    }
}

struct PhoneStartSheet: View {
    @ObservedObject var remote: PhoneRemote
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Enregistrer sur \(remote.device ?? "l’iPhone")", systemImage: "iphone.gen3.radiowaves.left.and.right").font(.title3.weight(.semibold))
            TextField("Titre du cours (facultatif)", text: $title).textFieldStyle(.roundedBorder).onSubmit(start)
            Text("L’iPhone enregistre avec son micro, même écran verrouillé. Tu suis et contrôles l’enregistrement depuis ce Mac ; à la fin, l’audio est envoyé ici et traité comme un cours enregistré sur le Mac.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer", action: start).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.red)
                    .disabled(!remote.connected || remote.recording)
            }
        }
        .padding(20).frame(width: 440)
    }
    private func start() {
        guard remote.connected, !remote.recording else { return }
        remote.send(.start, title: title.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss()
    }
}
