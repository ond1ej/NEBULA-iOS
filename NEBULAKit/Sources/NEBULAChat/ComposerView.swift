import AVFoundation
import NEBULACore
import NEBULADesignSystem
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Message composer: growing text field, photo / file attachments, voice notes, send ↔ stop.
struct ComposerView: View {
    @Binding var text: String
    let isRunning: Bool
    let agentName: String
    let onSend: (String, [Attachment]) -> Void
    let onStop: () -> Void
    let upload: (String, String, Data) async throws -> Attachment

    @State private var attachments: [Attachment] = []
    @State private var uploading = 0
    @State private var uploadError: String?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var recorder = VoiceRecorder()
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canSend: Bool {
        uploading == 0 && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var body: some View {
        VStack(spacing: NSpace.s) {
            if !attachments.isEmpty || uploading > 0 || uploadError != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NSpace.s) {
                        ForEach(attachments) { a in
                            HStack(spacing: 4) {
                                Image(systemName: a.isAudio ? "waveform" : a.isImage ? "photo" : "doc")
                                Text(a.name ?? "").lineLimit(1)
                                Button { attachments.removeAll { $0.id == a.id } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }.buttonStyle(.plain).accessibilityLabel(Text("Remove attachment"))
                            }
                            .font(.footnote).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(NColor.surfaceSunken))
                        }
                        if uploading > 0 { ProgressView().controlSize(.small) }
                        if let e = uploadError { Text(e).font(.footnote).foregroundStyle(NColor.danger) }
                    }
                    .padding(.horizontal, NSpace.l)
                }
            }
            HStack(alignment: .bottom, spacing: NSpace.s) {
                Menu {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 5, matching: .images) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                    }
                    Button { showFiles = true } label: { Label("File", systemImage: "doc") }
                } label: {
                    Image(systemName: "plus").font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(NColor.surfaceSunken))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Add attachment"))

                if recorder.isRecording {
                    RecordingBar(recorder: recorder)
                } else {
                    TextField(text: $text, axis: .vertical) {
                        Text("Message \(agentName.isEmpty ? "agenta" : agentName)")
                    }
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(NColor.surface))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(NColor.separator, lineWidth: 0.5))
                    #if os(macOS)
                    .onSubmit(send)
                    #endif
                }
                trailingButton
            }
            .padding(.horizontal, NSpace.m)
        }
        .padding(.top, NSpace.s)
        .padding(.bottom, NSpace.s)
        .background(.bar)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            for item in items { Task { await attachPhoto(item) } }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { for u in urls { Task { await attachFile(u) } } }
        }
        .nAnimation(NMotion.snappy, value: canSend)
        .nAnimation(NMotion.snappy, value: recorder.isRecording)
    }

    @ViewBuilder private var trailingButton: some View {
        if recorder.isRecording {
            circleButton("arrow.up", tint: NColor.accent, label: "Send voice message") {
                Task { await finishRecording() }
            }
        } else if canSend {
            circleButton("arrow.up", tint: NColor.accent, label: "Send", action: send)
                .keyboardShortcut(.return, modifiers: .command)
                .transition(.scale.combined(with: .opacity))
        } else if isRunning {
            circleButton("stop.fill", tint: NColor.danger, label: "Stop task", action: onStop)
                .transition(.scale.combined(with: .opacity))
        } else {
            circleButton("mic.fill", tint: NColor.textSecondary, label: "Record a voice message") {
                Task { await recorder.start() }
            }
        }
    }

    private func circleButton(_ symbol: String, tint: Color, label: LocalizedStringKey,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.bold))
                .foregroundStyle(tint == NColor.textSecondary ? tint : NColor.onAccent)
                .frame(width: 36, height: 36)
                .background(Circle().fill(tint == NColor.textSecondary ? NColor.surfaceSunken : tint))
        }
        .buttonStyle(NPressableStyle())
        .accessibilityLabel(Text(label))
    }

    private func send() {
        guard canSend else { return }
        let t = text
        let a = attachments
        text = ""
        attachments = []
        onSend(t, a)
    }

    private func attachPhoto(_ item: PhotosPickerItem) async {
        uploading += 1
        defer { uploading -= 1 }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let type = item.supportedContentTypes.first ?? .jpeg
            let ext = type.preferredFilenameExtension ?? "jpg"
            let a = try await upload("photo-\(Int(Date().timeIntervalSince1970)).\(ext)",
                                     type.preferredMIMEType ?? "image/jpeg", data)
            attachments.append(a)
            uploadError = nil
        } catch {
            uploadError = (error as? LocalizedError)?.errorDescription ?? String(localized: "Upload failed")
        }
    }

    private func attachFile(_ url: URL) async {
        uploading += 1
        defer { uploading -= 1 }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 50 * 1024 * 1024 else {
                uploadError = String(localized: "The file is larger than 50 MB")
                return
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            attachments.append(try await upload(url.lastPathComponent, mime, data))
            uploadError = nil
        } catch {
            uploadError = (error as? LocalizedError)?.errorDescription ?? String(localized: "Upload failed")
        }
    }

    private func finishRecording() async {
        guard let file = recorder.stop() else { return }
        defer { try? FileManager.default.removeItem(at: file) }
        uploading += 1
        defer { uploading -= 1 }
        do {
            let data = try Data(contentsOf: file)
            // "voice." tells NEBULA it is a voice note (transcribed on the server when speech-to-text is set up)
            let a = try await upload("voice.m4a", "audio/mp4", data)
            onSend(text, attachments + [a])
            text = ""
            attachments = []
        } catch {
            uploadError = (error as? LocalizedError)?.errorDescription ?? String(localized: "Upload failed")
        }
    }
}

