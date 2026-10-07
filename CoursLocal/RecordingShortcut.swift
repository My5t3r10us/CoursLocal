import SwiftUI
import AppKit
import Carbon.HIToolbox
import Combine

// MARK: - Shortcut

/// A key combination stored in the preferences. Modifiers use the Carbon masks expected by RegisterEventHotKey.
struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String
    static let standard = HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | cmdKey), key: "R")
    static let defaultsKey = "recordingHotKey"

    static var current: HotKey? {
        guard UserDefaults.standard.object(forKey: "recordingHotKeyEnabled") as? Bool ?? true else { return nil }
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return .standard }
        return (try? JSONDecoder().decode(HotKey.self, from: data)) ?? .standard
    }
    static func save(_ hotKey: HotKey) {
        UserDefaults.standard.set(try? JSONEncoder().encode(hotKey), forKey: defaultsKey)
    }

    /// Returns nil when the event has no ⌘, ⌥ or ⌃: a global shortcut on a bare key would steal typing everywhere.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        let names: [Int: String] = [kVK_Space: "Espace", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
                                    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        let key = names[Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !key.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers), key: key)
    }
    init(keyCode: UInt32, modifiers: UInt32, key: String) { self.keyCode = keyCode; self.modifiers = modifiers; self.key = key }

    var label: String {
        let m = Int(modifiers)
        return (m & controlKey != 0 ? "⌃" : "") + (m & optionKey != 0 ? "⌥" : "") + (m & shiftKey != 0 ? "⇧" : "") + (m & cmdKey != 0 ? "⌘" : "") + key
    }
}

/// System-wide shortcut through Carbon: it works while another app is in front and needs no accessibility permission.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    static let changed = Notification.Name("HotKeyCenterChanged")
    var action: (() -> Void)?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var failure: String?

    func reload() {
        unregister()
        guard let hotKey = HotKey.current else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x434C_5243), id: 1) // "CLRC"
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, id, GetApplicationEventTarget(), 0, &reference)
        failure = status == noErr ? nil : "Le raccourci \(hotKey.label) est déjà utilisé par macOS ou une autre application."
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
    /// Lets the preferences capture the current combination without triggering a recording.
    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil; failure = nil
    }
    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in HotKeyCenter.shared.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

// MARK: - Quick recording

/// Starts or stops a recording from the global shortcut and shows the floating pill while a recording runs.
@MainActor
final class QuickRecorder: ObservableObject {
    private let store: CourseStore
    private let recorder: AudioRecorder
    private var panel: NSPanel?
    private var observation: AnyCancellable?

    init(store: CourseStore, recorder: AudioRecorder) {
        self.store = store; self.recorder = recorder
        HotKeyCenter.shared.action = { [weak self] in self?.toggle() }
        HotKeyCenter.shared.reload()
        observation = recorder.$courseID.receive(on: RunLoop.main).sink { [weak self] id in
            if id != nil { self?.showPanel() } else { self?.hidePanel() }
        }
    }

    func toggle() {
        if recorder.courseID != nil {
            guard !recorder.stopping else { return }
            Task { await recorder.stop() }
            return
        }
        guard !recorder.starting, store.ready else { return }
        let mode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: "hotKeyCaptureMode") ?? "") ?? .microphone
        // The application captured is the one in front when the shortcut is pressed (Zoom, Teams, a browser…).
        let front = NSWorkspace.shared.frontmostApplication
        let pid = mode.usesApplication && front?.processIdentifier != ProcessInfo.processInfo.processIdentifier ? front?.processIdentifier : nil
        Task {
            do { _ = try await recorder.start(title: "", mode: mode, applicationPID: pid) }
            catch {
                store.error = mode.usesApplication && pid == nil
                    ? "Mets au premier plan l’application à capturer avant d’utiliser le raccourci."
                    : error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func showPanel() {
        guard UserDefaults.standard.object(forKey: "recordingPill") as? Bool ?? true else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 28))
        }
        panel.alphaValue = 0; panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }
    private func hidePanel() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) { [weak self] in
            Task { @MainActor in if self?.recorder.courseID == nil { panel.orderOut(nil) } }
        }
    }
    private func makePanel() -> NSPanel {
        let host = FirstMouseHostingView(rootView: RecordingPill(recorder: recorder))
        host.setFrameSize(host.fittingSize)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isFloatingPanel = true; panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }
}

