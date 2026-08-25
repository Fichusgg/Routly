//
//  VoiceCaptureButton.swift
//  RoutineOrganizer
//
//  The floating mic — the app's primary capture affordance, bottom right.
//
//  Press and hold to record, release to stop. Holding makes the end of the
//  recording unambiguous (no stray tap needed, no wondering whether it's still
//  listening), and it makes accidental captures self-correcting: let go and it's
//  over. A DragGesture with zero minimum distance is used rather than
//  LongPressGesture so the release is reported reliably even if the finger
//  drifts slightly while speaking.
//
//  There is one case where holding cannot be the rule: a session launched from
//  the mic widget is already recording by the time this button is on screen, and
//  nobody is holding anything. Then — and only then — a tap stops it. The
//  alternative would be a recording with no visible way to end it short of
//  waiting out the silence timeout.
//

import SwiftUI

struct VoiceCaptureButton: View {
    let speech: SpeechTranscriber

    /// True while a widget-launched session is running. Flips this control from
    /// hold-to-record into tap-to-stop for the life of that session.
    var isHandsFree: Bool = false

    var onFinish: (String) -> Void

    /// Guards against the drag gesture's repeated onChanged callbacks starting
    /// the recorder more than once per hold.
    @State private var isHolding = false

    private var diameter: CGFloat { 68 }

    var body: some View {
        // A solid accent disc — this is the one control on Today allowed to be
        // loud. Recording swaps the fill to the live colour, so "am I still
        // being listened to?" is answerable from across the room.
        ZStack {
            Circle()
                .fill(speech.isRecording ? Theme.Colors.now : Theme.Colors.accent)
                .frame(width: diameter, height: diameter)
                .shadow(
                    color: (speech.isRecording ? Theme.Colors.now : Theme.Colors.accent)
                        .opacity(speech.isRecording ? 0.40 : 0.28),
                    radius: speech.isRecording ? 18 : 12,
                    y: 6
                )

            // The glyph says which gesture is live: a square to stop reads as
            // "tap me", where a mic during a hands-free session would look like
            // it still wanted holding.
            Image(systemName: isHandsFree ? "stop.fill" : "mic.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Theme.Colors.onAccent)
        }
        .scaleEffect(speech.isRecording ? 1.12 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: speech.isRecording)
        .contentShape(Circle())
        .gesture(gesture)
        .accessibilityLabel(isHandsFree ? "Stop recording" : "Hold to record")
        .accessibilityHint(isHandsFree
            ? "Tap to finish the capture you started from the widget"
            : "Press and hold to capture by voice, release to finish")
    }

    /// Two different controls wearing one face.
    ///
    /// The hold gesture is not merely unhelpful during a hands-free session, it
    /// is actively wrong: its `onChanged` would try to start a recorder that is
    /// already running, and its `onEnded` would stop the session on the way *in*
    /// to a tap rather than on a deliberate one.
    private var gesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in if !isHandsFree { beginHold() } }
            .onEnded { _ in isHandsFree ? stopHandsFree() : endHold() }
    }

    private func stopHandsFree() {
        Task {
            let transcript = await speech.stop()
            onFinish(transcript)
        }
    }

    private func beginHold() {
        guard !isHolding else { return }
        isHolding = true
        Task { await speech.start() }
    }

    private func endHold() {
        guard isHolding else { return }
        isHolding = false
        Task {
            let transcript = await speech.stop()
            onFinish(transcript)
        }
    }
}
