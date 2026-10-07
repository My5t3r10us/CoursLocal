import XCTest
@testable import CoursLocal

final class TextChunksTests: XCTestCase {
    func testLongPassagePreservesTimestampAndContent() {
        let body = String(repeating: "énergie 🧠 et définition. ", count: 120)
        let prefix = "[00:15:00] "
        let chunks = TextChunks.split(prefix + body, maxBytes: 512)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 512 && $0.hasPrefix(prefix) })
        XCTAssertEqual(chunks.map { String($0.dropFirst(prefix.count)) }.joined(), body)
    }

    func testSplitKeepsEveryLineInOrder() {
        let lines = (0..<40).map { "[00:00:\(String(format: "%02d", $0))] " + String(repeating: "notion ", count: 15) }
        let chunks = TextChunks.split(lines.joined(separator: "\n"), maxBytes: 512)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 512 })
        XCTAssertEqual(chunks.joined(separator: "\n"), lines.joined(separator: "\n"))
    }

    func testEmptyInput() {
        XCTAssertEqual(TextChunks.split("\n\n"), [])
    }

    func testTranscriptOffsetsAcrossParts() {
        let course = Course(title: "Test", parts: [
            AudioPart(filename: "a.wav", duration: 300, passages: [Passage(start: 12, end: 15, text: "Première notion")]),
            AudioPart(filename: "b.wav", duration: 30, passages: [Passage(start: 4, end: 8, text: "Seconde notion")])
        ])
        XCTAssertEqual(course.transcript, "[00:00:12] Première notion\n[00:05:04] Seconde notion")
        XCTAssertEqual(course.duration, 330)
    }

    func testCheckpointRoundTripRetainsPartialResults() throws {
        let course = Course(title: "Test", parts: [AudioPart(filename: "a.wav", duration: 300, passages: [])], blocks: [StudyBlock(id: 0, source: "Source", notes: "Notes enregistrées")])
        let restored = try JSONDecoder().decode(Course.self, from: JSONEncoder().encode(course))
        XCTAssertEqual(restored.id, course.id)
        XCTAssertEqual(restored.parts[0].passages?.count, 0)
        XCTAssertEqual(restored.blocks[0].notes, "Notes enregistrées")
        XCTAssertNil(restored.blocks[0].cards)
        XCTAssertNil(restored.summary)
    }
}

import AVFoundation

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    init(_ value: Double) { self.value = value }
    func now() -> Double { lock.withLock { value } }
    func set(_ value: Double) { lock.withLock { self.value = value } }
}

final class AudioContinuityTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func readParts(_ parts: [AudioPart], folder: URL) throws -> [Float] {
        var samples: [Float] = []
        for part in parts {
            let file = try AVAudioFile(forReading: folder.appendingPathComponent(part.filename))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return samples
    }
    func testRotationPreservesEverySampleAndCreatesNoEmptyTrailingFile() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let writer = SegmentedAudioWriter(folder: folder, segmentFrames: 997)
        _ = try await writer.prepare()
        let input = (0..<9970).map { Float($0 % 512 - 256) / 1024 }
        for i in stride(from: 0, to: input.count, by: 321) { writer.append(Array(input[i..<min(i + 321, input.count)])) }
        let result = await writer.finish()
        XCTAssertNil(result.error); XCTAssertEqual(result.parts.count, 10)
        XCTAssertEqual(try readParts(result.parts, folder: folder), input)
        XCTAssertTrue(result.parts.allSatisfy { $0.duration == 997.0 / 16000 })
    }
    func testTwoHoursSyntheticAudioHas24ContinuousSegments() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let writer = SegmentedAudioWriter(folder: folder)
        _ = try await writer.prepare()
        let frames = 7200 * 16000
        var start = 0
        while start < frames {
            let chunk = (start..<(start + 16000)).map { Float($0 % 4096 - 2048) / 16384 }
            writer.append(chunk); start += 16000
            if start % (32 * 16000) == 0 { await writer.drain() }
        }
        let result = await writer.finish()
        XCTAssertNil(result.error); XCTAssertEqual(result.parts.count, 24)
        XCTAssertEqual(result.parts.reduce(0) { $0 + $1.duration }, 7200)
        var cursor = 0; var mismatches = 0
        for part in result.parts {
            let file = try AVAudioFile(forReading: folder.appendingPathComponent(part.filename))
            XCTAssertEqual(file.length, 300 * 16000)
            XCTAssertEqual(file.fileFormat.sampleRate, 16000)
            XCTAssertEqual(file.fileFormat.channelCount, 1)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 64000)!
            while file.framePosition < file.length {
                try file.read(into: buffer)
                let samples = buffer.floatChannelData![0]
                for i in 0..<Int(buffer.frameLength) {
                    if samples[i] != Float(cursor % 4096 - 2048) / 16384 { mismatches += 1 }
                    cursor += 1
                }
            }
        }
        XCTAssertEqual(cursor, frames); XCTAssertEqual(mismatches, 0)
    }
    func testWriterBackpressureIsReportedInsteadOfSilentlyDroppingData() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let writer = SegmentedAudioWriter(folder: folder); _ = try await writer.prepare()
        writer.append([Float](repeating: 0.5, count: 32001))
        let result = await writer.finish(); XCTAssertNotNil(result.error)
    }
    func testWriterFailureRetainsFinalizedParts() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let writer = SegmentedAudioWriter(folder: folder, segmentFrames: 1600); _ = try await writer.prepare()
        writer.append([Float](repeating: 0.25, count: 1600)); await writer.drain()
        writer.append([Float](repeating: 0.5, count: 32001))
        let result = await writer.finish(); XCTAssertNotNil(result.error); XCTAssertEqual(result.parts.first?.duration, 0.1)
        XCTAssertEqual(try readParts(result.parts, folder: folder), [Float](repeating: 0.25, count: 1600))
    }
    func testCombinedMixUsesHostClockAndPauseExcludesElapsedWallTime() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let writer = SegmentedAudioWriter(folder: folder); _ = try await writer.prepare()
        let clock = TestClock(10)
        let sink = AudioCaptureSink(writer: writer, mode: .combined, clock: { clock.now() })
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        func buffer(_ value: Float) -> AVAudioPCMBuffer {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!; b.frameLength = 1600
            b.floatChannelData![0].initialize(repeating: value, count: 1600); return b
        }
        sink.begin(); await sink.drain()
        sink.enqueue(buffer(0.5), source: .microphone, hostSeconds: 10)
        sink.enqueue(buffer(0.25), source: .application, hostSeconds: 10)
        await sink.drain(); clock.set(10.1); await sink.setPaused(true)
        clock.set(20); await sink.setPaused(false)
        sink.enqueue(buffer(0.25), source: .application, hostSeconds: 20)
        sink.enqueue(buffer(0.5), source: .microphone, hostSeconds: 20)
        await sink.drain(); clock.set(20.1); await sink.finish()
        let result = await writer.finish(); XCTAssertNil(result.error)
        let samples = try readParts(result.parts, folder: folder)
        XCTAssertEqual(samples.count, 3200)
        XCTAssertTrue(samples.allSatisfy { abs($0 - 0.375) < 1.0 / 32768 })
    }
    func testWriterCannotPrepareInMissingFolder() async {
        let writer = SegmentedAudioWriter(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        do { _ = try await writer.prepare(); XCTFail("Expected disk error") } catch { }
    }
}

final class HTTPMock: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        do {
            let (status, headers, body) = try XCTUnwrap(handler)(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
    static func client(_ handler: @escaping (URLRequest) throws -> (Int, [String: String], Data), sleep: @escaping @Sendable (Double) async throws -> Void = { _ in }) -> RapidMLXClient {
        lock.withLock { Self.handler = handler }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HTTPMock.self]
        return RapidMLXClient(session: URLSession(configuration: config, delegate: LocalSessionDelegate(), delegateQueue: nil), sleep: sleep)
    }
    static func body(_ request: URLRequest) -> Data {
        request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }; var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
            while true { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) }; return data
        } ?? Data()
    }
    static func completion(_ content: String, reason: String = "stop") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content], "finish_reason": reason]]])
    }
}

