import Foundation
import AVFoundation
import Combine

struct MobileRecording: Codable, Identifiable, Equatable, Sendable {
    struct Part: Codable, Equatable, Sendable { var name: String; var duration: Double }
    enum State: String, Codable, Sendable { case recording, ready, sent }
    var id = UUID()
    var title: String
    var createdAt = Date()
    var parts: [Part] = []
    var state: State = .recording
    var sentAt: Date? = nil
    var sentTo: String? = nil
    /// Shown under the recording, for example after recovering from a crash.
    var note: String? = nil
    var duration: Double { parts.reduce(0) { $0 + $1.duration } }
    var displayTitle: String { title.isEmpty ? "Cours du \(createdAt.formatted(date: .abbreviated, time: .shortened))" : title }
}

/// Recordings stored in Documents/Recordings/<id>/ (visible in Fichiers and in the Finder), one `recording.json` each.
@MainActor
final class RecordingLibrary: ObservableObject {
    @Published private(set) var recordings: [MobileRecording] = []
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        load()
    }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func files(_ recording: MobileRecording) -> [URL] { recording.parts.map { folder(recording.id).appendingPathComponent($0.name) } }
    func recording(_ id: UUID) -> MobileRecording? { recordings.first { $0.id == id } }
    var pending: [MobileRecording] { recordings.filter { $0.state == .ready }.sorted { $0.createdAt < $1.createdAt } }

    /// Called at launch, before any new recording: a recording still marked as running was cut short.
    private func load() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var loaded: [MobileRecording] = []
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("recording.json")),
                  var recording = try? JSONDecoder().decode(MobileRecording.self, from: data) else { continue }
            if recording.state == .recording {
                recording.parts = Self.recoverParts(in: folder)
                guard !recording.parts.isEmpty else { try? FileManager.default.removeItem(at: folder); continue }
                recording.state = .ready
                recording.note = "Enregistrement interrompu — audio récupéré jusqu’à l’arrêt"
                try? write(recording)
            }
            loaded.append(recording)
        }
        recordings = loaded.sorted { $0.createdAt > $1.createdAt }
    }
    /// Every readable segment, in order. The last one may lack its final header sizes: they are rebuilt.
    static func recoverParts(in folder: URL) -> [MobileRecording.Part] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("part-") && $0.hasSuffix(".wav") }.sorted()
        return names.compactMap { name in
            let url = folder.appendingPathComponent(name)
            _ = try? WAVRepair.repair(url)
            guard let file = try? AVAudioFile(forReading: url), file.length > 0, file.processingFormat.sampleRate > 0 else { return nil }
            return MobileRecording.Part(name: name, duration: Double(file.length) / file.processingFormat.sampleRate)
        }
    }
    private func write(_ recording: MobileRecording) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: folder(recording.id), withIntermediateDirectories: true)
        try encoder.encode(recording).write(to: folder(recording.id).appendingPathComponent("recording.json"), options: .atomic)
    }
    func save(_ recording: MobileRecording) throws {
        try write(recording)
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) { recordings[index] = recording }
        else { recordings.insert(recording, at: 0) }
    }
    func update(_ id: UUID, _ change: (inout MobileRecording) -> Void) throws {
        guard var recording = recording(id) else { return }
        change(&recording); try save(recording)
    }
    func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: folder(id))
        recordings.removeAll { $0.id == id }
    }
    var storageUsed: Int64 {
        recordings.flatMap(files).reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

/// Serial disk writer: WAV mono 16 kHz 16 bits, a new file every five minutes of audio, as on the Mac.
/// A crash can only damage the segment being written, and its header is repaired at the next launch.
final class SegmentWriter: @unchecked Sendable {
    static let sampleRate = 16000.0
    private let queue = DispatchQueue(label: "fr.baptiste.CoursLocalMobile.disk", qos: .userInitiated)
    private let folder: URL
    private let segmentFrames: Int
    private var file: AVAudioFile?
    private var frames = 0
    private var parts: [MobileRecording.Part] = []
    private var failure: String?
    var onError: (@Sendable (String) -> Void)?
    init(folder: URL, segmentFrames: Int = 300 * 16000) { self.folder = folder; self.segmentFrames = segmentFrames }

    func append(_ samples: [Float]) {
        queue.async {
            guard self.failure == nil else { return }
            do { try self.write(samples) } catch {
                self.failure = "Écriture audio impossible : \(error.localizedDescription)"; self.onError?(self.failure!)
            }
        }
    }
    private func open() throws {
        let name = String(format: "part-%03d.wav", parts.count)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                                       AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        file = try AVAudioFile(forWriting: folder.appendingPathComponent(name), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        parts.append(MobileRecording.Part(name: name, duration: 0)); frames = 0
    }
    private func closePart() {
        guard file != nil else { return }
        file = nil // Finalizes the WAV header.
        parts[parts.count - 1].duration = Double(frames) / Self.sampleRate
    }
    private func write(_ samples: [Float]) throws {
        var offset = 0
        while offset < samples.count {
            if file == nil { try open() }
            let count = min(segmentFrames - frames, samples.count - offset)
            guard let file, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
                  let data = buffer.floatChannelData?[0] else { throw MobileError("Tampon audio indisponible.") }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { data.update(from: $0.baseAddress! + offset, count: count) }
            try file.write(from: buffer); offset += count; frames += count
            if frames == segmentFrames { closePart() }
        }
    }
    func finish() async -> (parts: [MobileRecording.Part], error: String?) {
        await withCheckedContinuation { continuation in
            queue.async { self.closePart(); continuation.resume(returning: (self.parts, self.failure)) }
        }
    }
}

struct MobileError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Receives the converted audio of the tap: always measures the level, writes only while a recording runs.
private final class TapSink: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: SegmentWriter?
    private var frames = 0
    private var rms: Float = 0
    func setWriter(_ writer: SegmentWriter?) { lock.withLock { self.writer = writer } }
    func handle(_ samples: [Float]) {
        let value = (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
        let writer = lock.withLock { () -> SegmentWriter? in
            rms = value
            if writer != nil { frames += samples.count }
            return writer
        }
        writer?.append(samples)
    }
    func read() -> (frames: Int, rms: Float) { lock.withLock { (frames, rms) } }
    func reset() { lock.withLock { frames = 0; rms = 0 } }
}

/// Records the built-in microphone. Keeps running screen locked (background audio mode),
/// pauses during a call and resumes by itself afterwards. Paused time is not recorded.
///
/// iOS refuses to open the microphone from the background. The microphone therefore stays open during a pause,
/// and, with `keepAlive`, while idle: the app stays alive and the Mac can start a recording at any time.
@MainActor
final class MobileRecorder: ObservableObject {
    @Published private(set) var recording: MobileRecording?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var paused = false
    @Published private(set) var notice: String?
    /// Microphone open while no recording runs, so that the Mac can reach the iPhone in the background.
    @Published private(set) var standby = false
    @Published var error: String?
    @Published var keepAlive: Bool { didSet { UserDefaults.standard.set(keepAlive, forKey: "keepAlive"); updateStandby() } }
    var onFinished: ((MobileRecording) -> Void)?
    private let library: RecordingLibrary
    private let engine = AVAudioEngine()
    private let sink = TapSink()
    private var writer: SegmentWriter?
    private var tapInstalled = false
    private var timer: Timer?
    private var starting = false
    private var stopping = false
    private var pausedBySystem = false

    init(library: RecordingLibrary) {
        self.library = library
        keepAlive = UserDefaults.standard.bool(forKey: "keepAlive")
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.interrupted(began: raw == AVAudioSession.InterruptionType.began.rawValue) }
        }
        // A microphone change (headset, route) changes the input format: reinstall the tap.
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reconfigure() }
        }
    }
    private var wantsEngine: Bool { recording != nil || keepAlive }

    /// Opens or closes the idle microphone according to `keepAlive`. Opening only works in the foreground.
    func updateStandby() {
        if recording == nil {
            if keepAlive && !tapInstalled { try? openMicrophone() }
            if !keepAlive && tapInstalled { closeMicrophone() }
        }
        standby = recording == nil && tapInstalled
    }
    /// Back in the foreground: restarts what an interruption may have left stopped.
    func becameActive() {
        if pausedBySystem { resume() }
        else if wantsEngine && !tapInstalled { try? openMicrophone() }
        updateStandby()
    }

    /// Returns false when the recording could not start; `error` then says why.
    @discardableResult
    func start(title: String) async -> Bool {
        guard recording == nil, !starting else { return false }
        starting = true; defer { starting = false }
        var created: UUID?
        do {
            guard await AVAudioApplication.requestRecordPermission() else {
                throw MobileError("CoursLocal n’a pas accès au micro. Autorise-le dans Réglages → Confidentialité et sécurité → Micro.")
            }
            if !tapInstalled { try openMicrophone() }
            let new = MobileRecording(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
            try library.save(new); created = new.id // Durable before any audio, so a crash leaves a recoverable recording.
            let writer = SegmentWriter(folder: library.folder(new.id))
            writer.onError = { [weak self] message in Task { @MainActor in self?.error = message; await self?.stop() } }
            self.writer = writer; sink.reset(); sink.setWriter(writer)
            recording = new; paused = false; pausedBySystem = false; notice = nil; elapsed = 0; standby = false
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
            return true
        } catch {
            sink.setWriter(nil); writer = nil
            if let created { try? library.delete(created) }
            if !keepAlive { closeMicrophone() }
            self.error = error.localizedDescription
            return false
        }
    }
    /// Nothing is written during a pause. The microphone stays open, so that a pause can end from the Mac.
    func pause() {
        guard recording != nil, !paused else { return }
        sink.setWriter(nil); paused = true; notice = nil; level = 0
    }
    func resume() {
        guard recording != nil, paused, let writer else { return }
        do {
            if !tapInstalled { try openMicrophone() }
            sink.setWriter(writer); paused = false; pausedBySystem = false; notice = nil
        } catch { notice = "Reprise impossible : \(error.localizedDescription)" }
    }
    func stop() async {
        guard var finished = recording, !stopping, let writer else { return }
        stopping = true; defer { stopping = false }
        sink.setWriter(nil); timer?.invalidate(); timer = nil
        let result = await writer.finish()
        self.writer = nil; recording = nil; paused = false; pausedBySystem = false; notice = nil; level = 0
        if keepAlive { updateStandby() } else { closeMicrophone() }
        finished.parts = result.parts
        if finished.parts.isEmpty { try? library.delete(finished.id); return }
        finished.state = .ready
        if let message = result.error { finished.note = message }
        do { try library.save(finished); onFinished?(finished) }
        catch { self.error = "Enregistrement terminé, mais sa fiche n’a pas pu être écrite : \(error.localizedDescription)" }
    }

    private func openMicrophone() throws {
        let session = AVAudioSession.sharedInstance()
        // Mixable: music or a video can keep playing; a call still interrupts the recording.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
        // The built-in microphone hears the lecture hall; AirPods would only hear their wearer.
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) { try? session.setPreferredInput(builtIn) }
        try session.setActive(true)
        do { try startEngine() } catch { try? session.setActive(false); throw error }
    }
    private func closeMicrophone() {
        stopEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        standby = false
    }
    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MobileError("Aucun micro disponible.") }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SegmentWriter.sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: format, to: target) else { throw MobileError("Format du micro non pris en charge.") }
        converter.primeMethod = .none
        let sink = sink
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 512)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false; var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true; inputStatus.pointee = .haveData; return buffer
            }
            guard status != .error, output.frameLength > 0, let data = output.floatChannelData?[0] else { return }
            sink.handle(Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength))))
        }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() } catch { stopEngine(); throw error }
    }
    private func stopEngine() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
    }
    private func tick() {
        let value = sink.read()
        elapsed = Double(value.frames) / SegmentWriter.sampleRate
        let decibels = 20 * log10(max(Double(value.rms), 1e-6))
        level = paused ? 0 : min(1, max(0, (decibels + 55) / 55))
    }
    private func interrupted(began: Bool) {
        if began {
            guard tapInstalled else { return } // The system has stopped the engine.
            stopEngine()
            if recording != nil && !paused {
                sink.setWriter(nil); paused = true; pausedBySystem = true; level = 0
                notice = "En pause pendant l’interruption (appel…) — reprise automatique ensuite"
            }
        } else if pausedBySystem {
            resume()
            if !paused { notice = "Repris après une interruption" }
        } else if wantsEngine && !tapInstalled {
            try? openMicrophone()
        }
        standby = recording == nil && tapInstalled
    }
    private func reconfigure() {
        guard tapInstalled else { return }
        stopEngine()
        do { try startEngine() } catch {
            if recording != nil && !paused { sink.setWriter(nil); paused = true }
            if recording != nil { notice = "Micro modifié : touche Reprendre. (\(error.localizedDescription))" }
        }
        standby = recording == nil && tapInstalled
    }
}
