import Foundation
import Network
import UIKit

/// Keeps a control connection open with the Mac while the app runs: sends the recorder state live
/// and runs the Mac's commands (start, pause, resume, stop). Reconnects by itself.
@MainActor
final class MacRemote: ObservableObject {
    /// Name of the Mac currently able to control this iPhone.
    @Published private(set) var connectedTo: String?
    private let link: MacLink
    private let recorder: MobileRecorder
    private let library: RecordingLibrary
    private var loop: Task<Void, Never>?
    private var failure: (id: UUID, message: String)?

    init(link: MacLink, recorder: MobileRecorder, library: RecordingLibrary) {
        self.link = link; self.recorder = recorder; self.library = library
    }
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let mac = self.link.target, self.link.paired {
                    do { try await self.session(with: mac) }
                    catch PhoneTransfer.Failure.pairing(let message) {
                        self.link.code = ""; if self.link.error == nil { self.link.error = message }
                    } catch {}
                    self.connectedTo = nil
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func session(with mac: MacLink.Mac) async throws {
        let connection = FramedConnection(NWConnection(to: mac.endpoint, using: PhoneTransfer.parameters()))
        defer { connection.cancel() }
        let code = link.code, device = UIDevice.current.name
        try await withTaskCancellationHandler {
            try await connection.open()
            try await PhoneTransferClient.handshake(connection, code: code, device: device, mode: .control)
            connectedTo = mac.name
            try await withThrowingTaskGroup(of: Void.self) { group in
                // When either side stops, closing the connection ends the other one at once.
                group.addTask { defer { connection.cancel() }; try await self.publish(over: connection) }
                group.addTask { defer { connection.cancel() }; try await self.listen(over: connection) }
                try await group.next(); group.cancelAll()
            }
        } onCancel: { connection.cancel() }
    }

    /// Sends the state on every change (about five times a second while recording) and at least every two seconds.
    private func publish(over connection: FramedConnection) async throws {
        var last: PhoneTransfer.Status?, sentAt = Date.distantPast
        while true {
            let status = currentStatus()
            if status != last || Date().timeIntervalSince(sentAt) >= 2 {
                try await connection.sendMessage(status); last = status; sentAt = Date()
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
    /// The Mac pings every three seconds: silence means it is gone.
    private func listen(over connection: FramedConnection) async throws {
        while true {
            let command = try await connection.receiveMessage(PhoneTransfer.Command.self, timeout: 10)
            await run(command)
        }
    }
    private func run(_ command: PhoneTransfer.Command) async {
        switch command.action {
        case .ping: break
        case .start:
            guard recorder.recording == nil else { return }
            if !(await recorder.start(title: command.title ?? "")) {
                let reason = recorder.error ?? "Démarrage impossible."
                let background = UIApplication.shared.applicationState != .active && !recorder.keepAlive
                fail(background ? "\(reason) iOS n’ouvre pas le micro d’une app en arrière-plan : ouvre CoursLocal sur l’iPhone ou active « Rester joignable en arrière-plan »." : reason)
            }
        case .pause: recorder.pause()
        case .resume:
            recorder.resume()
            if recorder.paused { fail(recorder.notice ?? "Reprise impossible.") }
        case .stop: await recorder.stop()
        }
    }
    private func fail(_ message: String) { failure = (UUID(), message) }

    private func currentStatus() -> PhoneTransfer.Status {
        let state: PhoneTransfer.Status.State = recorder.recording == nil ? .idle : recorder.paused ? .paused : .recording
        return PhoneTransfer.Status(
            state: state, title: recorder.recording?.displayTitle, elapsed: recorder.elapsed,
            level: (recorder.level * 40).rounded() / 40, notice: recorder.notice,
            pending: library.pending.count, sending: link.sendingID == nil ? nil : link.progress,
            standby: recorder.keepAlive, errorID: failure?.id, error: failure?.message)
    }
}