final class RapidMLXTests: XCTestCase {
    private var settings: AISettings { .init(baseURL: "http://127.0.0.1:8000/v1", model: "local-model", whisperModel: "small", language: "fr", apiKey: "test-key") }
    func testEndpointsAreStrictlyLocal() throws {
        for url in ["http://example.com/v1", "http://127.0.0.1.evil.com/v1", "file:///v1", "http://user:pass@localhost:8000/v1", "http://localhost/v1?remote=true"] { XCTAssertThrowsError(try LocalEndpoint(url)) }
        XCTAssertEqual(try LocalEndpoint("http://localhost:8000/v1/").base.absoluteString, "http://127.0.0.1:8000/v1")
        XCTAssertEqual(try LocalEndpoint("http://[::1]:8000/v1").health.path, "/health")
    }
    func testOpenAIContractAndModelDiscovery() async throws {
        let client = HTTPMock.client { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            if request.url!.path == "/health" { return (200, [:], Data("{}".utf8)) }
            if request.url!.path == "/v1/models" { return (200, [:], Data("{\"data\":[{\"id\":\"local-model\",\"owned_by\":\"rapid-mlx\",\"modality\":\"text\"},{\"id\":\"whisper\",\"modality\":\"audio\"},{\"id\":\"remote\",\"owned_by\":\"openai\"}]}".utf8)) }
            XCTAssertEqual(request.url!.path, "/v1/chat/completions"); XCTAssertEqual(request.httpMethod, "POST")
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }; var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
                while true { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) }; return data
            } ?? Data()) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "local-model"); XCTAssertNil(body["options"])
            return (200, [:], try HTTPMock.completion("Notes"))
        }
        let models = try await client.discover(baseURL: settings.baseURL, key: settings.apiKey); XCTAssertEqual(models.map(\.id), ["local-model"])
        let output = try await client.generate(settings: settings, task: "Notes", source: "Source"); XCTAssertEqual(output, "Notes")
    }
    func testRetryBudgetStopsAfterThreeRequests() async {
        var requests = 0
        let client = HTTPMock.client { _ in requests += 1; return (503, ["Retry-After": "0"], Data()) }
        do { _ = try await client.generate(settings: settings, task: "", source: ""); XCTFail() } catch { }
        XCTAssertEqual(requests, 3)
    }
    func testRetryAfterParsesSecondsAndDates() {
        XCTAssertEqual(RapidMLXClient.retryDelay("12", attempt: 0), 12)
        XCTAssertEqual(RapidMLXClient.retryDelay(nil, attempt: 1), 2)
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(RapidMLXClient.retryDelay("Thu, 01 Jan 1970 00:00:10 GMT", attempt: 0, now: now), 10)
    }
    func testAuthenticationFailureDoesNotRetry() async {
        var count = 0; let client = HTTPMock.client { _ in count += 1; return (401, [:], Data()) }
        do { _ = try await client.generate(settings: settings, task: "", source: ""); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("Clé")) }
        XCTAssertEqual(count, 1)
    }
    func testMissingModelIsActionable() async {
        let client = HTTPMock.client { _ in (404, [:], Data()) }
        do { _ = try await client.generate(settings: settings, task: "", source: ""); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("Modèle")) }
    }
    func testConnectionRefusedIsActionable() async {
        let client = HTTPMock.client { _ in throw URLError(.cannotConnectToHost) }
        do { _ = try await client.generate(settings: settings, task: "", source: ""); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("Desktop")) }
    }
    func testTruncatedEmptyAndMalformedResponsesAreRejected() async throws {
        for body in [try HTTPMock.completion("Partiel", reason: "length"), try HTTPMock.completion(" "), Data("{}".utf8)] {
            let client = HTTPMock.client { _ in (200, [:], body) }
            do { _ = try await client.generate(settings: settings, task: "", source: ""); XCTFail() } catch { }
        }
    }
    func testMalformedCleaningGetsExactlyOneCorrectionAttempt() async throws {
        let id = UUID(); let block = CleanBlock(id: 0, sourceIDs: [id], lines: ["La mémoire de travail maintient l’information."])
        let valid = "```json\n{\"sections\":[{\"title\":\"Définition\",\"theme\":\"Mémoire\",\"paragraphs\":[{\"text\":\"La mémoire de travail maintient l’information.\",\"sources\":[1]}]}],\"corrections\":[]}\n```"
        var count = 0; let client = HTTPMock.client { _ in count += 1; return (200, [:], try HTTPMock.completion(count == 1 ? "bad JSON" : valid)) }
        let result = try await client.clean(settings: settings, block: block, knownThemes: [], previous: nil)
        XCTAssertEqual(result.sections.first?.paragraphs.first?.references, [id]); XCTAssertEqual(result.sections.first?.theme, "Mémoire"); XCTAssertEqual(count, 2)
    }
    func testSummarizedCleaningIsRejectedAfterCorrection() async throws {
        let lines = (0..<6).map { "Ligne \($0) : " + String(repeating: "le professeur détaille une notion importante du cours ", count: 2) }
        let block = CleanBlock(id: 0, sourceIDs: lines.map { _ in UUID() }, lines: lines)
        let summary = "{\"sections\":[{\"title\":\"Résumé\",\"theme\":\"Cours\",\"paragraphs\":[{\"text\":\"Une notion.\",\"sources\":[1,2,3,4,5,6]}]}]}"
        var count = 0; let client = HTTPMock.client { _ in count += 1; return (200, [:], try HTTPMock.completion(summary)) }
        do { _ = try await client.clean(settings: settings, block: block, knownThemes: [], previous: nil); XCTFail() }
        catch { XCTAssertTrue(CourseError.isModelOutput(error)) }
        XCTAssertEqual(count, 2)
    }
    func testTransportErrorsAreNotMistakenForInvalidOutput() async throws {
        var count = 0; let client = HTTPMock.client { _ in count += 1; return (401, [:], Data()) }
        do { _ = try await client.clean(settings: settings, block: CleanBlock(id: 0, sourceIDs: [UUID()], lines: ["Texte"]), knownThemes: [], previous: nil); XCTFail() }
        catch { XCTAssertFalse(CourseError.isModelOutput(error)) }
        XCTAssertEqual(count, 1)
    }
    func testCleaningPromptCarriesKnownThemesAndPreviousSection() async throws {
        var prompt = ""
        let client = HTTPMock.client { request in
            let body = try JSONSerialization.jsonObject(with: HTTPMock.body(request)) as! [String: Any]
            prompt = ((body["messages"] as? [[String: String]])?.last?["content"]) ?? ""
            return (200, [:], try HTTPMock.completion("{\"sections\":[{\"paragraphs\":[{\"text\":\"Suite du cours.\"}]}]}"))
        }
        let previous = CleanSection(title: "Encodage", theme: "Mémoire", paragraphs: [])
        let result = try await client.clean(settings: settings, block: CleanBlock(id: 1, sourceIDs: [UUID()], lines: ["Suite du cours."]), knownThemes: ["Mémoire", "Attention"], previous: previous)
        XCTAssertTrue(prompt.contains("« Attention »")); XCTAssertTrue(prompt.contains("« Encodage »")); XCTAssertTrue(prompt.contains("[1] Suite du cours."))
        // Missing title, theme and sources are repaired from context instead of failing.
        XCTAssertEqual(result.sections.first?.theme, "Mémoire"); XCTAssertEqual(result.sections.first?.title, "Mémoire")
        XCTAssertEqual(result.sections.first?.paragraphs.first?.references.count, 1)
    }
    func testHarmonizationMapsEveryDetectedThemeAndSkipsSingleTheme() async throws {
        var count = 0
        let client = HTTPMock.client { _ in
            count += 1
            return (200, [:], try HTTPMock.completion("{\"themes\":[{\"name\":\"Mémoire de travail\",\"includes\":[\"mémoire de travail\",\"La mémoire à court terme\",\"Inventé\"]}],\"tags\":[\"Mémoire\",\"Psychologie cognitive\",\"2024\"]}"))
        }
        let index = try await client.harmonize(settings: settings, themes: [("Mémoire de travail", 2), ("La mémoire à court terme", 1), ("Attention", 1)])
        XCTAssertEqual(index.canonical("La mémoire à court terme"), "Mémoire de travail"); XCTAssertEqual(index.canonical("Attention"), "Attention")
        XCTAssertEqual(index.tags, ["memoire", "psychologie-cognitive", "t-2024"]); XCTAssertNil(index.aliases["Inventé"])
        let single = try await client.harmonize(settings: settings, themes: [("Seul", 3)])
        XCTAssertEqual(single.canonical("Seul"), "Seul"); XCTAssertEqual(count, 1)
    }
    func testCancellationInterruptsRetrySleep() async throws {
        let client = HTTPMock.client({ _ in (503, ["Retry-After": "30"], Data()) }, sleep: { _ in try await Task.sleep(for: .seconds(30)) })
        let settings = settings
        let task = Task { try await client.generate(settings: settings, task: "", source: "") }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testRedirectDelegateRefusesRemoteAndLocalRedirects() async throws {
        let delegate = LocalSessionDelegate(); let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "http://127.0.0.1:8000")!)
        let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for url in ["https://example.com", "http://127.0.0.1:8000/other"] {
            let forwarded: URLRequest? = await withCheckedContinuation { continuation in
                delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: url)!)) { continuation.resume(returning: $0) }
            }
            XCTAssertNil(forwarded)
        }
    }
}

