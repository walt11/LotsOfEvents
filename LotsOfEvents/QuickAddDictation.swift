import Foundation
import AVFoundation
@preconcurrency import Speech

@MainActor
final class QuickAddDictation: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var listening = false
    @Published var transcript = ""
    @Published var error: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapped = false
    private var session = UUID()
    private var timeout: Task<Void, Never>?

    func start() async {
        guard !active else { return }
        active = true
        error = nil
        transcript = ""
        let id = UUID()
        session = id
        let speech = await Self.requestSpeechAuthorization()
        guard active, session == id else { return }
        guard speech else { fail("Allow Speech Recognition for LotsOfEvents in Settings to dictate text."); return }
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard active, session == id else { return }
        guard microphone else { fail("Allow Microphone access for LotsOfEvents in Settings to dictate text."); return }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            fail("Speech recognition is unavailable right now. Try again or type your text."); return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                fail("No microphone is available. Try again or type your text."); return
            }
            Self.installTap(on: input, format: format, request: request)
            tapped = true
            task = Self.recognize(with: recognizer, request: request) { [weak self] words, final, message in
                Task { @MainActor [weak self] in
                    guard let self, self.session == id, self.active else { return }
                    if let words { self.transcript = words }
                    if final { self.stop() }
                    else if let message { self.fail(message) }
                }
            }
            engine.prepare()
            try engine.start()
            listening = true
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(55))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch { fail(error.localizedDescription) }
    }
    func stop() {
        session = UUID()
        timeout?.cancel()
        timeout = nil
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        if listening || active { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        listening = false
        active = false
    }
    private func fail(_ message: String) { stop(); error = message }

    // Speech and audio callbacks arrive on background queues. Closures created inside main-actor
    // methods would be main-actor isolated and trap there, so they are built in nonisolated helpers.
    nonisolated private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
    }
    nonisolated private static func recognize(with recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest, deliver: @escaping @Sendable (String?, Bool, String?) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            deliver(result?.bestTranscription.formattedString, result?.isFinal ?? false, error?.localizedDescription)
        }
    }
}
