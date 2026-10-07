import Foundation
import Combine
import Network
import AVFoundation

/// Received iPhone recordings, kept on disk until they become courses.
/// A recording is written to `<id>.partial`, checked, then renamed: a folder named `<id>` is always complete.
struct PhoneInbox: Sendable {
    enum Outcome: Equatable { case received(PhoneTransfer.Recording), duplicate }
    let folder: URL
    private var receivedList: URL { folder.appendingPathComponent("received.json") }

    func prepare() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "partial" {
            try? FileManager.default.removeItem(at: url)
        }
    }
    /// Complete recordings waiting to become courses, oldest first.
    func pending() -> [(folder: URL, recording: PhoneTransfer.Recording)] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { url in
            guard url.pathExtension.isEmpty, let data = try? Data(contentsOf: url.appendingPathComponent("recording.json")),
                  let recording = try? JSONDecoder().decode(PhoneTransfer.Recording.self, from: data) else { return nil }
            return (url, recording)
        }.sorted { $0.recording.createdAt < $1.recording.createdAt }
    }
    private func received() -> Set<UUID> {
        guard let data = try? Data(contentsOf: receivedList) else { return [] }
        return Set((try? JSONDecoder().decode([UUID].self, from: data)) ?? [])
    }
    /// Remembers an integrated recording so that a resend after a lost reply is not imported twice.
    func markIntegrated(_ id: UUID) throws {
        var ids = received(); ids.insert(id)
        try JSONEncoder().encode(ids.sorted { $0.uuidString < $1.uuidString }).write(to: receivedList, options: .atomic)
    }
    func isKnown(_ id: UUID) -> Bool {
        received().contains(id) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(id.uuidString).path)
    }

    /// Receives one recording after an accepted Hello. Nothing is acknowledged before it is durably stored and readable.
    func receive(over link: FramedConnection, hello: PhoneTransfer.Hello, progress: @escaping @Sendable (String, Double) -> Void) async throws -> Outcome {
        var recording = try await link.receiveMessage(PhoneTransfer.Recording.self)
        recording.device = String(hello.device.prefix(80))
        recording.title = String(recording.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard (1...PhoneTransfer.maxParts).contains(recording.parts.count),
              recording.parts.allSatisfy({ (1...PhoneTransfer.maxPartBytes).contains($0.size) && $0.duration.isFinite && $0.duration >= 0 }) else {
            try await link.sendMessage(PhoneTransfer.Reply.refused("Enregistrement invalide ou trop volumineux."))
            throw PhoneTransfer.Failure.message("Enregistrement iPhone refusé : en-tête invalide.")
        }
        if isKnown(recording.id) {
            try await link.sendMessage(PhoneTransfer.Reply(ok: true, duplicate: true)); return .duplicate
        }
        let partial = folder.appendingPathComponent(recording.id.uuidString + ".partial", isDirectory: true)
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: partial) } }
        try await link.sendMessage(PhoneTransfer.Reply.accepted)

        let total = Double(recording.parts.reduce(0) { $0 + $1.size }); var done: Int64 = 0
        let label = recording.title.isEmpty ? "Enregistrement iPhone" : recording.title
        for index in recording.parts.indices {
            let ext = ["wav", "m4a", "caf"].contains((recording.parts[index].name as NSString).pathExtension.lowercased()) ? (recording.parts[index].name as NSString).pathExtension.lowercased() : "wav"
            let name = String(format: "part-%03d.%@", index, ext)
            let url = partial.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw PhoneTransfer.Failure.message("Impossible d’écrire l’audio reçu.") }
            let handle = try FileHandle(forWritingTo: url)
            do {
                var remaining = recording.parts[index].size
                while remaining > 0 {
                    try Task.checkCancellation()
                    let data = try await link.receive(max: Int(min(Int64(PhoneTransfer.chunk), remaining)))
                    try handle.write(contentsOf: data)
                    remaining -= Int64(data.count); done += Int64(data.count)
                    progress(label, Double(done) / total)
                }
                try handle.synchronize(); try handle.close()
            } catch { try? handle.close(); throw error }
            do {
                let audio = try AVAudioFile(forReading: url)
                guard audio.length > 0, audio.processingFormat.sampleRate > 0 else { throw PhoneTransfer.Failure.message("segment vide") }
                recording.parts[index].name = name
                recording.parts[index].duration = Double(audio.length) / audio.processingFormat.sampleRate
            } catch {
                try await link.sendMessage(PhoneTransfer.Reply.refused("Le segment \(index + 1) est illisible sur le Mac (\(error.localizedDescription))."))
                throw PhoneTransfer.Failure.message("Enregistrement iPhone refusé : segment \(index + 1) illisible.")
            }
        }
        try JSONEncoder().encode(recording).write(to: partial.appendingPathComponent("recording.json"), options: .atomic)
        try FileManager.default.moveItem(at: partial, to: folder.appendingPathComponent(recording.id.uuidString, isDirectory: true))
        complete = true
        try await link.sendMessage(PhoneTransfer.Reply.accepted)
        return .received(recording)
    }
}

