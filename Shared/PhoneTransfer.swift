import Foundation
import Network

/// Wire format shared by the iPhone recorder and the Mac app, over TCP on the local network (Wi-Fi or peer-to-peer).
/// Every message is a 4-byte big-endian length followed by JSON. Audio bytes follow the recording header, raw.
///
///     iPhone → Mac  Hello          Mac → iPhone  Reply (code checked)
///     iPhone → Mac  Recording      Mac → iPhone  Reply (accepted, or already received)
///     iPhone → Mac  part bytes…    Mac → iPhone  Reply (files durably stored and readable)
///
/// A control connection starts with a Hello in `.control` mode and stays open: the iPhone sends its Status
/// at least every two seconds, the Mac sends Commands (and a ping every three seconds).
enum PhoneTransfer {
    static let serviceType = "_courslocal._tcp"
    static let version = 2
    static let maxMessage = 256 * 1024
    static let maxPartBytes: Int64 = 512 * 1024 * 1024
    static let maxParts = 500
    static let chunk = 1 << 20

    enum Mode: String, Codable, Sendable { case transfer, control }
    struct Hello: Codable, Sendable { var version: Int; var code: String; var device: String; var mode: Mode? = nil }
    /// What the iPhone recorder is doing, as shown live on the Mac.
    struct Status: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable { case idle, recording, paused }
        var state: State = .idle
        var title: String? = nil
        var elapsed: Double = 0
        var level: Double = 0
        var notice: String? = nil
        /// Finished recordings not yet on the Mac, and the progress of the one being sent.
        var pending: Int = 0
        var sending: Double? = nil
        /// Reachable while in the background, microphone kept open.
        var standby: Bool = false
        /// The last command that failed on the iPhone, reported once per identifier.
        var errorID: UUID? = nil
        var error: String? = nil
    }
    struct Command: Codable, Sendable, Equatable {
        enum Action: String, Codable, Sendable { case ping, start, pause, resume, stop }
        var action: Action
        var title: String? = nil
    }
    struct Part: Codable, Sendable, Equatable { var name: String; var duration: Double; var size: Int64 }
    struct Recording: Codable, Sendable, Equatable {
        var id: UUID
        var title: String
        var createdAt: Date
        var parts: [Part]
        var device: String? = nil
    }
    struct Reply: Codable, Sendable {
        var ok: Bool
        var message: String? = nil
        var duplicate: Bool? = nil
        static let accepted = Reply(ok: true)
        static func refused(_ message: String) -> Reply { Reply(ok: false, message: message) }
    }
    enum Failure: LocalizedError {
        case message(String)
        /// The Mac refused the pairing code: the iPhone must ask for it again.
        case pairing(String)
        var errorDescription: String? { switch self { case .message(let text), .pairing(let text): return text } }
    }

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 15; tcp.connectionTimeout = 10; tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true // Works without a shared Wi-Fi, like AirDrop.
        return parameters
    }
    static func isValidCode(_ code: String) -> Bool { code.count == 6 && code.allSatisfy { $0.isASCII && $0.isNumber } }
    static func newCode() -> String { String(format: "%06d", Int.random(in: 0..<1_000_000)) }
    /// Compares without stopping at the first different digit.
    static func sameCode(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Async framing over an NWConnection. Every send and receive has a deadline so a silent peer cannot block forever.
final class FramedConnection: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "fr.baptiste.CoursLocal.transfer")
    private final class Once: @unchecked Sendable { var done = false }

    init(_ connection: NWConnection) { self.connection = connection }

    func open(timeout: TimeInterval = 15) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once() // All handlers run on `queue`.
            @Sendable func finish(_ error: Error?) {
                guard !once.done else { return }; once.done = true
                if let error { connection.cancel(); c.resume(throwing: error) } else { c.resume() }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(nil)
                case .failed(let error), .waiting(let error): finish(error)
                case .cancelled: finish(PhoneTransfer.Failure.message("Connexion annulée."))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(PhoneTransfer.Failure.message("Le Mac ne répond pas.")) }
            connection.start(queue: queue)
        }
    }
    func cancel() { connection.cancel() }

    func send(_ data: Data, timeout: TimeInterval = 30) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            queue.asyncAfter(deadline: .now() + timeout) { if !once.done { self.connection.cancel() } }
            connection.send(content: data, completion: .contentProcessed { error in
                self.queue.async {
                    guard !once.done else { return }; once.done = true
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
            })
        }
    }
    /// Returns between 1 and `max` bytes.
    func receive(max: Int, timeout: TimeInterval = 30) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            let once = Once()
            queue.asyncAfter(deadline: .now() + timeout) { if !once.done { self.connection.cancel() } }
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { content, _, isComplete, error in
                self.queue.async {
                    guard !once.done else { return }; once.done = true
                    if let content, !content.isEmpty { c.resume(returning: content) }
                    else if let error { c.resume(throwing: error) }
                    else { c.resume(throwing: PhoneTransfer.Failure.message(isComplete ? "Connexion fermée par l’autre appareil." : "Connexion interrompue.")) }
                }
            }
        }
    }
    func receive(exactly count: Int, timeout: TimeInterval = 30) async throws -> Data {
        var data = Data(capacity: count)
        while data.count < count { data.append(try await receive(max: count - data.count, timeout: timeout)) }
        return data
    }
    func sendMessage<T: Encodable>(_ value: T) async throws {
        let body = try JSONEncoder().encode(value)
        let length = UInt32(body.count)
        try await send(Data([UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]) + body)
    }
    func receiveMessage<T: Decodable>(_ type: T.Type, timeout: TimeInterval = 30) async throws -> T {
        let header = try await receive(exactly: 4, timeout: timeout)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= PhoneTransfer.maxMessage else { throw PhoneTransfer.Failure.message("Message de transfert invalide.") }
        do { return try JSONDecoder().decode(T.self, from: try await receive(exactly: length, timeout: timeout)) }
        catch is DecodingError { throw PhoneTransfer.Failure.message("Message de transfert illisible.") }
    }
}