final class CourseDataTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func testLegacyMigrationBacksUpOriginalAndKeepsTexts() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var course = Course(title: "Ancien", blocks: [StudyBlock(id: 0, source: "Source", notes: "Notes", cards: "Fiches historiques")]); course.summary = "Résumé"
        let folder = root.appendingPathComponent(course.id.uuidString); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(course)) as! [String: Any]
        for key in ["formatVersion", "state", "transcriptRevision", "synthesis", "captureMode", "resultsObsolete"] { json.removeValue(forKey: key) }
        let original = try JSONSerialization.data(withJSONObject: json); try original.write(to: folder.appendingPathComponent("course.json"))
        let repository = CourseRepository(root: root); let result = await repository.load()
        XCTAssertTrue(result.errors.isEmpty); XCTAssertEqual(result.courses.first?.formatVersion, Course.currentFormat)
        XCTAssertEqual(result.courses.first?.notes, "## Partie 1\n\nNotes"); XCTAssertEqual(result.courses.first?.cards, "Fiches historiques")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("course.v1.backup.json")), original)
    }
    func testUnreadableMetadataIsNotDeleted() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("broken"); try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let url = sub.appendingPathComponent("course.json"); let bytes = Data("not JSON".utf8); try bytes.write(to: url)
        let result = await CourseRepository(root: root).load()
        XCTAssertEqual(result.errors.count, 1); XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testManifestRecoversAudioAfterInterruptedCapture() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = CourseRepository(root: root); _ = await repository.load()
        let course = try await repository.create(title: "Crash")
        let writer = SegmentedAudioWriter(folder: root.appendingPathComponent(course.id.uuidString), segmentFrames: 1600)
        _ = try await writer.prepare(); writer.append([Float](repeating: 0.25, count: 3200)); _ = await writer.finish()
        let result = await CourseRepository(root: root).load()
        XCTAssertEqual(result.courses.first?.state, .interrupted); XCTAssertEqual(result.courses.first?.parts.count, 2)
        XCTAssertEqual(result.courses.first?.duration ?? 0, 0.2, accuracy: 0.000001)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(course.id.uuidString).appendingPathComponent("recording-manifest.json").path))
    }
    func testCardsDeduplicateAndSortBySourceTime() {
        let early = Passage(start: 1, end: 2, text: "A"); let late = Passage(start: 10, end: 11, text: "B")
        let a = StudyCard(title: "Notion", explanation: "A", question: "Question", answer: "A", references: [early.id])
        let b = StudyCard(title: "Autre", explanation: "B", question: "Question", answer: "B", references: [late.id])
        var duplicate = a; duplicate.title = "NOTION"; duplicate.id = UUID()
        var course = Course(title: "Test", parts: [AudioPart(filename: "a.wav", duration: 20, passages: [early, late])])
        course.blocks = [StudyBlock(id: 0, source: "", result: StudyResult(notes: "N", references: [early.id], cards: [b, a, duplicate]))]
        XCTAssertEqual(course.studyCards.map(\.id), [a.id, b.id])
    }
    func testCleaningBlocksCoverEverySourceOnceAndStayBounded() {
        let sources = (0..<20).map { SourcePassage(id: UUID(), start: Double($0), end: Double($0 + 1), text: String(repeating: "Notion expliquée. ", count: 15) + "Fin \($0).") }
        let long = SourcePassage(id: UUID(), start: 20, end: 30, text: String(repeating: "une phrase très longue sans aucun point ", count: 60))
        let blocks = TextChunks.cleaningBlocks(sources + [long], maxCharacters: 1000, maxLine: 300)
        XCTAssertGreaterThan(blocks.count, 1); XCTAssertTrue(blocks.allSatisfy { $0.characterCount <= 1000 && $0.lines.count == $0.sourceIDs.count })
        XCTAssertTrue(blocks.flatMap(\.lines).allSatisfy { $0.count <= 300 })
        XCTAssertEqual(blocks.flatMap(\.sourceIDs).filter { $0 != long.id }, sources.flatMap { s in Array(repeating: s.id, count: TextChunks.slices(s.text, max: 300).count) })
        XCTAssertEqual(blocks.flatMap(\.lines).filter { $0.contains("Fin") }.count, 20) // No overlap: nothing duplicated.
        XCTAssertEqual(blocks.flatMap(\.lines).joined(separator: " ").split(separator: " ").count,
                       (sources + [long]).map(\.text).joined(separator: " ").split(separator: " ").count)
    }
    @MainActor func testGateBlocksConcurrentOperations() throws {
        let gate = OperationGate(); try gate.acquire("Capture")
        XCTAssertThrowsError(try gate.acquire("Import")); gate.release(); try gate.acquire("Traitement"); XCTAssertTrue(gate.busy)
    }
    @MainActor func testCorrectionPreservesEditsAndMarksResultsObsolete() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CourseStore(root: root); while !store.ready { try await Task.sleep(for: .milliseconds(10)) }
        let id = try await store.create(title: "Test"); let passage = Passage(start: 0, end: 1, text: "Erreur")
        try await store.update(id) { $0.parts = [AudioPart(filename: "a.wav", duration: 1, passages: [passage])]; $0.editedNotes = "Mes notes"; $0.summary = "Ancien résumé" }
        try await store.editPassage(courseID: id, passageID: passage.id, text: "Correction")
        let course = try XCTUnwrap(store.course(id)); XCTAssertTrue(course.resultsObsolete); XCTAssertEqual(course.transcriptRevision, 1)
        XCTAssertEqual(course.editedNotes, "Mes notes"); XCTAssertEqual(course.summary, "Ancien résumé")
        XCTAssertTrue(course.markdown.contains("Résultats obsolètes")); XCTAssertTrue(course.transcript.contains("Correction"))
    }
}

actor FakeTranscriber: CourseTranscribing {
    let passages: [Passage]
    private(set) var calls = 0
    init(passages: [Passage]) { self.passages = passages }
    func transcribe(_ url: URL, model: String, language: String) async throws -> [Passage] { calls += 1; return passages }
    func release() { }
}

final class PipelineTests: XCTestCase {
    @MainActor func testFailedThemePassResumesWithoutRetranscribingOrRecleaning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CourseStore(root: root); while !store.ready { try await Task.sleep(for: .milliseconds(10)) }
        let id = try await store.create(title: "Test")
        let writer = SegmentedAudioWriter(folder: store.folder(id)); _ = try await writer.prepare()
        writer.append([Float](repeating: 0, count: 1600)); let written = await writer.finish()
        try await store.update(id) { $0.parts = written.parts; $0.state = .audioReady }
        let passage = Passage(start: 0, end: 0.1, text: "Euh, la notion est, euh, définie dans ce cours. Ensuite l’attention est abordée.")
        let transcriber = FakeTranscriber(passages: [passage]); var chats = 0; var failThemes = true; var cleaningPrompt = ""
        let client = HTTPMock.client { request in
            if request.url!.path == "/health" { return (200, [:], Data("{}".utf8)) }
            if request.url!.path == "/v1/models" { return (200, [:], Data("{\"data\":[{\"id\":\"local-model\"}]}".utf8)) }
            chats += 1
            if chats == 1 {
                cleaningPrompt = String(data: HTTPMock.body(request), encoding: .utf8) ?? ""
                return (200, [:], try HTTPMock.completion("{\"sections\":[{\"title\":\"Définition\",\"theme\":\"Notion\",\"paragraphs\":[{\"text\":\"La notion est définie dans ce cours.\",\"sources\":[1]}]},{\"title\":\"Attention\",\"theme\":\"Attention\",\"paragraphs\":[{\"text\":\"Ensuite l’attention est abordée.\",\"sources\":[1]}]}],\"corrections\":[{\"from\":\"notion\",\"to\":\"notion\"}]}"))
            }
            if failThemes { return (401, [:], Data()) }
            return (200, [:], try HTTPMock.completion("{\"themes\":[{\"name\":\"Notions\",\"includes\":[\"Notion\"]},{\"name\":\"Attention\",\"includes\":[\"Attention\"]}],\"tags\":[\"cognition\"]}"))
        }
        let pipeline = Pipeline(store: store, client: client, transcriber: transcriber)
        let settings = AISettings(baseURL: "http://127.0.0.1:8000/v1", model: "local-model", whisperModel: "small", language: "fr", apiKey: "")
        pipeline.process(id: id, settings: settings)
        while pipeline.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.course(id)?.state, .failed); XCTAssertEqual(store.course(id)?.documentSections.count, 2)
        XCTAssertTrue(cleaningPrompt.contains("[1] La notion est, définie dans ce cours."), "Obvious hesitations are filtered before reaching the model.")
        failThemes = false; pipeline.process(id: id, settings: settings)
        while pipeline.busy { try await Task.sleep(for: .milliseconds(10)) }
        let course = try XCTUnwrap(store.course(id))
        XCTAssertEqual(course.state, .ready); XCTAssertEqual(course.themeGroups.map(\.name), ["Notions", "Attention"])
        XCTAssertEqual(course.themeIndex?.tags, ["cognition"]); XCTAssertTrue(course.transcriptFixes.isEmpty)
        let calls = await transcriber.calls; XCTAssertEqual(calls, 1); XCTAssertEqual(chats, 3)
        let loaded = await CourseRepository(root: root).load(); XCTAssertEqual(loaded.courses.first?.themeGroups.count, 2)
        XCTAssertTrue(loaded.courses.first?.markdown.contains("## Notions") == true)
    }
    @MainActor func testModelFailureFallsBackToFilteredTextInsteadOfLosingThePassage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CourseStore(root: root); while !store.ready { try await Task.sleep(for: .milliseconds(10)) }
        let id = try await store.create(title: "Repli")
        let writer = SegmentedAudioWriter(folder: store.folder(id)); _ = try await writer.prepare()
        writer.append([Float](repeating: 0, count: 1600)); let written = await writer.finish()
        try await store.update(id) { $0.parts = written.parts; $0.state = .audioReady }
        let transcriber = FakeTranscriber(passages: [Passage(start: 0, end: 0.1, text: "Euh, la la synapse transmet le signal.")])
        let client = HTTPMock.client { request in
            if request.url!.path == "/health" { return (200, [:], Data("{}".utf8)) }
            if request.url!.path == "/v1/models" { return (200, [:], Data("{\"data\":[{\"id\":\"local-model\"}]}".utf8)) }
            return (200, [:], try HTTPMock.completion("Désolé, je ne peux pas."))
        }
        let pipeline = Pipeline(store: store, client: client, transcriber: transcriber)
        pipeline.process(id: id, settings: AISettings(baseURL: "http://127.0.0.1:8000/v1", model: "local-model", whisperModel: "small", language: "fr", apiKey: ""))
        while pipeline.busy { try await Task.sleep(for: .milliseconds(10)) }
        let course = try XCTUnwrap(store.course(id))
        XCTAssertEqual(course.state, .ready); XCTAssertEqual(course.documentSections.first?.fallback, true)
        XCTAssertEqual(course.documentSections.first?.text, "La synapse transmet le signal.")
        XCTAssertTrue(course.markdown.contains("[!caution] Nettoyage simplifié"))
    }
}

