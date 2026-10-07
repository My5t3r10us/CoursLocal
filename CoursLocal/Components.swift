import SwiftUI
import AppKit
import AVFoundation

// MARK: - Audio player

@MainActor
final class CourseAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing = false
    @Published private(set) var position = 0.0
    @Published var rate: Float = 1 { didSet { audio?.rate = rate } }
    @Published private(set) var duration = 0.0
    @Published private(set) var currentCourseID: UUID?
    private var audio: AVAudioPlayer?
    private var course: Course?
    private var folder: URL?
    private var index = 0
    private var offset = 0.0
    private var timer: Timer?
    func configure(_ course: Course, folder: URL) {
        if self.course?.id != course.id { stop(); position = 0 }
        self.course = course; currentCourseID = course.id; self.folder = folder; duration = course.duration
    }
    func toggle() throws {
        if playing { audio?.pause(); playing = false }
        else { try seek(position >= duration ? 0 : position, play: true) }
    }
    func skip(_ seconds: Double) throws { try seek(max(0, min(duration, position + seconds))) }
    func seek(_ seconds: Double, play: Bool? = nil) throws {
        guard let course, let folder, course.duration > 0 else { return }
        let shouldPlay = play ?? playing
        let target = max(0, min(seconds, course.duration - 0.001)); var start = 0.0
        for (i, part) in course.parts.enumerated() {
            if target < start + part.duration {
                guard part.excluded != true, part.problem == nil else { throw CourseError.message("Cette portion audio est indisponible.") }
                if index != i || audio == nil {
                    audio?.stop(); audio = try AVAudioPlayer(contentsOf: folder.appendingPathComponent(part.filename))
                    audio?.delegate = self; audio?.enableRate = true; audio?.prepareToPlay(); index = i
                }
                offset = start; position = target; audio?.currentTime = target - start; audio?.rate = rate
                playing = shouldPlay
                if shouldPlay {
                    guard audio?.play() == true else { playing = false; throw CourseError.message("Lecture audio impossible.") }
                    startTimer()
                } else { audio?.pause() }
                return
            }
            start += part.duration
        }
    }
    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in
            guard let self, self.playing, let audio = self.audio else { return }; self.position = self.offset + audio.currentTime
        } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stop() { audio?.stop(); audio = nil; playing = false; timer?.invalidate(); timer = nil }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.audio === player, let course = self.course else { return }
            let next = self.index + 1; self.audio = nil
            var start = self.offset + course.parts[self.index].duration
            for i in next..<course.parts.count {
                let part = course.parts[i]
                if part.excluded != true && part.problem == nil && part.duration > 0 {
                    do { try self.seek(start, play: true) } catch { self.stop() }; return
                }
                start += part.duration
            }
            self.stop(); self.position = course.duration
        }
    }
}

// MARK: - Presentation helpers

extension CourseState {
    var label: String {
        switch self {
        case .new: return "Nouveau"; case .recording: return "Enregistrement"; case .paused: return "En pause"
        case .audioReady: return "Audio prêt"; case .importing: return "Import"; case .importIncomplete: return "Import incomplet"
        case .transcribing: return "Transcription"; case .generating: return "Nettoyage"; case .ready: return "Prêt"
        case .interrupted: return "Interrompu"; case .failed: return "Échec"
        }
    }
    var symbol: String {
        switch self {
        case .new: return "doc"; case .recording: return "record.circle.fill"; case .paused: return "pause.circle.fill"
        case .audioReady: return "waveform"; case .importing: return "square.and.arrow.down"; case .importIncomplete: return "exclamationmark.triangle.fill"
        case .transcribing: return "text.bubble"; case .generating: return "wand.and.stars"; case .ready: return "checkmark.circle.fill"
        case .interrupted: return "pause.circle"; case .failed: return "xmark.octagon.fill"
        }
    }
    var tint: Color {
        switch self {
        case .recording, .failed: return .red
        case .paused, .interrupted, .importIncomplete: return .orange
        case .importing, .transcribing, .generating: return .blue
        case .ready: return .green
        case .audioReady: return .purple
        case .new: return .gray
        }
    }
}

