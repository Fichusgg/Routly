//
//  SpeechTranscriber.swift
//  RoutineOrganizer
//
//  On-device speech-to-text for hands-busy capture.
//
//  The session is continuous: pausing to think — even mid-sentence, even
//  followed by "and…" — never ends it and never loses what came before.
//  Recording stops only when you tap stop, or after a sustained stretch of real
//  silence (measured from the audio signal, not from the recognizer's opinion of
//  when an utterance ended).
//
//  Two details make that reliable:
//   • Text is append-only. The recognizer finalizes a segment whenever you
//     pause; each finished segment is appended, never replacing what came
//     before, and segments are joined in the order they started.
//   • The audio tap writes through a lock-protected holder that always points at
//     a live request. Swapping segments installs the replacement *before*
//     retiring the old one, so there is no window in which buffers are appended
//     to an ended request and silently dropped.
//

import Foundation
import Speech
import AVFoundation

/// Holds the request the audio tap feeds. Lock-protected because the tap runs on
/// the audio thread while segments are swapped on the main actor.
private final class RequestHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let request = self.request; lock.unlock()
        request?.append(buffer)
    }
}

/// Tracks when speech was last actually heard, so silence is judged from the
/// audio itself rather than from recognizer callbacks.
private final class SilenceMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var lastVoiceAt = Date()
    /// RMS above this counts as speech rather than room tone.
    private let threshold: Float = 0.015

    func reset() {
        lock.lock(); defer { lock.unlock() }
        lastVoiceAt = Date()
    }

    func note(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sumOfSquares: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Float(count)).squareRoot()
        guard rms > threshold else { return }

        lock.lock(); lastVoiceAt = Date(); lock.unlock()
    }

    func silenceDuration() -> TimeInterval {
        lock.lock(); let last = lastVoiceAt; lock.unlock()
        return Date().timeIntervalSince(last)
    }
}

@MainActor
@Observable
final class SpeechTranscriber {
    enum Status: Equatable {
        case idle
        case recording
        case denied
        case unavailable
        /// This language has no on-device model on this device, so transcribing
        /// it means sending audio to Apple — and the user hasn't been asked yet.
        case needsServerConsent(VoiceLanguage)
    }

    private(set) var status: Status = .idle

    /// Whether a failed `start()` is worth trying again in a moment.
    ///
    /// `.unavailable` is the only status the audio session's own failures land
    /// in: `setActive` throws when the app isn't yet allowed to take the
    /// microphone, which happens for a beat after a launch from the lock screen
    /// even though the scene already reports itself active. That is a race and
    /// asking again shortly works.
    ///
    /// A denial and a withheld server-speech consent are *decisions*. Retrying
    /// those would be nagging at best, and at worst would re-ask for permission
    /// the user has already refused.
    var startFailureIsRetryable: Bool { status == .unavailable }
    /// Everything heard this session: finished segments plus the live partial.
    private(set) var transcript: String = ""
    var isRecording: Bool { status == .recording }

    /// How long a stretch of pure silence ends the session on its own.
    var silenceTimeout: TimeInterval = 15

    /// Keeps audio and transcription on the device (the privacy default). Apple's
    /// server-based recognition is noticeably more robust on long, rambling
    /// dictation — set this to false to trade that privacy for accuracy.
    var preferOnDeviceRecognition = true

    /// Called with the final transcript when silence ends the session, so the
    /// app can go straight to parsing without the user tapping stop.
    var onSilenceTimeout: ((String) -> Void)?

    /// Where the spoken-language choice comes from. Read at `start()` rather
    /// than cached, so changing the language and immediately recording uses the
    /// new one — there is no window where the two disagree.
    var settings: AppSettings = .shared