extension RapidMLXTests {
    func testRealLoopbackTransportAndRedirectProtectionAgainstFixture() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:38991/health")!); request.timeoutInterval = 1
        let response: URLResponse
        do { (_, response) = try await URLSession.shared.data(for: request) } catch { throw XCTSkip("Run the disposable HTTP fixture to exercise live loopback transport.") }
        guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-CoursLocal-Test-Fixture") == "true" else { throw XCTSkip("No CoursLocal HTTP fixture is running.") }
        let client = RapidMLXClient()
        var settings = AISettings(baseURL: "http://127.0.0.1:38991/v1", model: "fixture-model", whisperModel: "small", language: "fr", apiKey: "")
        let models = try await client.discover(baseURL: settings.baseURL, key: settings.apiKey); XCTAssertEqual(models.map(\.id), ["fixture-model"])
        let text = try await client.generate(settings: settings, task: "Vérifier le transport", source: "Données de test synthétiques")
        XCTAssertEqual(text, "Transport local vérifié")
        settings.model = "redirect-test"
        do { _ = try await client.generate(settings: settings, task: "", source: "Données de test synthétiques"); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("Redirection refusée")) }
    }
}

import SwiftUI

final class InterfaceRenderingTests: XCTestCase {
    @MainActor func testCourseInterfaceRendersWithRevisionCardsAndVerifiedReferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CourseStore(root: root); while !store.ready { try await Task.sleep(for: .milliseconds(10)) }
        let id = try await store.create(title: "Les mécanismes de la mémoire")
        let passage = Passage(start: 12, end: 20, text: "La mémoire de travail maintient temporairement les informations nécessaires à une tâche.")
        let second = Passage(start: 300, end: 320, text: "L’attention sélectionne les informations pertinentes.")
        try await store.update(id) { c in
            c.parts = [AudioPart(filename: "test.wav", duration: 7200, passages: [passage, second])]
            c.state = .ready; c.status = "Document prêt"
            c.cleanBlocks = [CleanBlock(id: 0, sourceIDs: [passage.id, second.id], lines: [passage.text, second.text], result: CleanResult(sections: [
                CleanSection(title: "Définition", theme: "Mémoire", paragraphs: [CleanParagraph(text: passage.text, references: [passage.id])]),
                CleanSection(title: "Sélection", theme: "Attention", paragraphs: [CleanParagraph(text: second.text, references: [second.id])], fallback: true)
            ], fixes: [TranscriptFix(from: "mémoire de travaille", to: "mémoire de travail")]))]
            c.themeIndex = ThemeIndex(aliases: ["Mémoire": "Mémoire de travail"], tags: ["memoire"])
            c.summary = "Ancien résumé conservé."
            c.sheet = CourseSheet(themes: [
                ThemeSheet(theme: "Mémoire de travail", summary: "La mémoire de travail maintient temporairement les informations utiles à une tâche.",
                           keyPoints: ["Capacité limitée à quelques éléments.", "Indispensable au raisonnement."],
                           definitions: [SheetDefinition(term: "Mémoire de travail", definition: "Système de maintien temporaire de l’information.")],
                           examples: ["Retenir un numéro le temps de le composer."], examHints: ["La définition tombe souvent à l’examen."]),
                ThemeSheet(theme: "Attention", summary: "L’attention filtre l’information pertinente.", keyPoints: ["Elle est sélective."])
            ], overview: "Le cours présente la mémoire de travail puis le rôle de l’attention.", takeaways: ["La mémoire de travail est limitée.", "L’attention sélectionne."],
               questions: [SheetQuestion(question: "Qu’est-ce que la mémoire de travail ?", answer: "Un système de maintien temporaire.")])
        }
        let course = try XCTUnwrap(store.course(id))
        let view = CourseView(course: course, store: store, player: CourseAudioPlayer(), gate: store.gate, assistant: CourseAssistant(store: store), process: { _ in }, reimport: {})
        let host = NSHostingView(rootView: view.preferredColorScheme(.light).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua); window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 780)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 5000)
        XCTAssertEqual(course.themeGroups.map(\.name), ["Mémoire de travail", "Attention"])
        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("CoursLocal-interface.png")
        try data.write(to: snapshot); print("Interface snapshot: \(snapshot.path)")
    }
}

final class CapturePermissionTests: XCTestCase {
    @MainActor func testMicrophoneRefusalCreatesNoCourseAndReleasesGlobalGate() async throws {
        for mode in [CaptureMode.microphone, .combined] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = CourseStore(root: root); while !store.ready { try await Task.sleep(for: .milliseconds(10)) }
            let recorder = AudioRecorder(store: store, microphonePermission: { false })
            do { _ = try await recorder.start(title: "Test", mode: mode); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("microphone")) }
            XCTAssertFalse(store.gate.busy); XCTAssertTrue(store.courses.isEmpty); XCTAssertNil(recorder.courseID)
        }
    }
    @MainActor func testSystemPermissionRefusalCreatesNoCourseAndReleasesGlobalGate() async throws {
        for mode in [CaptureMode.application, .combined] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = CourseStore(root: root); while !store.ready { try await Task.sleep(for: .milliseconds(10)) }
            let recorder = AudioRecorder(store: store, microphonePermission: { true }, shareableContent: { throw CourseError.message("Permission refusée") })
            do { _ = try await recorder.start(title: "Test", mode: mode, applicationPID: 1); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("son système")) }
            XCTAssertFalse(store.gate.busy); XCTAssertTrue(store.courses.isEmpty)
        }
    }
}

extension CourseDataTests {
    func testIdenticalQuestionsWithDifferentAnswersAreNotDiscarded() {
        let p = Passage(start: 0, end: 1, text: "Source")
        let a = StudyCard(title: "Notion", explanation: "Contexte A", question: "Question", answer: "A", references: [p.id])
        let b = StudyCard(title: "Notion", explanation: "Contexte B", question: "Question", answer: "B", references: [p.id])
        let c = Course(title: "Test", parts: [AudioPart(filename: "a.wav", duration: 1, passages: [p])], blocks: [StudyBlock(id: 0, source: "", result: StudyResult(notes: "Notes", references: [p.id], cards: [a, b]))])
        XCTAssertEqual(c.studyCards.count, 2)
    }
    func testDuplicateSourceIDsAndInvalidTimesAreRejectedWithoutCrashing() throws {
        let p = Passage(start: 0, end: 1, text: "Source")
        let c = Course(title: "Test", parts: [AudioPart(filename: "a.wav", duration: 1, passages: [p, p])])
        XCTAssertThrowsError(try c.validateStoredData())
        let invalid = Course(title: "Test", parts: [AudioPart(filename: "a.wav", duration: -1)])
        XCTAssertThrowsError(try invalid.validateStoredData())
        XCTAssertEqual(timestamp(-Double.greatestFiniteMagnitude), "00:00:00")
        XCTAssertEqual(timestamp(.nan), "00:00:00")
        XCTAssertFalse(timestamp(Double.greatestFiniteMagnitude).isEmpty)
    }
}