extension CaptureMode {
    var symbol: String {
        switch self { case .microphone: return "mic.fill"; case .application: return "macwindow"; case .combined: return "waveform.and.mic" }
    }
    var detail: String {
        switch self {
        case .microphone: return "Cours en présentiel"
        case .application: return "Zoom, Teams, navigateur…"
        case .combined: return "Visio avec tes questions"
        }
    }
}

func shortDuration(_ seconds: Double) -> String {
    let minutes = Int((seconds.isFinite ? max(0, seconds) : 0) / 60)
    if minutes < 1 { return "< 1 min" }
    return minutes < 60 ? "\(minutes) min" : String(format: "%d h %02d", minutes / 60, minutes % 60)
}

enum ThemePalette {
    static let colors: [Color] = [.blue, .purple, .orange, .teal, .pink, .green, .indigo, .brown, .mint, .cyan]
    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
}

// MARK: - Small views

struct StateBadge: View {
    let state: CourseState
    var body: some View {
        Label(state.label, systemImage: state.symbol)
            .font(.caption.weight(.semibold)).foregroundStyle(state.tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(state.tint.opacity(0.12)))
    }
}

struct ThemeChip: View {
    let name: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 7, height: 7); Text(name).lineLimit(1) }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.1)))
    }
}

struct MetaLabel: View {
    let symbol: String
    let text: String
    var body: some View { Label(text, systemImage: symbol).font(.callout).foregroundStyle(.secondary).labelStyle(.titleAndIcon) }
}

struct NoticeView<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var message: String? = nil
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                if let message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}

extension NoticeView where Actions == EmptyView {
    init(symbol: String, tint: Color, title: String, message: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, message: message) { EmptyView() }
    }
}

struct LevelMeter: View {
    let label: String
    let value: Double
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * min(1, max(0, value)))
                }
            }.frame(width: 90, height: 5)
        }.animation(.linear(duration: 0.1), value: value)
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium)).symbolRenderingMode(.multicolor)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

// MARK: - Player bar