/// Listens for the iPhone app on the local network and turns received recordings into courses.
@MainActor
final class PhoneReceiver: ObservableObject {
    enum Status: Equatable { case off, starting, listening, failed(String) }
    struct Activity: Equatable { var title: String; var fraction: Double }
    @Published private(set) var status: Status = .off
    @Published private(set) var activity: Activity?
    @Published private(set) var code: String
    @Published private(set) var lastEvent: String?
    /// The iPhone currently connected for remote control, if any.
    let remote = PhoneRemote()
    /// Called for every recording that became a course, to start processing as after a Mac recording.
    var onImported: ((UUID) -> Void)?
    let inbox: PhoneInbox
    private let store: CourseStore
    private let advertise: Bool
    private var listener: NWListener?
    private var transfer: Task<Void, Never>?
    private var handshakes = 0
    private var observers: Set<AnyCancellable> = []
    private var integrating = false
    private var failedIDs: Set<UUID> = []
    private var wrongCodes = 0
    private var lockedUntil = Date.distantPast
    static let codeKey = "phonePairingCode"
    static let enabledKey = "phoneReceiver"

    init(store: CourseStore, inbox: URL? = nil, advertise: Bool = true) {
        self.store = store; self.advertise = advertise
        self.inbox = PhoneInbox(folder: inbox ?? store.root.deletingLastPathComponent().appendingPathComponent("CoursLocal-iPhone", isDirectory: true))
        if let saved = UserDefaults.standard.string(forKey: Self.codeKey), PhoneTransfer.isValidCode(saved) { code = saved }
        else { code = PhoneTransfer.newCode(); UserDefaults.standard.set(code, forKey: Self.codeKey) }
        try? self.inbox.prepare()
        // A received recording waits for the library and for any recording, import or processing to finish.
        store.gate.$operation.combineLatest(store.$ready).receive(on: RunLoop.main)
            .sink { [weak self] operation, ready in if operation == nil && ready { Task { await self?.integratePending() } } }
            .store(in: &observers)
    }
    var port: NWEndpoint.Port? { listener?.port }