extension AudioContinuityTests {
    func test44100HzMicrophoneIsContinuouslyResampledTo16000Hz() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = SegmentedAudioWriter(folder: folder, segmentFrames: 3200); _ = try await writer.prepare()
        let clock = TestClock(10); let sink = AudioCaptureSink(writer: writer, mode: .microphone, clock: { clock.now() })
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
        sink.begin(); await sink.drain()
        for block in 0..<100 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441)!; buffer.frameLength = 441
            for i in 0..<441 { buffer.floatChannelData![0][i] = Float(0.5 * sin(2 * .pi * 440 * Double(block * 441 + i) / 44100)) }
            sink.enqueue(buffer, source: .microphone, hostSeconds: 10 + Double(block) / 100)
            if block % 8 == 0 { await sink.drain() }
        }
        await sink.drain(); clock.set(11); await sink.finish(); let result = await writer.finish()
        XCTAssertNil(result.error); XCTAssertEqual(result.parts.count, 5)
        var samples: [Float] = []
        for part in result.parts {
            let file = try AVAudioFile(forReading: folder.appendingPathComponent(part.filename)); let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer); samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        XCTAssertEqual(samples.count, 16000)
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        XCTAssertEqual(rms, 0.5 / sqrt(2), accuracy: 0.01)
        for boundary in stride(from: 3200, to: 16000, by: 3200) {
            XCTAssertLessThan(abs(samples[boundary] - samples[boundary - 1]), 0.15)
        }
    }
}

import Combine

extension PipelineTests {
    @MainActor func testRealImportAndCancellationPreserveCompletedAudioParts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let writer = SegmentedAudioWriter(folder: sourceFolder, segmentFrames: 620 * 16000); _ = try await writer.prepare()
        let silence = [Float](repeating: 0, count: 16000)
        for second in 0..<620 { writer.append(silence); if second % 32 == 0 { await writer.drain() } }
        let source = await writer.finish(); XCTAssertNil(source.error)
        let url = sourceFolder.appendingPathComponent(try XCTUnwrap(source.parts.first).filename)
        let store = CourseStore(root: root.appendingPathComponent("library")); while !store.ready { try await Task.sleep(for: .milliseconds(10)) }
        let pipeline = Pipeline(store: store)
        pipeline.importAudio(url, title: "Import complet")
        var deadline = Date().addingTimeInterval(30)
        while pipeline.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(pipeline.busy)
        let imported = try XCTUnwrap(store.courses.first(where: { $0.title == "Import complet" }))
        XCTAssertEqual(imported.state, .audioReady); XCTAssertEqual(imported.parts.count, 3)
        XCTAssertEqual(imported.duration, 620, accuracy: 0.01)
        for part in imported.parts { XCTAssertGreaterThan(try AVAudioFile(forReading: store.folder(imported.id).appendingPathComponent(part.filename)).length, 0) }
        let observer = store.$courses.sink { courses in
            if courses.first(where: { $0.title == "Import interrompu" })?.parts.count == 1 { pipeline.cancel() }
        }
        pipeline.importAudio(url, title: "Import interrompu")
        deadline = Date().addingTimeInterval(30)
        while pipeline.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        observer.cancel(); XCTAssertFalse(pipeline.busy); XCTAssertFalse(store.gate.busy)
        let interrupted = try XCTUnwrap(store.courses.first(where: { $0.title == "Import interrompu" }))
        XCTAssertEqual(interrupted.state, .importIncomplete); XCTAssertEqual(interrupted.parts.count, 1)
        XCTAssertGreaterThan(try AVAudioFile(forReading: store.folder(interrupted.id).appendingPathComponent(interrupted.parts[0].filename)).length, 0)
        let reloaded = await CourseRepository(root: store.root).load()
        XCTAssertEqual(reloaded.courses.first(where: { $0.id == interrupted.id })?.state, .importIncomplete)
    }
}

final class AudioPlaybackTests: XCTestCase {
    @MainActor func testSeekAcrossPartsAndUnavailablePortions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = SegmentedAudioWriter(folder: root, segmentFrames: 1600); _ = try await writer.prepare()
        writer.append([Float](repeating: 0, count: 3200)); let written = await writer.finish()
        var course = Course(title: "Lecture", parts: written.parts)
        let player = CourseAudioPlayer(); player.configure(course, folder: root)
        try player.seek(0.15, play: false)
        XCTAssertEqual(player.position, 0.15, accuracy: 0.0001); XCTAssertEqual(player.duration, 0.2, accuracy: 0.0001)
        XCTAssertFalse(player.playing); player.rate = 1.5
        course.parts[0].excluded = true; player.configure(course, folder: root)
        XCTAssertThrowsError(try player.seek(0.05, play: false)); player.stop()
    }
}