struct PlayerBar: View {
    let course: Course
    @ObservedObject var player: CourseAudioPlayer
    let folder: URL
    let disabled: Bool
    let onError: (String) -> Void
    private var current: Bool { player.currentCourseID == course.id }
    private var position: Double { current ? player.position : 0 }
    var body: some View {
        HStack(spacing: 14) {
            Button { act { try player.skip(-15) } } label: { Image(systemName: "gobackward.15") }.help("Reculer de 15 s")
            Button { act { try player.toggle() } } label: {
                Image(systemName: player.playing && current ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 26))
            }.help(player.playing && current ? "Pause" : "Lecture")
            Button { act { try player.skip(15) } } label: { Image(systemName: "goforward.15") }.help("Avancer de 15 s")
            Text(timestamp(position)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Slider(value: Binding(get: { position }, set: { value in act { try player.seek(value) } }), in: 0...max(0.001, course.duration))
                .controlSize(.small)
            Text(timestamp(course.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Menu {
                Picker("Vitesse", selection: $player.rate) { ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { Text(String(format: "%g×", $0)).tag($0) } }
                    .pickerStyle(.inline)
            } label: { Text(String(format: "%g×", player.rate)).font(.caption.monospacedDigit().weight(.semibold)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Vitesse de lecture")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .disabled(disabled || course.duration <= 0)
    }
    private func act(_ action: () throws -> Void) {
        do { player.configure(course, folder: folder); try action() } catch { onError(error.localizedDescription) }
    }
}

// MARK: - Markdown (earlier results)

struct MarkdownContent: View {
    let text: String
    let duration: Double
    var validTimes: [Double] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("#### ") { rendered(String(line.dropFirst(5))).font(.headline) }
                else if line.hasPrefix("### ") { rendered(String(line.dropFirst(4))).font(.title3.bold()).padding(.top, 6) }
                else if line.hasPrefix("## ") { rendered(String(line.dropFirst(3))).font(.title2.bold()).padding(.top, 6) }
                else if line.hasPrefix("# ") { rendered(String(line.dropFirst(2))).font(.title.bold()).padding(.top, 8) }
                else if line.hasPrefix("- ") || line.hasPrefix("* ") { HStack(alignment: .top) { Text("•"); rendered(String(line.dropFirst(2))) } }
                else if line.hasPrefix("> ") { rendered(String(line.dropFirst(2))).foregroundStyle(.secondary) }
                else { rendered(line.isEmpty ? " " : line) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
    private func rendered(_ string: String) -> Text {
        var linked = string
        if let regex = try? NSRegularExpression(pattern: "\\[([0-9]{2}):([0-9]{2}):([0-9]{2})\\]") {
            for match in regex.matches(in: string, range: NSRange(string.startIndex..., in: string)).reversed() {
                guard let range = Range(match.range, in: string) else { continue }
                let label = String(string[range]); let values = label.dropFirst().dropLast().split(separator: ":").compactMap { Double($0) }
                if values.count == 3 {
                    let seconds = values[0] * 3600 + values[1] * 60 + values[2]
                    if seconds < duration && validTimes.contains(where: { Int($0) == Int(seconds) }) { linked.replaceSubrange(Range(match.range, in: linked)!, with: "\(label)(courslocal://time/\(seconds))") }
                }
            }
        }
        return Text((try? AttributedString(markdown: linked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(linked))
    }
}

// MARK: - Editors

struct TextEditorSheet: View {
    let title: String
    var subtitle: String? = nil
    var singleLine = false
    let save: (String) async throws -> Void
    @State private var text: String
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    init(title: String, subtitle: String? = nil, singleLine: Bool = false, original: String, save: @escaping (String) async throws -> Void) {
        self.title = title; self.subtitle = subtitle; self.singleLine = singleLine; self.save = save; _text = State(initialValue: original)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.bold())
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            if singleLine { TextField(title, text: $text).textFieldStyle(.roundedBorder).font(.title3).onSubmit(commit) }
            else { EditorBox(text: $text) }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Enregistrer", action: commit).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(saving || (singleLine && text.trimmed.isEmpty))
            }
        }
        .padding(24).frame(width: singleLine ? 460 : 680, height: singleLine ? nil : 480).interactiveDismissDisabled(saving)
    }
    private func commit() {
        saving = true; Task { do { try await save(text); dismiss() } catch { self.error = error.localizedDescription }; saving = false }
    }
}

struct EditorBox: View {
    @Binding var text: String
    var body: some View {
        TextEditor(text: $text).font(.system(size: 14)).lineSpacing(3).scrollContentBackground(.hidden).padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

struct SectionEditorSheet: View {
    let themes: [String]
    let save: (String, String, String) async throws -> Void
    @State private var title: String
    @State private var theme: String
    @State private var text: String
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    init(section: DocumentSection, themes: [String], save: @escaping (String, String, String) async throws -> Void) {
        self.themes = themes; self.save = save
        _title = State(initialValue: section.title); _theme = State(initialValue: section.theme); _text = State(initialValue: section.text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Modifier la section").font(.title3.bold())
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Titre").foregroundStyle(.secondary)
                    TextField("Titre", text: $title).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Thème").foregroundStyle(.secondary)
                    HStack {
                        TextField("Thème", text: $theme).textFieldStyle(.roundedBorder)
                        Menu { ForEach(themes, id: \.self) { name in Button(name) { theme = name } } } label: { Image(systemName: "list.bullet") }
                            .menuStyle(.borderlessButton).fixedSize().help("Choisir un thème existant")
                    }
                }
            }
            Text("Une ligne vide sépare deux paragraphes.").font(.caption).foregroundStyle(.secondary)
            EditorBox(text: $text)
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption) }
            HStack {
                Text("Laisser le texte vide supprime la section.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Enregistrer") {
                    saving = true; Task { do { try await save(title, theme, text); dismiss() } catch { self.error = error.localizedDescription }; saving = false }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(saving || title.trimmed.isEmpty || theme.trimmed.isEmpty)
            }
        }
        .padding(24).frame(width: 720, height: 560).interactiveDismissDisabled(saving)
    }
}