    /// Built per session from the chosen language. `SFSpeechRecognizer` is bound
    /// to one locale for its lifetime, so switching language means a new one.
    private var recognizer: SFSpeechRecognizer?
    /// The language this session is actually transcribing, held so a mid-session
    /// settings change can't retarget a recording already in flight.
    private(set) var activeLanguage: VoiceLanguage = .systemDefault
    private let audioEngine = AVAudioEngine()
    private let requestHolder = RequestHolder()
    private let silence = SilenceMonitor()

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Finished text in the order segments began — append-only within a session.
    private var segmentTexts: [(id: Int, text: String)] = []
    private var currentPartial = ""
    private var segmentCounter = 0
    private var activeSegmentID = 0
    private var closedSegments: Set<Int> = []
    /// Rotated-out tasks, held until they deliver their final result so they
    /// aren't deallocated mid-flight.
    private var retiringTasks: [Int: SFSpeechRecognitionTask] = [:]

    /// Rotate before Apple's ~60s per-task ceiling.
    private let segmentSeconds: TimeInterval = 45
    private var rotationTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?

    private var isStopping = false
    private var finishContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Control

    func start() async {
        guard status != .recording else { return }
        resetState()

        guard await requestSpeechAuthorization(), await requestMicAuthorization() else {
            status = .denied
            return
        }

        let language = settings.voiceLanguage
        let recognizer = SFSpeechRecognizer(locale: language.resolvedLocale())
        guard let recognizer, recognizer.isAvailable else {
            status = .unavailable
            return
        }

        // On-device is the promise this app makes. When the chosen language has
        // no on-device model here, honouring the request at all means Apple's
        // servers hear the audio.
        if preferOnDeviceRecognition && !recognizer.supportsOnDeviceRecognition
            && !settings.allowsServerSpeech(for: language) {
            // Asked and declined: don't record, and don't ask again on every
            // hold. The Settings row explains the state and is where they can
            // change their mind — a modal on each press would be nagging.
            status = settings.hasDecidedServerSpeech(for: language)
                ? .unavailable
                : .needsServerConsent(language)
            return
        }

        self.recognizer = recognizer
        activeLanguage = language

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            let holder = requestHolder
            let silence = silence
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                // Always a live request here — see RequestHolder.
                holder.append(buffer)
                silence.note(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()

            status = .recording
            silence.reset()
            beginSegment()
            startRotationLoop()
            startSilenceWatch()
        } catch {
            status = .unavailable
            teardown()
        }
    }

