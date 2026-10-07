import Foundation
import AVFoundation
import Combine
import AppKit
import ScreenCaptureKit
import CoreMedia

// The capture devices never stop at file boundaries. Only this serial disk writer rotates files.
final class SegmentedAudioWriter: @unchecked Sendable {
    static let sampleRate = 16000.0
    private let queue = DispatchQueue(label: "fr.baptiste.CoursLocal.audio.disk", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = 0
    private var accepting = true
    private let folder: URL
    private let segmentFrames: Int
    private var file: AVAudioFile?
    private var frames = 0
    private var parts: [AudioPart] = []
    private var failure: String?
    var onError: (@Sendable (String) -> Void)?
    var onParts: (@Sendable ([AudioPart]) -> Void)?
    init(folder: URL, segmentFrames: Int = 300 * 16000) { self.folder = folder; self.segmentFrames = segmentFrames; precondition(segmentFrames > 0) }
    func prepare() async throws -> [AudioPart] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { try self.open(); continuation.resume(returning: self.parts) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        guard accepting else { lock.unlock(); return }
        if pending >= 64 || samples.count > 16000 * 2 {
            accepting = false; lock.unlock()
            queue.async { self.fail("L’écriture audio ne suit plus. L’enregistrement a été arrêté sans masquer la perte de données.") }
            return
        }
        pending += 1; lock.unlock()
        queue.async {
            defer { self.lock.lock(); self.pending -= 1; self.lock.unlock() }
            guard self.failure == nil else { return }
            do { try self.write(samples) } catch { self.fail(error.localizedDescription) }
        }
    }
    private func fail(_ message: String) {
        guard failure == nil else { return }; failure = message; onError?(message)
    }
    private func persistManifest() throws {
        try JSONEncoder().encode(parts).write(to: folder.appendingPathComponent("recording-manifest.json"), options: .atomic)
    }
    private func open() throws {
        let part = AudioPart(filename: "\(UUID().uuidString).wav")
        parts.append(part); try persistManifest() // Name is durable before audio creation.
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate,
                                     AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                                     AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        file = try AVAudioFile(forWriting: folder.appendingPathComponent(part.filename), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        frames = 0
    }
    private func closePart() throws {
        guard file != nil else { return }
        file = nil // Finalize the WAV header before publishing the part.
        parts[parts.count - 1].duration = Double(frames) / Self.sampleRate
        try persistManifest(); onParts?(parts)
    }
    private func write(_ samples: [Float]) throws {
        var offset = 0
        while offset < samples.count {
            if file == nil { try open() }
            let count = min(segmentFrames - frames, samples.count - offset)
            guard let file, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)), let data = buffer.floatChannelData?[0] else { throw CourseError.message("Impossible de créer le tampon audio.") }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in data.update(from: source.baseAddress! + offset, count: count) }
            try file.write(from: buffer); offset += count; frames += count
            if frames == segmentFrames { try closePart() }
        }
    }
    func drain() async {
        await withCheckedContinuation { c in queue.async { c.resume() } }
    }
    func finish() async -> (parts: [AudioPart], error: String?) {
        lock.withLock { accepting = false }
        return await withCheckedContinuation { continuation in
            queue.async {
                do { try self.closePart() } catch { self.fail(error.localizedDescription) }
                continuation.resume(returning: (self.parts, self.failure))
            }
        }
    }
}

