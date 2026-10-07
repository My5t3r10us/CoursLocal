import XCTest
import AVFoundation
import Network
@testable import CoursLocal

final class PhoneTransferTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("phone-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// Same format as the iPhone writer: WAV mono 16 kHz 16 bits.
    private func wav(_ name: String, seconds: Double) throws -> URL {
        let url = root.appendingPathComponent(name)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let count = AVAudioFrameCount(seconds * 16000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)); buffer.frameLength = count
        for i in 0..<Int(count) { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.3 }
        try file.write(from: buffer)
        return url
    }
    private func header(_ files: [URL], id: UUID = UUID(), title: String = "Neurosciences") throws -> PhoneTransfer.Recording {
        let parts = try files.map { PhoneTransfer.Part(name: $0.lastPathComponent, duration: 0, size: Int64(try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize!)) }
        return PhoneTransfer.Recording(id: id, title: title, createdAt: Date(timeIntervalSince1970: 1_790_000_000), parts: parts)
    }
    @MainActor private func receiver() async throws -> (CourseStore, PhoneReceiver, NWEndpoint.Port) {
        let store = CourseStore(root: root.appendingPathComponent("library")); while !store.ready { try await Task.sleep(for: .milliseconds(10)) }
        let receiver = PhoneReceiver(store: store, inbox: root.appendingPathComponent("inbox"), advertise: false)
        receiver.start()
        let deadline = Date().addingTimeInterval(5)
        while receiver.status != .listening, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return (store, receiver, try XCTUnwrap(receiver.port))
    }
    private func send(_ recording: PhoneTransfer.Recording, files: [URL], code: String, port: NWEndpoint.Port) async throws -> Bool {
        let link = FramedConnection(NWConnection(host: "127.0.0.1", port: port, using: PhoneTransfer.parameters()))
        defer { link.cancel() }
        try await link.open()
        return try await PhoneTransferClient.send(recording, files: files, code: code, device: "iPhone de test", over: link) { _ in }
    }

    @MainActor func testRecordingBecomesCourseAndResendIsNotDuplicated() async throws {
        let (store, receiver, port) = try await receiver(); defer { receiver.stop() }
        let files = [try wav("part-000.wav", seconds: 3), try wav("part-001.wav", seconds: 1.5)]
        let recording = try header(files)
        let duplicate = try await send(recording, files: files, code: receiver.code, port: port)
        XCTAssertFalse(duplicate)
        let deadline = Date().addingTimeInterval(5)
        while store.courses.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let course = try XCTUnwrap(store.courses.first)
        XCTAssertEqual(course.title, "Neurosciences"); XCTAssertEqual(course.state, .audioReady)
        XCTAssertEqual(course.createdAt, recording.createdAt); XCTAssertEqual(course.status, "Audio reçu de iPhone de test")
        XCTAssertEqual(course.parts.map(\.duration), [3, 1.5])
        for part in course.parts {
            let audio = try AVAudioFile(forReading: store.folder(course.id).appendingPathComponent(part.filename))
            XCTAssertEqual(audio.length, AVAudioFramePosition(part.duration * 16000))
        }
        XCTAssertTrue(receiver.inbox.pending().isEmpty)
        // The reply was lost, the iPhone sends again: acknowledged, not imported twice.
        let again = try await send(recording, files: files, code: receiver.code, port: port)
        XCTAssertTrue(again); try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.courses.count, 1)
    }

    @MainActor func testWrongCodeIsRefusedAsPairingError() async throws {
        let (store, receiver, port) = try await receiver(); defer { receiver.stop() }
        let files = [try wav("part-000.wav", seconds: 1)]
        let wrong = receiver.code == "000000" ? "111111" : "000000"
        do { _ = try await send(try header(files), files: files, code: wrong, port: port); XCTFail("Code accepté") }
        catch PhoneTransfer.Failure.pairing(let message) { XCTAssertTrue(message.contains("Code d’appairage incorrect")) }
        XCTAssertTrue(store.courses.isEmpty); XCTAssertTrue(receiver.inbox.pending().isEmpty)
    }

    @MainActor func testUnreadableAudioIsRefusedAndNothingIsKept() async throws {
        let (store, receiver, port) = try await receiver(); defer { receiver.stop() }
        let junk = root.appendingPathComponent("part-000.wav"); try Data(repeating: 7, count: 4096).write(to: junk)
        do { _ = try await send(try header([junk]), files: [junk], code: receiver.code, port: port); XCTFail("Audio illisible accepté") }
        catch { XCTAssertTrue(error.localizedDescription.contains("illisible"), error.localizedDescription) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(store.courses.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("inbox").path).isEmpty)
    }

    @MainActor func testReceivedRecordingWaitsForBusyGate() async throws {
        let (store, receiver, port) = try await receiver(); defer { receiver.stop() }
        try store.gate.acquire("Traitement")
        let files = [try wav("part-000.wav", seconds: 1)]
        _ = try await send(try header(files, title: ""), files: files, code: receiver.code, port: port)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(store.courses.isEmpty); XCTAssertEqual(receiver.inbox.pending().count, 1)
        store.gate.release()
        let deadline = Date().addingTimeInterval(5)
        while store.courses.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(try XCTUnwrap(store.courses.first).title.hasPrefix("Cours du "))
    }

    func testRepairRestoresSizesOfUnfinishedWAV() throws {
        let url = try wav("cut.wav", seconds: 2)
        let handle = try FileHandle(forUpdating: url)
        let head = try XCTUnwrap(try handle.read(upToCount: 4096))
        let data = try XCTUnwrap(head.range(of: Data("data".utf8)))
        // Header as left by a crash: lengths never written, plus half a frame at the end.
        try handle.seek(toOffset: 4); try handle.write(contentsOf: Data(count: 4))
        try handle.seek(toOffset: UInt64(data.upperBound)); try handle.write(contentsOf: Data(count: 4))
        try handle.seekToEnd(); try handle.write(contentsOf: Data([1])); try handle.close()
        XCTAssertNotEqual((try? AVAudioFile(forReading: url))?.length, 32000)
        XCTAssertTrue(try WAVRepair.repair(url))
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 32000)
        XCTAssertFalse(try WAVRepair.repair(url), "A complete file is left untouched.")
    }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while await !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }
    private func nextCommand(_ link: FramedConnection) async throws -> PhoneTransfer.Command {
        while true {
            let command = try await link.receiveMessage(PhoneTransfer.Command.self)
            if command.action != .ping { return command }
        }
    }

    @MainActor func testControlChannelShowsLiveStateAndRelaysCommands() async throws {
        let (store, receiver, port) = try await receiver(); defer { receiver.stop() }
        let remote = receiver.remote
        var errors: [String] = []; remote.onError = { errors.append($0) }
        let control = FramedConnection(NWConnection(host: "127.0.0.1", port: port, using: PhoneTransfer.parameters()))
        defer { control.cancel() }
        try await control.open()
        try await PhoneTransferClient.handshake(control, code: receiver.code, device: "iPhone de test", mode: .control)
        try await control.sendMessage(PhoneTransfer.Status(state: .recording, title: "Biologie", elapsed: 12, level: 0.5))
        try await until { remote.status?.state == .recording }
        XCTAssertTrue(remote.connected); XCTAssertEqual(remote.device, "iPhone de test")
        XCTAssertEqual(remote.status?.elapsed, 12); XCTAssertTrue(remote.recording)

        remote.send(.pause)
        let pause = try await nextCommand(control)
        XCTAssertEqual(pause, PhoneTransfer.Command(action: .pause))
        remote.send(.start, title: "Chimie")
        let start = try await nextCommand(control)
        XCTAssertEqual(start, PhoneTransfer.Command(action: .start, title: "Chimie"))

        // A failed command is reported once, however many times the state repeats it.
        let failure = PhoneTransfer.Status(state: .idle, errorID: UUID(), error: "Micro refusé")
        try await control.sendMessage(failure); try await control.sendMessage(failure)
        try await until { remote.status?.state == .idle }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(errors, ["iPhone : Micro refusé"])

        // Recordings are still received while the control connection stays open.
        let files = [try wav("part-000.wav", seconds: 1)]
        _ = try await send(try header(files), files: files, code: receiver.code, port: port)
        try await until { !store.courses.isEmpty }
        XCTAssertEqual(store.courses.count, 1); XCTAssertTrue(remote.connected)

        // Lost during a recording: the last state stays visible, controls are disabled.
        try await control.sendMessage(PhoneTransfer.Status(state: .recording, elapsed: 30))
        try await until { remote.status?.elapsed == 30 }
        control.cancel()
        try await until { !remote.connected }
        XCTAssertFalse(remote.connected); XCTAssertEqual(remote.status?.state, .recording)
        remote.send(.stop)
        XCTAssertEqual(errors.last, "L’iPhone n’est plus connecté. Ouvre CoursLocal sur l’iPhone.")
    }

    @MainActor func testControlChannelRequiresPairingCode() async throws {
        let (_, receiver, port) = try await receiver(); defer { receiver.stop() }
        let control = FramedConnection(NWConnection(host: "127.0.0.1", port: port, using: PhoneTransfer.parameters()))
        defer { control.cancel() }
        try await control.open()
        let wrong = receiver.code == "000000" ? "111111" : "000000"
        do { try await PhoneTransferClient.handshake(control, code: wrong, device: "Intrus", mode: .control); XCTFail("Code accepté") }
        catch PhoneTransfer.Failure.pairing {}
        XCTAssertNil(receiver.remote.device); XCTAssertFalse(receiver.remote.connected)
    }

    func testPairingCodes() {
        XCTAssertTrue(PhoneTransfer.isValidCode(PhoneTransfer.newCode()))
        XCTAssertFalse(PhoneTransfer.isValidCode("12345")); XCTAssertFalse(PhoneTransfer.isValidCode("12345a"))
        XCTAssertTrue(PhoneTransfer.sameCode("042317", "042317")); XCTAssertFalse(PhoneTransfer.sameCode("042317", "042318"))
    }
}