enum PhoneTransferClient {
    /// Opens a session; throws `.pairing` when the Mac refuses the code.
    static func handshake(_ link: FramedConnection, code: String, device: String, mode: PhoneTransfer.Mode) async throws {
        try await link.sendMessage(PhoneTransfer.Hello(version: PhoneTransfer.version, code: code, device: device, mode: mode))
        let reply = try await link.receiveMessage(PhoneTransfer.Reply.self)
        guard reply.ok else { throw PhoneTransfer.Failure.pairing(reply.message ?? "Le Mac a refusé la connexion.") }
    }
    /// Sends one recording whose parts are `files`, in order. Returns true when the Mac already had it.
    static func send(_ recording: PhoneTransfer.Recording, files: [URL], code: String, device: String, over link: FramedConnection,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> Bool {
        precondition(files.count == recording.parts.count)
        func check(_ reply: PhoneTransfer.Reply) throws -> PhoneTransfer.Reply {
            guard reply.ok else { throw PhoneTransfer.Failure.message(reply.message ?? "Le Mac a refusé l’enregistrement.") }
            return reply
        }
        try await handshake(link, code: code, device: device, mode: .transfer)
        try await link.sendMessage(recording)
        if try check(await link.receiveMessage(PhoneTransfer.Reply.self)).duplicate == true { progress(1); return true }
        let total = max(1, recording.parts.reduce(0) { $0 + $1.size }); var sent: Int64 = 0
        for (part, url) in zip(recording.parts, files) {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var remaining = part.size
            while remaining > 0 {
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: Int(min(Int64(PhoneTransfer.chunk), remaining))), !data.isEmpty else {
                    throw PhoneTransfer.Failure.message("Le fichier audio a changé pendant l’envoi.")
                }
                try await link.send(data)
                remaining -= Int64(data.count); sent += Int64(data.count)
                progress(Double(sent) / Double(total))
            }
        }
        // The Mac checks every file before answering: allow time for a long recording.
        _ = try check(await link.receiveMessage(PhoneTransfer.Reply.self, timeout: 120))
        return false
    }
}

/// Repairs the sizes in a WAV header left unfinished by an interrupted recording (crash, battery, killed app).
/// The audio bytes are already on disk; only the RIFF and data lengths are missing.
enum WAVRepair {
    @discardableResult
    static func repair(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url); defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 44, fileSize <= UInt64(UInt32.max) else { return false }
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: 64 * 1024) ?? Data()
        guard head.count >= 12, head.prefix(4) == Data("RIFF".utf8), head[8..<12] == Data("WAVE".utf8) else { return false }
        func le32(_ offset: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(head[offset + $1]) << (8 * UInt32($1)) } }
        func bytes(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(value >> (8 * UInt32($0)) & 0xFF) }) }
        var offset = 12, blockAlign: UInt32 = 0
        while offset + 8 <= head.count {
            let id = head[offset..<offset + 4], size = le32(offset + 4)
            if id == Data("fmt ".utf8), offset + 22 <= head.count { blockAlign = UInt32(head[offset + 20]) | UInt32(head[offset + 21]) << 8 }
            if id == Data("data".utf8) {
                let start = UInt64(offset + 8)
                var length = UInt32(fileSize - start)
                if blockAlign > 0 { length -= length % blockAlign } // Drop a partially written frame.
                let riff = UInt32(start - 8) + length
                guard size != length || le32(4) != riff else { return false }
                try handle.seek(toOffset: 4); try handle.write(contentsOf: bytes(riff))
                try handle.seek(toOffset: UInt64(offset + 4)); try handle.write(contentsOf: bytes(length))
                return true
            }
            offset += 8 + Int(size) + Int(size % 2)
        }
        return false
    }
}