// Host-clock-aligned, bounded mixer. Buffers are copied before the device callback returns.
final class AudioCaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Source: Hashable { case microphone, application }
    private final class Bucket { var samples = [Float](repeating: 0, count: 1600) }
    private let queue = DispatchQueue(label: "fr.baptiste.CoursLocal.audio.mix", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = 0
    private var accepting = true
    private var stopped = false
    private var origin: Double?
    private var emitted = 0
    private var buckets: [Int: Bucket] = [:]
    private var cursors: [Source: Int] = [:]
    private var converters: [Source: AVAudioConverter] = [:]
    private var timer: DispatchSourceTimer?
    private let writer: SegmentedAudioWriter
    private let mode: CaptureMode
    private let clock: @Sendable () -> Double
    var onError: (@Sendable (String) -> Void)?
    var onMeter: (@Sendable (Source, Double) -> Void)?
    var onElapsed: (@Sendable (Double) -> Void)?
    private var previousFrames = 0
    init(writer: SegmentedAudioWriter, mode: CaptureMode, clock: @escaping @Sendable () -> Double = { AudioCaptureSink.hostSeconds }) { self.writer = writer; self.mode = mode; self.clock = clock }
    static var hostSeconds: Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }
    func begin() {
        queue.async { [self] in
            self.origin = self.clock()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self, let origin = self.origin, !self.stopped else { return }
                let target = max(0, Int(((self.clock() - origin) * 16000).rounded()) - 4000)
                self.flush(to: target / 1600 * 1600)
                self.onElapsed?(Double(self.previousFrames + self.emitted) / 16000)
            }
            self.timer = timer; timer.resume()
        }
    }
    func drain() async { await withCheckedContinuation { c in queue.async { c.resume() } } }
    func setPaused(_ paused: Bool) async {
        await withCheckedContinuation { continuation in
            queue.async {
                if paused {
                    if let origin = self.origin { self.flush(to: max(self.emitted, Int(((self.clock() - origin) * 16000).rounded()))) }
                    self.previousFrames += self.emitted; self.emitted = 0; self.origin = nil
                    self.buckets = [:]; self.cursors = [:]; self.converters = [:]
                } else { self.origin = self.clock() }
                continuation.resume()
            }
        }
    }
    func enqueue(_ original: AVAudioPCMBuffer, source: Source, hostSeconds: Double) {
        guard hostSeconds.isFinite, hostSeconds > 0 else { onError?("Horodatage audio invalide."); return }
        guard original.frameLength > 0 else { return }
        lock.lock()
        guard accepting else { lock.unlock(); return }
        if pending >= 64 || original.frameLength > 192000 {
            accepting = false; lock.unlock(); onError?("La capture audio ne suit plus. Vérifie la charge du Mac."); return
        }
        pending += 1; lock.unlock()
        guard let copy = AVAudioPCMBuffer(pcmFormat: original.format, frameCapacity: original.frameLength) else { releasePending(); onError?("Mémoire audio insuffisante."); return }
        copy.frameLength = original.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: original.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            if let from = src[i].mData, let to = dst[i].mData { memcpy(to, from, Int(src[i].mDataByteSize)) }
        }
        queue.async {
            defer { self.releasePending() }
            guard let origin = self.origin, !self.stopped else { return }
            do {
                let samples = try self.convert(copy, source: source)
                self.onMeter?(source, sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, samples.count))))
                var start = Int(((hostSeconds - origin) * 16000).rounded())
                if let cursor = self.cursors[source], abs(start - cursor) < 160 { start = cursor }
                self.cursors[source] = start + samples.count
                let gain: Float = self.mode == .combined ? 0.5 : 1
                for (i, value) in samples.enumerated() {
                    let index = start + i
                    if index < 0 { continue } // Buffers belonging to the previous pause/start epoch.
                    guard index >= self.emitted else { throw CourseError.message("Tampon audio arrivé trop tard. L’enregistrement a été interrompu pour signaler la perte.") }
                    guard index < self.emitted + 16000 * 3 else { throw CourseError.message("Horloge audio désynchronisée.") }
                    let key = index / 1600
                    let bucket = self.buckets[key] ?? Bucket(); self.buckets[key] = bucket
                    bucket.samples[index % 1600] += value * gain
                }
            } catch { self.onError?(error.localizedDescription) }
        }
    }
    private func releasePending() { lock.lock(); pending -= 1; lock.unlock() }
    private func convert(_ buffer: AVAudioPCMBuffer, source: Source) throws -> [Float] {
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        if converters[source]?.inputFormat != buffer.format {
            converters[source] = AVAudioConverter(from: buffer.format, to: target)
            converters[source]?.primeMethod = .none
        }
        guard let converter = converters[source], let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 512)) else { throw CourseError.message("Format audio non pris en charge.") }
        var supplied = false; var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil, let data = output.floatChannelData?[0] else { throw error ?? CourseError.message("Conversion audio impossible.") as NSError }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }
    private func flush(to target: Int) {
        guard target >= emitted, target - emitted <= 16000 * 3 else {
            onError?("L’horloge de capture a été interrompue (veille ou surcharge). L’audio disponible est conservé."); return
        }
        while emitted < target {
            let key = emitted / 1600; let offset = emitted % 1600; let count = min(1600 - offset, target - emitted)
            let bucket = buckets[key]
            let samples = bucket.map { Array($0.samples[offset..<(offset + count)]).map { max(-1, min(1, $0)) } } ?? [Float](repeating: 0, count: count)
            writer.append(samples); emitted += count
            if emitted % 1600 == 0 { buckets[key] = nil }
        }
    }
    func finish() async {
        lock.withLock { accepting = false }
        await withCheckedContinuation { continuation in
            queue.async {
                if let origin = self.origin { self.flush(to: max(self.emitted, Int(((self.clock() - origin) * 16000).rounded()))) }
                self.stopped = true; self.timer?.cancel(); self.timer = nil; self.buckets = [:]
                self.onElapsed?(Double(self.previousFrames + self.emitted) / 16000)
                continuation.resume()
            }
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer), let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))) else { return }
        buffer.frameLength = buffer.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(buffer.frameLength), into: buffer.mutableAudioBufferList)
        guard status == noErr else { onError?("Lecture du son système impossible (\(status))."); return }
        enqueue(buffer, source: .application, hostSeconds: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?("Capture de l’application interrompue : \(error.localizedDescription)") }
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var courseID: UUID?
    @Published private(set) var paused = false
    @Published private(set) var stopping = false
    @Published private(set) var starting = false
    private var startupFailure: String?
    @Published private(set) var elapsed = 0.0
    @Published private(set) var level = 0.0
    @Published private(set) var applicationLevel = 0.0
    private let store: CourseStore
    private var engine: AVAudioEngine?
    private var hasMicrophoneTap = false
    private var stream: SCStream?
    private var sink: AudioCaptureSink?
    private var writer: SegmentedAudioWriter?
    private var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    private var terminationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private let microphonePermission: @Sendable () async -> Bool
    private let shareableContent: @Sendable () async throws -> SCShareableContent
    var onCompleted: ((UUID) -> Void)?
    init(store: CourseStore,
         microphonePermission: @escaping @Sendable () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) },
         shareableContent: @escaping @Sendable () async throws -> SCShareableContent = { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }) {
        self.store = store; self.microphonePermission = microphonePermission; self.shareableContent = shareableContent
    }
    static var applications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
    func start(title: String, mode: CaptureMode = .microphone, applicationPID: pid_t? = nil) async throws -> UUID {
        try store.gate.acquire("Enregistrement")
        starting = true; startupFailure = nil
        defer { starting = false }
        var created: UUID?
        do {
            if mode.usesMicrophone {
                guard await microphonePermission() else { throw CourseError.message("Autorise le microphone dans Réglages Système → Confidentialité et sécurité → Microphone.") }
            }
            var filter: SCContentFilter?
            var applicationName: String?
            if mode.usesApplication {
                let content: SCShareableContent
                do { content = try await shareableContent() }
                catch { throw CourseError.message("Autorise l’enregistrement de l’écran et du son système dans les Réglages Système. Aucune image ni vidéo n’est enregistrée. \(error.localizedDescription)") }
                guard let pid = applicationPID, let app = content.applications.first(where: { $0.processID == pid }), let display = content.displays.first else { throw CourseError.message("Choisis une application ouverte pour capturer son audio.") }
                filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
                applicationName = app.applicationName
            }
            let id = try await store.create(title: title); created = id; courseID = id
            let name = applicationName
            try await store.update(id) { $0.captureMode = mode; $0.applicationName = name; $0.state = .recording; $0.status = "Enregistrement" }
            elapsed = 0; paused = false; level = 0; applicationLevel = 0
            let writer = SegmentedAudioWriter(folder: store.folder(id))
            let sink = AudioCaptureSink(writer: writer, mode: mode)
            let failure: @Sendable (String) -> Void = { [weak self] message in
                Task { @MainActor in
                    guard let self, self.courseID == id, !self.stopping else { return }
                    if self.starting { self.startupFailure = message } else { await self.stop(interruption: message) }
                }
            }
            writer.onError = failure; sink.onError = failure
            sink.onMeter = { [weak self] source, value in Task { @MainActor in
                guard self?.courseID == id else { return }
                if source == .microphone { self?.level = value } else { self?.applicationLevel = value }
            } }
            sink.onElapsed = { [weak self] value in Task { @MainActor in if self?.courseID == id { self?.elapsed = value } } }
            writer.onParts = { [weak self] parts in Task { @MainActor in
                guard let self, self.courseID == id, !self.stopping else { return }
                do { try await self.store.update(id) { $0.parts = parts } } catch { await self.stop(interruption: error.localizedDescription) }
            } }
            self.writer = writer; self.sink = sink
            let parts = try await writer.prepare(); try await store.update(id) { $0.parts = parts }
            if mode.usesMicrophone {
                let engine = AVAudioEngine(); self.engine = engine
                let input = engine.inputNode; let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw CourseError.message("Microphone indisponible.") }
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak sink] buffer, time in
                    sink?.enqueue(buffer, source: .microphone, hostSeconds: AVAudioTime.seconds(forHostTime: time.hostTime))
                }
                hasMicrophoneTap = true
                engine.prepare(); try engine.start()
                observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in failure("Le microphone ou son format a changé. Vérifie le périphérique avant de reprendre.") })
            }
            if let filter {
                let configuration = SCStreamConfiguration(); configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true; configuration.sampleRate = 48000; configuration.channelCount = 1
                configuration.width = 2; configuration.height = 2; configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
                let stream = SCStream(filter: filter, configuration: configuration, delegate: sink); self.stream = stream
                try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: DispatchQueue(label: "fr.baptiste.CoursLocal.system-audio"))
                try await stream.startCapture()
                terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
                    if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier == applicationPID { failure("L’application capturée a été fermée.") }
                }
            }
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in failure("Le Mac va se mettre en veille. L’enregistrement est interrompu.") }
            if let startupFailure { throw CourseError.message(startupFailure) }
            sink.begin()
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Enregistrement du cours")
            return id
        } catch {
            if created != nil { await stop(interruption: error.localizedDescription) }
            else { store.gate.release() }
            throw error
        }
    }
    func togglePause() async {
        guard let id = courseID, !stopping, let sink else { return }
        paused.toggle(); await sink.setPaused(paused)
        level = 0; applicationLevel = 0
        let pause = paused
        do { try await store.update(id) { $0.state = pause ? .paused : .recording; $0.status = pause ? "En pause" : "Enregistrement" } }
        catch { await stop(interruption: error.localizedDescription) }
    }
    func stop(interruption: String? = nil) async {
        guard let id = courseID, !stopping else { return }
        stopping = true
        for token in observers { NotificationCenter.default.removeObserver(token) }; observers = []
        if let token = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(token) }; sleepObserver = nil
        if let token = terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(token) }; terminationObserver = nil
        if hasMicrophoneTap { engine?.inputNode.removeTap(onBus: 0); hasMicrophoneTap = false }; engine?.stop(); engine = nil
        var failure = interruption
        if let stream { do { try await stream.stopCapture() } catch { failure = failure ?? error.localizedDescription } }; stream = nil
        await sink?.finish(); sink = nil
        let result = await writer?.finish(); writer = nil
        failure = failure ?? result?.error
        do {
            let message = failure; let parts = result?.parts
            try await store.update(id) { c in
                if let parts { c.parts = parts }
                c.state = message == nil ? .audioReady : .interrupted
                c.status = message == nil ? "Audio enregistré" : "Enregistrement interrompu — vérifier l’audio"
                c.lastError = message
            }
            // The course metadata now contains all finalized segments.
            if failure == nil {
                let manifest = store.folder(id).appendingPathComponent("recording-manifest.json")
                try await Task.detached { try FileManager.default.removeItem(at: manifest) }.value
            }
        } catch { failure = failure ?? error.localizedDescription }
        courseID = nil; stopping = false; paused = false; level = 0; applicationLevel = 0
        if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil
        store.gate.release()
        if let failure { store.error = failure } else { onCompleted?(id) }
    }
}
