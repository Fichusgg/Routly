//
//  MigrationPlanner.swift
//  RoutineOrganizer
//
//  Decides what a first sign-in should do with the data already on the device.
//  Pure logic — no store, no network — so every branch is testable.
//
//  The governing rule is that a first sign-in must never be able to lose data
//  and must never block on the network. That's why the local claim is a separate
//  step that happens first: if the connection dies immediately afterwards, the
//  person is signed in with everything intact and an upload still pending.
//

import Foundation

/// What the server has for this account. `unknown` is a first-class answer —
/// the probe couldn't tell us, and guessing would risk the wrong branch.
enum RemoteDataState: Equatable, Sendable {
    case empty
    case populated(items: Int)
    case unknown
}

/// Asks the server whether an account already has data.
///
/// The real implementation arrives with the sync layer. It's a protocol now so
/// the decision logic below can be written and tested against every branch
/// before the transport exists.
protocol RemoteDataProbe: Sendable {
    func probe(accountID: String) async -> RemoteDataState
}

/// The stand-in used while the app is still local-only.
///
/// It reports `.unknown` rather than `.empty` on purpose: this build genuinely
/// does not know what's in the cloud, and saying "empty" would be asserting
/// something unverified. `.unknown` routes to a plain local claim, which is
/// correct and safe — no data is uploaded or overwritten either way.
struct UncheckedRemoteProbe: RemoteDataProbe {
    func probe(accountID: String) async -> RemoteDataState { .unknown }
}

/// How the person chose to resolve local data meeting cloud data.
enum MigrationChoice: String, Equatable, Sendable, CaseIterable, Identifiable {
    /// Union both sets. Nothing is lost — the default and the recommendation.
    case merge
    /// This phone wins; the cloud copy is replaced.
    case keepLocal
    /// The cloud wins; local data is archived to a file first, never just deleted.
    case keepCloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .merge: return "Merge both"
        case .keepLocal: return "Keep this phone"
        case .keepCloud: return "Keep the cloud copy"
        }
    }

    var detail: String {
        switch self {
        case .merge: return "Combine everything from this phone and your account. Nothing is lost."
        case .keepLocal: return "Replace what's in your account with what's on this phone."
        case .keepCloud: return "Replace what's on this phone with your account. A backup is saved first."
        }
    }

    var isRecommended: Bool { self == .merge }
}

/// What to do next after a successful sign-in.
enum MigrationRoute: Equatable, Sendable {
    /// Nothing on this device to hand over.
    case nothingToDo
    /// Straight local claim, no question needed — the common case.
    case claimLocally
    /// Both sides hold data; the person has to decide before anything changes.
    case askUser(localItems: Int, remoteItems: Int)
}

enum MigrationPlanner {

    /// The one decision the whole flow turns on.
    ///
    /// Note the asymmetry: a populated cloud with *no* local data is
    /// `nothingToDo`, not a question. There's nothing to reconcile — the sync
    /// layer will simply pull it down when it exists. Only data on both sides
    /// is a genuine fork that needs a person to settle it.
    static func route(localItems: Int, remote: RemoteDataState) -> MigrationRoute {
        switch remote {
        case .empty, .unknown:
            return localItems > 0 ? .claimLocally : .nothingToDo
        case .populated(let remoteItems):
            guard localItems > 0 else { return .nothingToDo }
            guard remoteItems > 0 else { return .claimLocally }
            return .askUser(localItems: localItems, remoteItems: remoteItems)
        }
    }
}