    func setEnabled(_ enabled: Bool) { enabled ? start() : stop() }
    func start(port: NWEndpoint.Port = .any) {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: PhoneTransfer.parameters(), on: port)
            if advertise { listener.service = NWListener.Service(type: PhoneTransfer.serviceType) } // Named after the Mac.
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready: self.status = .listening
                    case .failed(let error): self.status = .failed(error.localizedDescription); self.listener = nil; listener.cancel()
                    case .waiting(let error): self.status = .failed(error.localizedDescription)
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
            self.listener = listener; status = .starting
            listener.start(queue: .main)
        } catch { status = .failed(error.localizedDescription) }
    }
    func stop() {
        listener?.cancel(); listener = nil; transfer?.cancel(); remote.detach(); status = .off
    }
    func regenerateCode() {
        code = PhoneTransfer.newCode(); UserDefaults.standard.set(code, forKey: Self.codeKey)
    }

    private func accept(_ connection: NWConnection) {
        // Few simultaneous handshakes, and repeated wrong codes pause the receiver for a minute.
        guard listener != nil, handshakes < 4, Date() >= lockedUntil else { connection.cancel(); return }
        handshakes += 1
        let link = FramedConnection(connection)
        Task { [weak self] in
            var hello: PhoneTransfer.Hello?
            do {
                try await link.open()
                hello = try await link.receiveMessage(PhoneTransfer.Hello.self, timeout: 10)
            } catch {}
            guard let self else { link.cancel(); return }
            self.handshakes -= 1
            guard let hello, await self.authenticate(hello, link) else { link.cancel(); return }
            switch hello.mode ?? .transfer {
            case .control: self.remote.attach(link, device: String(hello.device.prefix(80)))
            case .transfer: self.receive(hello, over: link)
            }
        }
    }
    /// Answers the Hello. Only a known code and protocol version are accepted.
    private func authenticate(_ hello: PhoneTransfer.Hello, _ link: FramedConnection) async -> Bool {
        guard hello.version == PhoneTransfer.version else {
            try? await link.sendMessage(PhoneTransfer.Reply.refused("Versions incompatibles : mets à jour CoursLocal sur l’iPhone et sur le Mac."))
            report("Un iPhone utilise une autre version de CoursLocal."); return false
        }
        guard PhoneTransfer.sameCode(hello.code, code) else {
            wrongCodes += 1
            if wrongCodes >= 5 { wrongCodes = 0; lockedUntil = Date().addingTimeInterval(60) }
            report("Un appareil a envoyé un code d’appairage incorrect.")
            try? await Task.sleep(for: .seconds(1)) // Slows down guessing.
            try? await link.sendMessage(PhoneTransfer.Reply.refused("Code d’appairage incorrect. Il est affiché sur le Mac dans CoursLocal → Réglages → iPhone."))
            return false
        }
        wrongCodes = 0
        do { try await link.sendMessage(PhoneTransfer.Reply.accepted); return true } catch { return false }
    }
    private func receive(_ hello: PhoneTransfer.Hello, over link: FramedConnection) {
        guard transfer == nil else {
            Task { try? await link.sendMessage(PhoneTransfer.Reply.refused("Un autre envoi est en cours vers ce Mac. Réessaie dans un instant.")); link.cancel() }
            return
        }
        let inbox = inbox
        transfer = Task { [weak self] in
            defer { link.cancel(); self?.transfer = nil; self?.activity = nil }
            do {
                let outcome = try await withTaskCancellationHandler {
                    try await inbox.receive(over: link, hello: hello) { title, fraction in
                        Task { @MainActor in self?.activity = Activity(title: title, fraction: fraction) }
                    }
                } onCancel: { link.cancel() }
                await self?.finished(outcome)
            } catch {
                self?.report("Réception interrompue : \(error.localizedDescription)")
            }
        }
    }
    private func finished(_ outcome: PhoneInbox.Outcome) async {
        switch outcome {
        case .duplicate: report("Enregistrement déjà reçu.")
        case .received(let recording):
            report("Reçu de \(recording.device ?? "l’iPhone") : \(recording.title.isEmpty ? "enregistrement sans titre" : recording.title)")
            await integratePending()
        }
    }
    private func report(_ text: String) { lastEvent = text }

    /// Creates a course for each received recording, one at a time, under the operation gate.
    func integratePending() async {
        guard !integrating, store.ready, !store.gate.busy else { return }
        integrating = true; defer { integrating = false }
        for (folder, recording) in inbox.pending() where !failedIDs.contains(recording.id) {
            guard (try? store.gate.acquire("Réception iPhone")) != nil else { return }
            var created: UUID?
            do {
                let title = recording.title.isEmpty ? "Cours du \(recording.createdAt.formatted(date: .abbreviated, time: .shortened))" : recording.title
                let id = try await store.create(title: title); created = id
                var parts: [AudioPart] = []
                for part in recording.parts {
                    let local = AudioPart(filename: "\(UUID().uuidString).\((part.name as NSString).pathExtension)", duration: part.duration)
                    try FileManager.default.copyItem(at: folder.appendingPathComponent(part.name), to: store.folder(id).appendingPathComponent(local.filename))
                    parts.append(local)
                }
                let device = recording.device ?? "l’iPhone", date = recording.createdAt
                try await store.update(id) { c in
                    c.parts = parts; c.createdAt = date; c.captureMode = .microphone
                    c.state = .audioReady; c.status = "Audio reçu de \(device)"
                }
                try inbox.markIntegrated(recording.id)
                try? FileManager.default.removeItem(at: folder)
                store.gate.release()
                onImported?(id)
            } catch {
                failedIDs.insert(recording.id) // Kept in the inbox; retried at next launch.
                store.gate.release()
                if let created { try? await store.delete(created) }
                store.error = "Impossible d’ajouter l’enregistrement reçu de l’iPhone : \(error.localizedDescription). Il reste dans la file de réception."
                return
            }
            // Processing of the new course now holds the gate: the next recording waits for it.
            if store.gate.busy { return }
        }
    }
}

