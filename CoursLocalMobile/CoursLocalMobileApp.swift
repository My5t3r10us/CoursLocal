import SwiftUI

@main
@MainActor
struct CoursLocalMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library: RecordingLibrary
    @StateObject private var recorder: MobileRecorder
    @StateObject private var link: MacLink
    @StateObject private var remote: MacRemote
    init() {
        let library = RecordingLibrary(), recorder = MobileRecorder(library: library), link = MacLink(library: library)
        _remote = StateObject(wrappedValue: MacRemote(link: link, recorder: recorder, library: library))
        // A finished recording leaves for the Mac as soon as it is visible.
        recorder.onFinished = { [weak link] _ in if link?.autoSend == true { link?.sendPending() } }
        _library = StateObject(wrappedValue: library); _recorder = StateObject(wrappedValue: recorder); _link = StateObject(wrappedValue: link)
    }
    var body: some Scene {
        WindowGroup {
            MobileContentView(library: library, recorder: recorder, link: link, remote: remote)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active:
                        recorder.becameActive(); link.startBrowsing(); remote.start()
                        if link.autoSend { link.sendPending() }
                    // While recording, or reachable on purpose, the app keeps running: so do discovery and control.
                    case .background: if recorder.recording == nil && !recorder.keepAlive { link.stopBrowsing() }
                    default: break
                    }
                }
        }
    }
}