final class CleaningTests: XCTestCase {
    func testFillerFilterRemovesHesitationsStuttersAndAnnotations() {
        XCTAssertEqual(FillerFilter.clean("Euh, la mémoire de de travail, euh… stocke [Musique] l’information, hein."), "La mémoire de travail, stocke l’information.")
        XCTAssertEqual(FillerFilter.clean("c'est c'est important (rires)"), "c'est important")
        XCTAssertEqual(FillerFilter.clean("Nous nous souvenons très très bien."), "Nous nous souvenons très très bien.")
        XCTAssertEqual(FillerFilter.clean("Il a eu un heurt et une euphorie."), "Il a eu un heurt et une euphorie.")
        XCTAssertEqual(FillerFilter.clean("L’intervalle [0, 1] est fermé."), "L’intervalle [0, 1] est fermé.")
        XCTAssertEqual(FillerFilter.clean("Euh..."), "")
        XCTAssertTrue(FillerFilter.isHallucination("Sous-titrage Société Radio-Canada"))
        XCTAssertTrue(FillerFilter.isHallucination("Merci d'avoir regardé cette vidéo !"))
        XCTAssertFalse(FillerFilter.isHallucination("Merci pour votre attention, la vidéo du cours sera en ligne."))
    }
    func testCleanResponseRepairsReferencesAndRejectsInventedFixes() throws {
        let ids = [UUID(), UUID(), UUID()]
        let block = CleanBlock(id: 0, sourceIDs: ids, lines: ["la mémoire de travaille", "est limitée", "à quelques éléments"])
        let json = """
        {"sections":[{"title":"# Capacité [1]","theme":"","paragraphs":[{"text":"La mémoire de travail est limitée","sources":[1,2,9]},{"text":"à quelques éléments.","sources":[]}]}],
         "corrections":[{"from":"travaille","to":"travail"},{"from":"absent","to":"inventé"},{"from":"est","to":"Est"}]}
        """
        let result = try JSONDecoder().decode(CleanResponse.self, from: Data(json.utf8)).result(for: block, fallbackTheme: "Mémoire")
        XCTAssertEqual(result.sections.first?.title, "Capacité 1"); XCTAssertEqual(result.sections.first?.theme, "Mémoire")
        XCTAssertEqual(result.sections.first?.paragraphs.map(\.references), [[ids[0], ids[1]], [ids[1]]])
        XCTAssertEqual(result.fixes, [TranscriptFix(from: "travaille", to: "travail")])
    }
    func testAdjacentSectionsMergeAcrossBlocksAndThemesFollowFirstAppearance() {
        let p = (0..<4).map { Passage(start: Double($0 * 10), end: Double($0 * 10 + 5), text: "Passage \($0)") }
        var course = Course(title: "Fusion", parts: [AudioPart(filename: "a.wav", duration: 60, passages: p)])
        func section(_ title: String, _ theme: String, _ i: Int) -> CleanSection { CleanSection(title: title, theme: theme, paragraphs: [CleanParagraph(text: "Texte \(i)", references: [p[i].id])]) }
        course.cleanBlocks = [
            CleanBlock(id: 0, sourceIDs: [p[0].id, p[1].id], lines: ["a", "b"], result: CleanResult(sections: [section("Intro", "A", 0), section("Suite", "B", 1)])),
            CleanBlock(id: 1, sourceIDs: [p[2].id, p[3].id], lines: ["c", "d"], result: CleanResult(sections: [section("suite", "B", 2), section("Retour", "A", 3)]))
        ]
        XCTAssertEqual(course.documentSections.map(\.title), ["Intro", "Suite", "Retour"])
        XCTAssertEqual(course.documentSections[1].start, 10); XCTAssertEqual(course.documentSections[1].end, 25)
        XCTAssertEqual(course.themeGroups.map(\.name), ["A", "B"]); XCTAssertEqual(course.themeGroups[0].sections.map(\.title), ["Intro", "Retour"])
    }
    func testObsidianMarkdownHasPropertiesTagsLinksAndCallouts() {
        let p = Passage(start: 65, end: 70, text: "Le cortex préfrontal intervient.")
        var course = Course(title: "Neuro: \"cours\" 1", parts: [AudioPart(filename: "a.wav", duration: 3600, passages: [p])])
        course.cleanBlocks = [CleanBlock(id: 0, sourceIDs: [p.id], lines: [p.text], result: CleanResult(sections: [
            CleanSection(title: "Cortex", theme: "Anatomie du cerveau", paragraphs: [CleanParagraph(text: "Le cortex préfrontal intervient.", references: [p.id])])
        ], fixes: [TranscriptFix(from: "cortex pré frontal", to: "cortex préfrontal")]))]
        course.themeIndex = ThemeIndex(aliases: [:], tags: ["neurosciences"])
        course.parts[0].excluded = nil
        let md = ObsidianMarkdown.build(course)
        XCTAssertTrue(md.hasPrefix("---\ntitle: \"Neuro: \\\"cours\\\" 1\"\n"))
        XCTAssertTrue(md.contains("tags:\n  - cours\n  - neurosciences\n  - anatomie-du-cerveau\n"))
        XCTAssertTrue(md.contains("themes:\n  - \"Anatomie du cerveau\"\n"))
        XCTAssertTrue(md.contains("## Anatomie du cerveau\n\n### Cortex\n\n`00:01:05 → 00:01:10`\n\nLe cortex préfrontal intervient."))
        XCTAssertTrue(md.contains("> [!info]- Corrections de transcription (1)\n> | Transcrit | Corrigé |"))
        XCTAssertTrue(md.contains("> [!quote]- Transcription brute\n> `00:01:05` Le cortex préfrontal intervient."))
        XCTAssertFalse(md.contains("## Sommaire"), "A single theme needs no table of contents.")
        let chrono = ObsidianMarkdown.build(course, layout: .chronological, includeTranscript: false)
        XCTAssertTrue(chrono.contains("## Cortex\n\n`00:01:05 → 00:01:10` · #anatomie-du-cerveau")); XCTAssertFalse(chrono.contains("Transcription brute"))
        XCTAssertEqual(ObsidianMarkdown.filename("Cours #3 : [intro] / partie|2"), "Cours -3 - -intro- - partie-2.md")
    }
    @MainActor func testSectionEditAndThemeRenamePersist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CourseStore(root: root); while !store.ready { try await Task.sleep(for: .milliseconds(10)) }
        let id = try await store.create(title: "Édition")
        let a = Passage(start: 0, end: 1, text: "A"), b = Passage(start: 1, end: 2, text: "B")
        let first = CleanSection(title: "Partie", theme: "Brut", paragraphs: [CleanParagraph(text: "Un", references: [a.id])])
        let second = CleanSection(title: "Partie", theme: "Brut", paragraphs: [CleanParagraph(text: "Deux", references: [b.id])])
        try await store.update(id) { c in
            c.parts = [AudioPart(filename: "a.wav", duration: 2, passages: [a, b])]
            c.cleanBlocks = [CleanBlock(id: 0, sourceIDs: [a.id], lines: ["A"], result: CleanResult(sections: [first])),
                             CleanBlock(id: 1, sourceIDs: [b.id], lines: ["B"], result: CleanResult(sections: [second]))]
            c.themeIndex = ThemeIndex(aliases: ["Brut": "Thème"], tags: [])
        }
        let merged = try XCTUnwrap(store.course(id)?.documentSections.first); XCTAssertEqual(merged.ids.count, 2)
        try await store.editSection(courseID: id, sectionIDs: merged.ids, title: "Partie revue", theme: "Thème", text: "Un corrigé\n\nDeux corrigé")
        var course = try XCTUnwrap(store.course(id))
        XCTAssertEqual(course.documentSections.count, 1); XCTAssertEqual(course.documentSections[0].paragraphs.map(\.references), [[a.id], [b.id]])
        XCTAssertTrue(course.documentSections[0].edited)
        try await store.renameTheme(courseID: id, from: "Thème", to: "Thème final")
        course = try XCTUnwrap(store.course(id)); XCTAssertEqual(course.themeGroups.map(\.name), ["Thème final"])
        XCTAssertFalse(store.gate.busy)
    }
}

final class OpenRouterTests: XCTestCase {
    private var settings: AISettings {
        AISettings(baseURL: AIProvider.openRouterBase.absoluteString, model: "vendor/model", whisperModel: "small", language: "fr", apiKey: "sk-or-test", provider: .openRouter)
    }
    func testChatGoesToOpenRouterWithPrivacyPreferenceAndAttribution() async throws {
        var seen: URLRequest?; var body: [String: Any] = [:]
        let client = HTTPMock.client { request in
            seen = request; body = try JSONSerialization.jsonObject(with: HTTPMock.body(request)) as! [String: Any]
            return (200, [:], try HTTPMock.completion("Texte"))
        }
        let text = try await client.generate(settings: settings, task: "Tâche", source: "Source")
        XCTAssertEqual(text, "Texte")
        XCTAssertEqual(seen?.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "X-Title"), "CoursLocal")
        XCTAssertEqual((body["provider"] as? [String: String])?["data_collection"], "deny")
        var open = settings; open.denyDataCollection = false
        _ = try await client.generate(settings: open, task: "Tâche", source: "Source")
        XCTAssertNil(body["provider"])
    }
    func testLocalRequestsCarryNoOpenRouterPreferences() async throws {
        var body: [String: Any] = [:]
        let client = HTTPMock.client { request in body = try JSONSerialization.jsonObject(with: HTTPMock.body(request)) as! [String: Any]; return (200, [:], try HTTPMock.completion("Texte")) }
        _ = try await client.generate(settings: AISettings(baseURL: "http://127.0.0.1:8000/v1", model: "local", whisperModel: "small", language: "fr", apiKey: ""), task: "", source: "")
        XCTAssertNil(body["provider"])
    }
    func testMissingKeyCreditAndModelErrorsAreActionable() async throws {
        var noKey = settings; noKey.apiKey = ""
        do { _ = try await HTTPMock.client { _ in XCTFail(); return (200, [:], Data()) }.generate(settings: noKey, task: "", source: ""); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("clé OpenRouter")) }
        let credit = HTTPMock.client { _ in (402, [:], Data("{\"error\":{\"message\":\"Insufficient credits\"}}".utf8)) }
        do { _ = try await credit.generate(settings: settings, task: "", source: ""); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("Crédit insuffisant")); XCTAssertTrue(error.localizedDescription.contains("Insufficient credits")) }
        let refused = HTTPMock.client { _ in (401, [:], Data()) }
        do { _ = try await refused.generate(settings: settings, task: "", source: ""); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.hasPrefix("OpenRouter")); if case .unauthorized = error as? CourseError {} else { XCTFail() } }
    }
    func testCheckModelVerifiesKeyAndCatalogueAndSkipsMalformedEntries() async throws {
        var paths: [String] = []
        let client = HTTPMock.client { request in
            paths.append(request.url!.path)
            if request.url!.path == "/api/v1/key" { return (200, [:], Data("{\"data\":{\"label\":\"cours\",\"usage\":1.5,\"limit\":null,\"limit_remaining\":null,\"is_free_tier\":false}}".utf8)) }
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "text")
            return (200, [:], Data("""
            {"data":[{"id":"vendor/model","name":"Model","context_length":128000,"pricing":{"prompt":"0.0000001","completion":"0.0000004"},"architecture":{"input_modalities":["text"],"output_modalities":["text"]}},
                     {"id":"vendor/free","name":"Free","pricing":{"prompt":"0","completion":"0"}},
                     {"id":"vendor/image","architecture":{"input_modalities":["text"],"output_modalities":["image"]}},
                     {"id":42}]}
            """.utf8))
        }
        try await client.checkModel(settings: settings)
        XCTAssertEqual(paths, ["/api/v1/key", "/api/v1/models"])
        let models = try await client.openRouterModels("sk-or-test")
        XCTAssertEqual(models.map(\.id), ["vendor/free", "vendor/model"])
        XCTAssertTrue(models[0].isFree); XCTAssertEqual(models[1].twoHourCost ?? 0, 0.022, accuracy: 0.0001)
        var missing = settings; missing.model = "vendor/absent"
        do { try await client.checkModel(settings: missing); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("vendor/absent")) }
    }
    func testProviderChangeRequiresRegeneration() {
        var local = settings; local.provider = .local; local.baseURL = "http://127.0.0.1:7659/v1"
        XCTAssertNotEqual(settings.configuration(revision: 0), local.configuration(revision: 0))
    }
}