    /// Stops recording and returns the complete transcript, waiting for the
    /// recognizer's final result so the tail isn't lost.
    @discardableResult
    func stop() async -> String {
        guard status == .recording else { return transcript }
        isStopping = true
        rotationTask?.cancel(); rotationTask = nil
        silenceTask?.cancel(); silenceTask = nil
        request?.endAudio()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishContinuation = continuation
            // Safety net: never hang the UI if no final result arrives.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if let pending = self.finishContinuation {
                    self.finishContinuation = nil
                    pending.resume()
                }
            }
        }

        teardown()
        isStopping = false
        return transcript
    }

    /// Dismisses a consent prompt once it has been answered either way, so the
    /// mic goes back to looking ready rather than stuck.
    func acknowledgeConsentPrompt() {
        if case .needsServerConsent = status { status = .idle }
    }

    // MARK: - Timers

    private func startRotationLoop() {
        rotationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.segmentSeconds))
                guard !Task.isCancelled, self.status == .recording, !self.isStopping else { return }
                self.rotateSegment()
            }
        }
    }

    /// Ends the session after a sustained stretch of genuine silence. Short
    /// pauses mid-thought are ignored — only the audio level decides.
    private func startSilenceWatch() {
        // Only armed when someone wants it. With press-and-hold capture the
        // release defines the end, so auto-stopping on a thinking pause would
        // cut the user off mid-thought.
        guard onSilenceTimeout != nil else { return }
        silenceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled,
                      self.status == .recording, !self.isStopping else { return }
                guard self.silence.silenceDuration() >= self.silenceTimeout else { continue }

                let finalText = await self.stop()
                if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.onSilenceTimeout?(finalText)
                }
                return
            }
        }
    }

    // MARK: - Segments

    /// Make-before-break: install the replacement, then close the old segment, so
    /// the audio tap never has a dead request to write into.
    ///
    /// Two things must survive the swap. The retiring task needs a strong
    /// reference or it can be released before delivering its final result —
    /// taking the whole segment's text with it. And whatever it has transcribed
    /// so far is committed up front, so the text never depends on that final
    /// actually arriving.
    private func rotateSegment() {
        let retiringID = activeSegmentID
        let retiringRequest = request
        let retiringTask = task

        if !currentPartial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commitSegment(id: retiringID, text: currentPartial)
        }
        currentPartial = ""

        if let retiringTask { retiringTasks[retiringID] = retiringTask }

        beginSegment()
        retiringRequest?.endAudio()
    }

    /// Insert or upgrade a segment's text, keeping segments in start order. A
    /// later, better final result replaces the provisional partial rather than
    /// appending a duplicate.
    private func commitSegment(id: Int, text: String) {
        if let index = segmentTexts.firstIndex(where: { $0.id == id }) {
            // A segment's text may only grow. A late result that dropped earlier
            // context must never replace the more complete text we already hold.
            if text.count >= segmentTexts[index].text.count {
                segmentTexts[index].text = text
            }
        } else {
            segmentTexts.append((id: id, text: text))
            segmentTexts.sort { $0.id < $1.id }
        }
        refreshTranscript()
    }

    private func beginSegment() {
        guard let recognizer else { return }
        segmentCounter += 1
        let id = segmentCounter
        activeSegmentID = id

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = preferOnDeviceRecognition && recognizer.supportsOnDeviceRecognition
        // Punctuation gives the parser real sentence boundaries — the difference
        // between five separate to-dos and one merged blob.
        request.addsPunctuation = true

        self.request = request
        requestHolder.set(request)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                self?.handle(segmentID: id, text: text, isFinal: isFinal, failed: failed)
            }
        }
    }

    private func handle(segmentID: Int, text: String?, isFinal: Bool, failed: Bool) {
        let isActive = segmentID == activeSegmentID

        if let text, !isFinal, isActive {
            if isPartialReset(new: text, previous: currentPartial) {
                // The recognizer dropped its earlier context and restarted its
                // running transcription. Salvage what it had already heard into a
                // finished segment, then let the new text start a fresh one —
                // otherwise it would simply overwrite everything said so far.
                rotateSegment()
            }
            currentPartial = text
            refreshTranscript()
        }

        guard isFinal || failed else { return }
        // A task can report completion more than once; only settle it once.
        guard !closedSegments.contains(segmentID) else { return }
        closedSegments.insert(segmentID)

        let settled = (isFinal ? text : nil) ?? (isActive ? currentPartial : nil) ?? ""
        if !settled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Upgrades the provisional text committed at rotation, if any.
            commitSegment(id: segmentID, text: settled)
        }
        retiringTasks[segmentID] = nil
        if isActive { currentPartial = "" }
        refreshTranscript()

        // A rotated-out segment finishing is expected and needs no follow-up;
        // only the live one drives what happens next.
        guard isActive else { return }
        task = nil

        if isStopping {
            requestHolder.set(nil)
            request = nil
            finishContinuation?.resume()
            finishContinuation = nil
        } else if status == .recording {
            // Pausing mid-thought finalizes a segment — immediately re-arm so the
            // session continues. Only silence or an explicit stop ends it.
            beginSegment()
        }
    }

    private func isPartialReset(new: String, previous: String) -> Bool {
        TranscriptAssembly.isPartialReset(new: new, previous: previous)
    }

    private func refreshTranscript() {
        var parts = segmentTexts.map(\.text)
        if !currentPartial.isEmpty { parts.append(currentPartial) }
        transcript = parts.joined(separator: " ")
    }

    // MARK: - Lifecycle

    private func resetState() {
        segmentTexts = []
        closedSegments = []
        retiringTasks = [:]
        currentPartial = ""
        transcript = ""
        segmentCounter = 0
        activeSegmentID = 0
    }

    private func teardown() {
        rotationTask?.cancel(); rotationTask = nil
        silenceTask?.cancel(); silenceTask = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        for retiring in retiringTasks.values { retiring.cancel() }
        retiringTasks = [:]
        requestHolder.set(nil)
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if status == .recording { status = .idle }
    }

    // MARK: - Authorization

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authStatus in
                continuation.resume(returning: authStatus == .authorized)
            }
        }
    }

    private func requestMicAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