/// The pill is clickable at once, even though its panel never becomes key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Floating pill

struct RecordingPill: View {
    @ObservedObject var recorder: AudioRecorder
    @State private var history = [Double](repeating: 0, count: 11)
    @State private var hoveringStop = false
    private let tick = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()
    private static let pink = Color(red: 0.93, green: 0.55, blue: 0.72)

    var body: some View {
        HStack(spacing: 0) {
            Button { Task { await recorder.togglePause() } } label: {
                ZStack {
                    if recorder.paused { Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange) }
                    else { Circle().fill(Self.pink).frame(width: 9, height: 9).opacity(recorder.stopping ? 0.4 : 1) }
                }.frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(recorder.stopping)
            .help(recorder.paused ? "Reprendre l’enregistrement" : "Mettre en pause")
            Spacer(minLength: 10)
            if recorder.stopping {
                ProgressView().controlSize(.small).frame(width: 64)
            } else {
                HStack(spacing: 3) {
                    ForEach(history.indices, id: \.self) { i in
                        Capsule().fill(Self.pink.opacity(recorder.paused ? 0.35 : 1)).frame(width: 3.5, height: 3.5 + history[i] * 14)
                    }
                }
                .frame(height: 18).animation(.easeOut(duration: 0.08), value: history)
            }
            Spacer(minLength: 10)
            Text(Self.clock(recorder.elapsed))
                .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white.opacity(recorder.paused ? 0.45 : 0.85))
                .contentTransition(.numericText()).fixedSize()
            Spacer(minLength: 10)
            Button { Task { await recorder.stop() } } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(hoveringStop ? 0.2 : 0.1)))
            }
            .buttonStyle(.plain).disabled(recorder.stopping).onHover { hoveringStop = $0 }
            .help("Terminer l’enregistrement")
        }
        .padding(.leading, 8).padding(.trailing, 7)
        .frame(width: 236, height: 40)
        .background(Capsule().fill(Color(white: 0.16)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        .onReceive(tick) { _ in
            let value = recorder.paused || recorder.stopping ? 0 : Self.loudness(max(recorder.level, recorder.applicationLevel))
            history.removeFirst(); history.append(value)
        }
    }

    /// Compact chrono: 4:07, then 1:04:07 past one hour.
    private static func clock(_ seconds: Double) -> String {
        let value = Int(seconds.isFinite ? max(0, seconds) : 0)
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }

    /// RMS to a 0…1 scale in decibels, so normal speech moves the bars visibly.
    private static func loudness(_ rms: Double) -> Double {
        guard rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(rms) + 50) / 40))
    }
}

// MARK: - Preferences

/// Captures the next key combination typed while it is listening.
struct HotKeyRecorder: View {
    @State private var hotKey = HotKey.current ?? .standard
    @State private var listening = false
    @State private var monitor: Any?
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button { listening ? stop() : listen() } label: {
                Text(listening ? "Tape le raccourci…" : hotKey.label).monospaced().frame(minWidth: 120)
            }
            .tint(listening ? .accentColor : nil).buttonStyle(.bordered)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { failure = HotKeyCenter.shared.failure }
        .onReceive(NotificationCenter.default.publisher(for: HotKeyCenter.changed)) { _ in failure = HotKeyCenter.shared.failure }
        .onDisappear { if listening { stop() } }
    }
    private func listen() {
        listening = true; failure = nil
        HotKeyCenter.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            guard let captured = HotKey(event: event) else { NSSound.beep(); return nil }
            hotKey = captured; HotKey.save(captured); stop()
            return nil
        }
    }
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; listening = false
        HotKeyCenter.shared.reload()
    }
}
