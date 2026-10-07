import Foundation
import Network
import UIKit
import Combine

/// Finds CoursLocal on the Mac (Bonjour, same Wi-Fi or peer-to-peer) and sends finished recordings to it.
@MainActor
final class MacLink: ObservableObject {
    struct Mac: Identifiable, Equatable { var id: String { name }; let name: String; let endpoint: NWEndpoint }
    @Published private(set) var macs: [Mac] = []
    @Published private(set) var sendingID: UUID?
    @Published private(set) var progress: Double = 0
    @Published private(set) var browserProblem: String?
    @Published var error: String?
    @Published var code: String { didSet { UserDefaults.standard.set(code, forKey: "pairingCode") } }
    @Published var autoSend: Bool { didSet { UserDefaults.standard.set(autoSend, forKey: "autoSend") } }
    @Published var deleteAfterSend: Bool { didSet { UserDefaults.standard.set(deleteAfterSend, forKey: "deleteAfterSend") } }
    @Published var preferredMac: String? { didSet { UserDefaults.standard.set(preferredMac, forKey: "preferredMac") } }
    private let library: RecordingLibrary
    private var browser: NWBrowser?
    private var queue: Task<Void, Never>?
    /// Recordings that failed during this launch are not retried automatically, only by hand.
    private var failed: Set<UUID> = []

    init(library: RecordingLibrary) {
        self.library = library
        let d = UserDefaults.standard
        code = d.string(forKey: "pairingCode") ?? ""
        autoSend = d.object(forKey: "autoSend") as? Bool ?? true
        deleteAfterSend = d.bool(forKey: "deleteAfterSend")
        preferredMac = d.string(forKey: "preferredMac")
    }
    var target: Mac? { macs.first { $0.name == preferredMac } ?? macs.first }
    var paired: Bool { PhoneTransfer.isValidCode(code) }

    func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: PhoneTransfer.serviceType, domain: nil), using: PhoneTransfer.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Mac? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return Mac(name: name, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in
                guard let self else { return }
                self.macs = found
                if self.autoSend { self.sendPending() }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: self.browserProblem = nil
                case .waiting(let error), .failed(let error):
                    // Usually the local network permission, refused or not yet granted.
                    self.browserProblem = "Réseau local indisponible (\(error.localizedDescription)). Vérifie Réglages → CoursLocal → Réseau local."
                    if case .failed = state { self.browser = nil }
                default: break
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }
    func stopBrowsing() {
        guard queue == nil else { return } // Never stop discovery under a running transfer.
        browser?.cancel(); browser = nil; macs = []
    }

    /// Sends every finished recording, oldest first, one at a time. `force` also retries earlier failures.
    func sendPending(force: Bool = false) {
        guard queue == nil, paired, target != nil else { return }
        if force { failed = [] }
        let ids = library.pending.map(\.id).filter { !failed.contains($0) }
        guard !ids.isEmpty else { return }
        run(ids)
    }
    /// Explicit request from the interface: also retries recordings that failed earlier.
    func send(_ id: UUID) {
        guard queue == nil else { return }
        guard paired else { error = "Saisis d’abord le code d’appairage affiché sur le Mac (CoursLocal → Réglages → iPhone)."; return }
        guard target != nil else { error = "Aucun Mac trouvé. Ouvre CoursLocal sur le Mac, sur le même Wi-Fi ou à proximité."; return }
        failed.remove(id); run([id])
    }

    private func run(_ ids: [UUID]) {
        let background = UIApplication.shared.beginBackgroundTask(withName: "Envoi au Mac") { [weak self] in
            Task { @MainActor in self?.queue?.cancel() }
        }
        queue = Task {
            defer { queue = nil; sendingID = nil; progress = 0; UIApplication.shared.endBackgroundTask(background) }
            for id in ids {
                guard !Task.isCancelled, let recording = library.recording(id), recording.state == .ready, let mac = target else { return }
                sendingID = id; progress = 0
                do {
                    try await transfer(recording, to: mac)
                    if deleteAfterSend { try? library.delete(id) }
                    else { try library.update(id) { $0.state = .sent; $0.sentAt = Date(); $0.sentTo = mac.name } }
                } catch PhoneTransfer.Failure.pairing(let message) {
                    code = ""; error = message; return
                } catch {
                    failed.insert(id)
                    if !Task.isCancelled { self.error = "Envoi de « \(recording.displayTitle) » impossible : \(error.localizedDescription)" }
                    return
                }
            }
        }
    }
    private func transfer(_ recording: MobileRecording, to mac: Mac) async throws {
        let files = library.files(recording)
        let parts = try zip(recording.parts, files).map { part, url in
            PhoneTransfer.Part(name: part.name, duration: part.duration, size: Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
        }
        let header = PhoneTransfer.Recording(id: recording.id, title: recording.title, createdAt: recording.createdAt, parts: parts)
        let link = FramedConnection(NWConnection(to: mac.endpoint, using: PhoneTransfer.parameters()))
        defer { link.cancel() }
        let code = code, device = UIDevice.current.name
        _ = try await withTaskCancellationHandler {
            try await link.open()
            return try await PhoneTransferClient.send(header, files: files, code: code, device: device, over: link) { [weak self] value in
                Task { @MainActor in self?.progress = value }
            }
        } onCancel: { link.cancel() }
    }
}
