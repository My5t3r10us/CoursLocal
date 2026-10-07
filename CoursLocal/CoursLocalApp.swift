import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var recorder: AudioRecorder?
    weak var pipeline: Pipeline?
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        guard recorder?.courseID != nil || pipeline?.busy == true else { return .terminateNow }
        terminating = true
        Task {
            pipeline?.cancel()
            await recorder?.stop(interruption: "Application quittée pendant l’enregistrement.")
            // Whisper cancellation may wait for the current segment. Its previous checkpoints are durable.
            while pipeline?.busy == true { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
@MainActor
struct CoursLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: CourseStore
    @StateObject private var recorder: AudioRecorder
    @StateObject private var pipeline: Pipeline
    @StateObject private var player: CourseAudioPlayer
    @StateObject private var quickRecorder: QuickRecorder
    @StateObject private var phoneReceiver: PhoneReceiver
    init() {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
        let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("CoursLocal-test-host-" + UUID().uuidString)
        let store = CourseStore(root: testing ? testRoot.appendingPathComponent("library") : nil); let pipeline = Pipeline(store: store); let recorder = AudioRecorder(store: store)
        recorder.onCompleted = { [weak pipeline, weak store] id in
            guard UserDefaults.standard.object(forKey: "autoProcess") as? Bool ?? true else { return }
            do { pipeline?.process(id: id, settings: try AISettings.current()) } catch { store?.error = error.localizedDescription }
        }
        let phoneReceiver = PhoneReceiver(store: store, inbox: testing ? testRoot.appendingPathComponent("iphone") : nil)
        phoneReceiver.onImported = recorder.onCompleted
        phoneReceiver.remote.onError = { [weak store] message in store?.error = message }
        if !testing && UserDefaults.standard.object(forKey: PhoneReceiver.enabledKey) as? Bool ?? true { phoneReceiver.start() }
        _phoneReceiver = StateObject(wrappedValue: phoneReceiver)
        _store = StateObject(wrappedValue: store); _recorder = StateObject(wrappedValue: recorder)
        _pipeline = StateObject(wrappedValue: pipeline); _player = StateObject(wrappedValue: CourseAudioPlayer())
        _quickRecorder = StateObject(wrappedValue: QuickRecorder(store: store, recorder: recorder))
    }
    var body: some Scene {
        WindowGroup {
            ContentView(store: store, recorder: recorder, pipeline: pipeline, player: player, phoneReceiver: phoneReceiver)
                .onAppear { delegate.recorder = recorder; delegate.pipeline = pipeline }
                .frame(minWidth: 1080, minHeight: 720)
        }
        Settings { PreferencesView().environmentObject(phoneReceiver) }
    }
}