/// Live view and remote control of the iPhone recorder, over the control connection the iPhone keeps open.
@MainActor
final class PhoneRemote: ObservableObject {
    @Published private(set) var device: String?
    @Published private(set) var connected = false
    /// Last state received. Kept after a disconnection during a recording, which goes on on the iPhone.
    @Published private(set) var status: PhoneTransfer.Status?
    @Published private(set) var lastSeen: Date?
    /// Errors reported by the iPhone for a command sent from this Mac.
    var onError: ((String) -> Void)?
    private var link: FramedConnection?
    private var session: Task<Void, Never>?
    private var reportedError: UUID?

    var recording: Bool { status.map { $0.state != .idle } ?? false }

    func attach(_ link: FramedConnection, device: String) {
        session?.cancel(); self.link?.cancel()
        self.link = link; self.device = device; connected = true; lastSeen = Date()
        session = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { // The iPhone sends its state at least every two seconds.
                    while true {
                        guard let status = try? await link.receiveMessage(PhoneTransfer.Status.self, timeout: 8) else { return }
                        await self?.received(status, from: link)
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        guard (try? await link.sendMessage(PhoneTransfer.Command(action: .ping))) != nil else { return }
                        try? await Task.sleep(for: .seconds(3))
                    }
                }
                await group.next(); group.cancelAll(); link.cancel()
            }
            self?.lost(link)
        }
    }
    func detach() {
        session?.cancel(); link?.cancel(); link = nil; connected = false; status = nil; device = nil
    }
    func dismiss() { guard !connected else { return }; status = nil; device = nil }

    func send(_ action: PhoneTransfer.Command.Action, title: String? = nil) {
        guard let link, connected else { onError?("L’iPhone n’est plus connecté. Ouvre CoursLocal sur l’iPhone."); return }
        Task { [weak self] in
            do { try await link.sendMessage(PhoneTransfer.Command(action: action, title: title)) }
            catch { self?.onError?("Commande non transmise à l’iPhone : \(error.localizedDescription)") }
        }
    }
    private func received(_ status: PhoneTransfer.Status, from link: FramedConnection) {
        guard link === self.link else { return }
        self.status = status; lastSeen = Date()
        if let id = status.errorID, id != reportedError, let message = status.error {
            reportedError = id; onError?("iPhone : \(message)")
        }
    }
    private func lost(_ link: FramedConnection) {
        guard link === self.link else { return }
        self.link = nil; connected = false
        // An idle iPhone that went away simply disappears; a recording one stays visible, marked as unreachable.
        if !recording { status = nil; device = nil }
    }
}