extension OpenRouterTests {
    func testReasoningModelTruncationRetriesWithLargerBudgetAndStrictSchema() async throws {
        var bodies: [[String: Any]] = []
        let valid = "{\"sections\":[{\"title\":\"Café\",\"theme\":\"Management\",\"paragraphs\":[{\"text\":\"La règle du café.\",\"sources\":[1]}]}],\"corrections\":[]}"
        let client = HTTPMock.client { request in
            bodies.append(try JSONSerialization.jsonObject(with: HTTPMock.body(request)) as! [String: Any])
            return (200, [:], try HTTPMock.completion(bodies.count == 1 ? "{\"sections\":[" : valid, reason: bodies.count == 1 ? "length" : "stop"))
        }
        let result = try await client.clean(settings: settings, block: CleanBlock(id: 0, sourceIDs: [UUID()], lines: ["La règle du café."]), knownThemes: [], previous: nil)
        XCTAssertEqual(result.sections.first?.title, "Café")
        let first = bodies[0], second = bodies[1]
        XCTAssertEqual(first["max_tokens"] as? Int, 16_000); XCTAssertEqual(second["max_tokens"] as? Int, 32_000)
        XCTAssertEqual((first["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        let format = try XCTUnwrap(first["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["corrections", "sections"]); XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }
    func testLocalServerGetsJSONModeWithoutReasoningOrSchema() async throws {
        var body: [String: Any] = [:]
        let client = HTTPMock.client { request in
            body = try JSONSerialization.jsonObject(with: HTTPMock.body(request)) as! [String: Any]
            return (200, [:], try HTTPMock.completion("{\"sections\":[{\"title\":\"A\",\"theme\":\"B\",\"paragraphs\":[{\"text\":\"Texte.\",\"sources\":[1]}]}]}"))
        }
        let local = AISettings(baseURL: "http://127.0.0.1:8000/v1", model: "local", whisperModel: "small", language: "fr", apiKey: "")
        _ = try await client.clean(settings: local, block: CleanBlock(id: 0, sourceIDs: [UUID()], lines: ["Texte."]), knownThemes: [], previous: nil)
        XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object"); XCTAssertNil(body["reasoning"])
    }
}

extension PipelineTests {
    @MainActor func testFallbackRecordsCauseAndRetryReprocessesOnlySimplifiedPassages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CourseStore(root: root); while !store.ready { try await Task.sleep(for: .milliseconds(10)) }
        let id = try await store.create(title: "Réessai")
        let writer = SegmentedAudioWriter(folder: store.folder(id)); _ = try await writer.prepare()
        writer.append([Float](repeating: 0, count: 1600)); let written = await writer.finish()
        try await store.update(id) { $0.parts = written.parts; $0.state = .audioReady }
        let transcriber = FakeTranscriber(passages: [Passage(start: 0, end: 0.1, text: "La règle du café-buf.")])
        var truncate = true; var chats = 0
        let client = HTTPMock.client { request in
            if request.url!.path == "/health" { return (200, [:], Data("{}".utf8)) }
            if request.url!.path == "/v1/models" { return (200, [:], Data("{\"data\":[{\"id\":\"local-model\"}]}".utf8)) }
            chats += 1
            if truncate { return (200, [:], try HTTPMock.completion("{", reason: "length")) }
            return (200, [:], try HTTPMock.completion("{\"sections\":[{\"title\":\"Café\",\"theme\":\"Management\",\"paragraphs\":[{\"text\":\"La règle du café.\",\"sources\":[1]}]}],\"corrections\":[{\"from\":\"café-buf\",\"to\":\"café\"}]}"))
        }
        let pipeline = Pipeline(store: store, client: client, transcriber: transcriber)
        let settings = AISettings(baseURL: "http://127.0.0.1:8000/v1", model: "local-model", whisperModel: "small", language: "fr", apiKey: "")
        pipeline.process(id: id, settings: settings)
        while pipeline.busy { try await Task.sleep(for: .milliseconds(10)) }
        var course = try XCTUnwrap(store.course(id))
        XCTAssertTrue(course.documentSections[0].fallback); XCTAssertTrue(course.documentSections[0].fallbackReason?.contains("tronquée") == true)
        XCTAssertEqual(chats, 2)
        truncate = false; pipeline.process(id: id, settings: settings, retryFallbacks: true)
        while pipeline.busy { try await Task.sleep(for: .milliseconds(10)) }
        course = try XCTUnwrap(store.course(id))
        XCTAssertEqual(course.state, .ready); XCTAssertFalse(course.documentSections[0].fallback)
        XCTAssertEqual(course.documentSections[0].title, "Café"); XCTAssertEqual(course.transcriptFixes.count, 1); XCTAssertEqual(chats, 3)
        let calls = await transcriber.calls; XCTAssertEqual(calls, 1)
    }
}

final class CourseSheetTests: XCTestCase {
    func testThemeSheetValidationCleansAndRejectsEmptySheets() throws {
        let json = """
        {"summary":" Synthèse. ","key_points":["Point A","point a"," ","Point B"],"definitions":[{"term":"Terme","definition":"Déf"},{"term":"terme","definition":"Doublon"},{"term":"","definition":"x"}],"examples":[],"exam_hints":["À savoir"]}
        """
        let sheet = try JSONDecoder().decode(ThemeSheetResponse.self, from: Data(json.utf8)).sheet(theme: "T")
        XCTAssertEqual(sheet.summary, "Synthèse."); XCTAssertEqual(sheet.keyPoints, ["Point A", "Point B"])
        XCTAssertEqual(sheet.definitions.map(\.term), ["Terme"]); XCTAssertEqual(sheet.examHints, ["À savoir"])
        XCTAssertThrowsError(try JSONDecoder().decode(ThemeSheetResponse.self, from: Data("{\"summary\":\"\",\"key_points\":[\"x\"]}".utf8)).sheet(theme: "T"))
        XCTAssertThrowsError(try JSONDecoder().decode(ThemeSheetResponse.self, from: Data("{\"summary\":\"S\",\"key_points\":[]}".utf8)).sheet(theme: "T"))
    }
    func testLongThemesAreSplitBySectionAndMerged() {
        let sections = (0..<5).map { DocumentSection(ids: [UUID()], title: "S\($0)", theme: "T", paragraphs: [CleanParagraph(text: String(repeating: "mot ", count: 100), references: [])], fallback: false, edited: false) }
        let chunks = SheetMerge.sources(for: ThemeGroup(name: "T", sections: sections), maxCharacters: 900)
        XCTAssertEqual(chunks.count, 3); XCTAssertTrue(chunks.allSatisfy { $0.hasPrefix("### S") })
        let merged = SheetMerge.merge([ThemeSheet(theme: "T", summary: "A", keyPoints: ["x", "y"]), ThemeSheet(theme: "T", summary: "B", keyPoints: ["Y", "z"])], theme: "T")
        XCTAssertEqual(merged.summary, "A\n\nB"); XCTAssertEqual(merged.keyPoints, ["x", "y", "z"])
    }
    func testObsidianNotePutsTheSheetFirstAndTheCleanTextBelow() {
        let p = Passage(start: 0, end: 5, text: "Texte.")
        var course = Course(title: "Cours", parts: [AudioPart(filename: "a.wav", duration: 10, passages: [p])])
        course.cleanBlocks = [CleanBlock(id: 0, sourceIDs: [p.id], lines: ["Texte."], result: CleanResult(sections: [
            CleanSection(title: "Section", theme: "Thème", paragraphs: [CleanParagraph(text: "Texte nettoyé.", references: [p.id])])]))]
        course.sheet = CourseSheet(themes: [ThemeSheet(theme: "Thème", summary: "Synthèse.", keyPoints: ["Point."], definitions: [SheetDefinition(term: "Terme", definition: "Sens.")], examHints: ["À l’examen."])],
                                   overview: "L’essentiel.", takeaways: ["Retenir."], questions: [SheetQuestion(question: "Pourquoi ?", answer: "Parce que.")])
        let md = ObsidianMarkdown.build(course)
        XCTAssertTrue(md.contains("> [!abstract] L’essentiel\n> L’essentiel.\n\n## À retenir\n\n- Retenir.\n\n## Thème\n\n`00:00:00`\n\nSynthèse.\n\n**Points clés**\n\n- Point."))
        XCTAssertTrue(md.contains("- **Terme** : Sens.")); XCTAssertTrue(md.contains("> [!important] Signalé par le professeur\n> - À l’examen."))
        XCTAssertTrue(md.contains("## Questions de révision\n\n> [!question]- Pourquoi ?\n> Parce que."))
        XCTAssertTrue(md.contains("## Texte nettoyé\n\n### Thème\n\n#### Section"))
        XCTAssertFalse(ObsidianMarkdown.build(course, includeText: false).contains("Texte nettoyé."))
    }
}

extension PipelineTests {
    @MainActor func testSheetIsBuiltPerThemeThenSummarizedAndResumesAfterFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CourseStore(root: root); while !store.ready { try await Task.sleep(for: .milliseconds(10)) }
        let id = try await store.create(title: "Management")
        let writer = SegmentedAudioWriter(folder: store.folder(id)); _ = try await writer.prepare()
        writer.append([Float](repeating: 0, count: 1600)); let written = await writer.finish()
        try await store.update(id) { $0.parts = written.parts; $0.state = .audioReady }
        let transcriber = FakeTranscriber(passages: [Passage(start: 0, end: 0.1, text: "La règle du café. Parler simplement aux interlocuteurs.")])
        var prompts: [String] = []; var failOverview = true
        let client = HTTPMock.client { request in
            if request.url!.path == "/health" { return (200, [:], Data("{}".utf8)) }
            if request.url!.path == "/v1/models" { return (200, [:], Data("{\"data\":[{\"id\":\"local-model\"}]}".utf8)) }
            let body = try JSONSerialization.jsonObject(with: HTTPMock.body(request)) as! [String: Any]
            let prompt = ((body["messages"] as? [[String: String]])?.last?["content"]) ?? ""; prompts.append(prompt)
            if prompt.contains("lignes numérotées") {
                return (200, [:], try HTTPMock.completion("{\"sections\":[{\"title\":\"Café\",\"theme\":\"Communication\",\"paragraphs\":[{\"text\":\"La règle du café.\",\"sources\":[1]}]},{\"title\":\"Simplicité\",\"theme\":\"Interlocuteurs\",\"paragraphs\":[{\"text\":\"Parler simplement aux interlocuteurs.\",\"sources\":[1]}]}],\"corrections\":[]}"))
            }
            if prompt.contains("thèmes détectés") { return (200, [:], try HTTPMock.completion("{\"themes\":[{\"name\":\"Communication\",\"includes\":[\"Communication\"]},{\"name\":\"Interlocuteurs\",\"includes\":[\"Interlocuteurs\"]}],\"tags\":[]}")) }
            if prompt.contains("fiche de cours de cette partie") {
                XCTAssertTrue(prompt.contains("### ")); XCTAssertFalse(prompt.contains("[1]"), "The sheet is written from the cleaned text, not the raw transcript.")
                return (200, [:], try HTTPMock.completion("{\"summary\":\"Synthèse.\",\"key_points\":[\"Point.\"],\"definitions\":[],\"examples\":[],\"exam_hints\":[]}"))
            }
            if failOverview { return (200, [:], try HTTPMock.completion("pas du JSON")) }
            return (200, [:], try HTTPMock.completion("{\"overview\":\"L’essentiel.\",\"takeaways\":[\"Retenir.\"],\"questions\":[{\"question\":\"Q ?\",\"answer\":\"R.\"}]}"))
        }
        let pipeline = Pipeline(store: store, client: client, transcriber: transcriber)
        var settings = AISettings(baseURL: "http://127.0.0.1:8000/v1", model: "local-model", whisperModel: "small", language: "fr", apiKey: ""); settings.generateSheet = true
        pipeline.process(id: id, settings: settings)
        while pipeline.busy { try await Task.sleep(for: .milliseconds(10)) }
        var course = try XCTUnwrap(store.course(id))
        XCTAssertEqual(course.state, .failed); XCTAssertEqual(course.sheet?.themes.count, 2); XCTAssertFalse(course.sheetComplete)
        XCTAssertEqual(prompts.count, 6) // cleaning, themes, two theme sheets, two overview attempts
        failOverview = false; pipeline.process(id: id, settings: settings)
        while pipeline.busy { try await Task.sleep(for: .milliseconds(10)) }
        course = try XCTUnwrap(store.course(id))
        XCTAssertEqual(course.state, .ready); XCTAssertTrue(course.sheetComplete); XCTAssertEqual(prompts.count, 7)
        XCTAssertEqual(course.orderedThemeSheets.map(\.theme), ["Communication", "Interlocuteurs"])
        XCTAssertEqual(course.sheet?.questions.first?.answer, "R.")
        pipeline.process(id: id, settings: settings, regenerateSheet: true)
        while pipeline.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(prompts.count, 10); XCTAssertTrue(store.course(id)?.sheetComplete == true)
        let calls = await transcriber.calls; XCTAssertEqual(calls, 1)
    }
}

