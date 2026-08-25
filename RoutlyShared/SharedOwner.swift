//
//  SharedOwner.swift
//  RoutineOrganizerShared
//
//  Who owns rows the widget writes.
//
//  The problem this solves is narrow and easy to miss. The device's guest
//  identity lives in the Keychain (see `LocalOwner`), under a service string
//  with no access group — so the widget extension cannot read it. Left alone,
//  the extension would call the same code, find nothing, and *mint a brand-new
//  guest id*: every completion written from the widget would land under an owner
//  that matches no other row on the device. Nothing would look broken until the
//  sync layer arrived and had to work out which of two "local:" identities was
//  really this person.
//
//  So the app mirrors its current owner into the shared defaults, and the widget
//  reads that. The Keychain stays the source of truth; this is a copy for a
//  process that can't see it.
//
//  A missing mirror reads as nil rather than as a fresh id, and nil is a value
//  the store already understands — rows that predate ownership decode nil, and
//  the app's launch backfill fills them in. Blank and correctable beats
//  populated and wrong.
//

import Foundation

enum SharedOwner {

    private static let key = "sharedOwnerID"

    /// The owner id the app last published, if any.
    ///
    /// Read by the widget extension only. nil means the app hasn't run since
    /// the mirror existed — the completion is still written, just unstamped.
    static var mirrored: String? {
        AppGroup.defaults.string(forKey: key)
    }

    /// Publishes the current owner for the extension to read.
    ///
    /// Called by the app whenever the answer changes: on first resolution of the
    /// guest identity each launch, and on sign-in and sign-out. Writes only on a
    /// genuine change, so this stays off the hot path of ordinary saves.
    static func mirror(_ owner: String?) {
        guard mirrored != owner else { return }
        if let owner {
            AppGroup.defaults.set(owner, forKey: key)
        } else {
            AppGroup.defaults.removeObject(forKey: key)
        }
    }
}
