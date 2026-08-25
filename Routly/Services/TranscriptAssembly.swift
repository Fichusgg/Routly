//
//  TranscriptAssembly.swift
//  RoutineOrganizer
//
//  The pure rules for stitching a long dictation together, kept out of
//  SpeechTranscriber so they can be unit tested without audio hardware.
//

import Foundation

enum TranscriptAssembly {

    /// True when a new partial result looks like the recognizer *restarted* its
    /// running transcription rather than extended it.
    ///
    /// Partial results are normally cumulative — each one extends the last. But
    /// during long dictation the engine can drop earlier context and begin again
    /// from recent audio. Overwriting on that would silently erase everything
    /// said so far, so it has to be told apart from an ordinary revision.
    ///
    /// A revision keeps most of the previous prefix ("buy milk" → "by milk");
    /// a reset shares almost none of it and is shorter.
    static func isPartialReset(new: String, previous: String) -> Bool {
        guard !previous.isEmpty, new.count < previous.count else { return false }
        // Either string containing the other is growth or a trim, not a restart.
        guard !new.hasPrefix(previous), !previous.hasPrefix(new) else { return false }
        let shared = new.commonPrefix(with: previous)
        return shared.count * 2 < previous.count
    }
}