final class CourseChatTests: XCTestCase {
    /// Three themed sections, each built from one passage at a known time.
    private func course(_ texts: [(title: String, text: String, start: Double)]) -> Course {
        let passages = texts.map { Passage(start: $0.start, end: $0.start + 30, text: $0.text) }
        var course = Course(title: "Psychologie cognitive", parts: [AudioPart(filename: "a.wav", duration: 3600, passages: passages)])
        course.cleanBlocks = [CleanBlock(id: 0, sourceIDs: passages.map(\.id), lines: passages.map(\.text), result: CleanResult(sections: zip(texts, passages).map { item, passage in
            CleanSection(title: item.title, theme: item.title, paragraphs: [CleanParagraph(text: item.text, references: [passage.id])])
        }))]
        return course
    }
    private let sections = [(title: "Mémoire", text: "La mémoire de travail maintient les informations.", start: 12.0),
                            (title: "Attention", text: "L’attention sélective filtre les stimulus pertinents.", start: 600.0),
                            (title: "Langage", text: "Le lexique mental regroupe les mots connus.", start: 1500.0)]

    func testShortCourseIsSentWholeWithTimestamps() {
        let context = ChatContext.build(course: course(sections), question: "Que dit le cours ?", previous: nil, budget: 10_000)
        XCTAssertFalse(context.partial)
        XCTAssertTrue(context.text.contains("## Mémoire (Mémoire) [00:00:12]\n[00:00:12] La mémoire de travail"))
        let order = ["Mémoire", "Attention", "Langage"].map { context.text.range(of: "## " + $0)!.lowerBound }
        XCTAssertEqual(order, order.sorted())
    }

    func testLongCourseKeepsMatchingSectionsInCourseOrder() {
        let long = sections.map { ($0.title, $0.text + String(repeating: " Développement du propos.", count: 20), $0.start) }
        let context = ChatContext.build(course: course(long), question: "Comment fonctionne la sélection attentionnelle ?", previous: "Et la mémoire de travail ?", budget: 1300)
        XCTAssertTrue(context.partial)
        XCTAssertTrue(context.text.contains("## Attention")); XCTAssertTrue(context.text.contains("## Mémoire")); XCTAssertFalse(context.text.contains("## Langage"))
        XCTAssertLessThan(context.text.range(of: "## Mémoire")!.lowerBound, context.text.range(of: "## Attention")!.lowerBound)
    }

    func testTranscriptIsUsedBeforeTheDocumentExists() {
        var raw = course(sections); raw.cleanBlocks = []
        let context = ChatContext.build(course: raw, question: "lexique", previous: nil, budget: 10_000)
        XCTAssertTrue(context.text.contains("[00:25:00] Le lexique mental"))
    }

    func testKeysFoldAccentsPluralsAndEndings() {
        XCTAssertTrue(ChatContext.keys("Définitions").isSubset(of: ChatContext.keys("définir la notion")))
        XCTAssertTrue(ChatContext.keys("pourquoi est-ce que le cours").isEmpty)
    }

    func testCourseWithoutChatStillDecodes() throws {
        var data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(course(sections))) as! [String: Any]
        data["chat"] = nil
        let decoded = try JSONDecoder().decode(Course.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertEqual(decoded.chat, [])
    }

    func testAnswerSendsHistoryAndKeepsTruncatedText() async throws {
        let settings = AISettings(baseURL: "http://127.0.0.1:8000/v1", model: "local-model", whisperModel: "small", language: "fr", apiKey: "")
        let client = HTTPMock.client { request in
            let body = try JSONSerialization.jsonObject(with: HTTPMock.body(request)) as! [String: Any]
            let messages = body["messages"] as! [[String: String]]
            XCTAssertEqual(messages.map { $0["role"]! }, ["system", "user", "assistant", "user"])
            XCTAssertEqual(messages.last?["content"], "Et pourquoi ?"); XCTAssertNil(body["response_format"])
            return (200, [:], try HTTPMock.completion("Parce que", reason: "length"))
        }
        let history = [ChatMessage(role: .user, text: "Qu’est-ce que l’attention ?"), ChatMessage(role: .assistant, text: "Un filtre [00:10:00].")]
        let answer = try await client.answer(settings: settings, system: "Système", history: history, question: "Et pourquoi ?")
        XCTAssertEqual(answer, "Parce que … (réponse tronquée)")
    }
}