struct RecordingBar: View {
    let recorder: VoiceRecorder
    var body: some View {
        HStack(spacing: NSpace.s) {
            Button { _ = recorder.cancel() } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(NColor.danger).accessibilityLabel(Text("Cancel recording"))
            StatusDot(color: NColor.danger, pulsing: true)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                    .font(.callout.monospacedDigit()).foregroundStyle(NColor.textPrimary)
            }
            LevelMeter(recorder: recorder)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(NColor.surface))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Recording a voice message"))
    }
}

struct LevelMeter: View {
    let recorder: VoiceRecorder
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { _ in
            let level = recorder.level()
            HStack(spacing: 2) {
                ForEach(0..<12, id: \.self) { i in
                    Capsule().fill(NColor.accent.opacity(Double(i) / 12 < level ? 1 : 0.2))
                        .frame(width: 3, height: 6 + CGFloat(i % 4) * 3)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// AAC voice notes (16 kHz mono — small uploads). The file lives in the temporary directory and is deleted after
/// upload or cancel.
@MainActor
@Observable
final class VoiceRecorder {
    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private(set) var isRecording = false
    var denied = false

    var elapsed: Double { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    func level() -> Double {
        guard let r = recorder, r.isRecording else { return 0 }
        r.updateMeters()
        return max(0, min(1, (Double(r.averagePower(forChannel: 0)) + 50) / 50))
    }

    func start() async {
        guard await Self.permission() else { denied = true; Haptics.warning(); return }
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? s.setActive(true)
        #endif
        let url = FileManager.default.temporaryDirectory.appending(path: "nebula-voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
                                       AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return }
        r.isMeteringEnabled = true
        guard r.record(forDuration: 300) else { return }
        recorder = r
        startedAt = Date()
        isRecording = true
        Haptics.tap()
    }

    func stop() -> URL? {
        guard let r = recorder else { return nil }
        r.stop()
        recorder = nil
        isRecording = false
        startedAt = nil
        deactivate()
        return r.url
    }

    func cancel() -> Bool {
        guard let url = stop() else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }

    private func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    static func permission() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}
