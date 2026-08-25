//
//  GoogleCalendarTarget.swift
//  RoutineOrganizer
//
//  Google Calendar, as a second conformer to `CalendarTarget`.
//
//  Nothing above this file knows Google exists. `CalendarLinkPlan` still plans,
//  `CalendarSync` still pushes, the Settings screen still lists whatever is in
//  the registry — which was the point of putting the protocol in first. What is
//  genuinely new here is only the three things Google has and EventKit doesn't:
//  a network, an account, and a calendar that has to be created before it can
//  be written to.
//
//  ── The Routly calendar ─────────────────────────────────────────────────
//
//  Events go into a secondary calendar Routly creates and owns, not the
//  person's primary one. `GoogleCalendarDirectory` resolves it once and
//  remembers its id. That buys three things: the narrowest workable OAuth
//  scope, a calendar nothing else writes to (so no other author to reason about
//  when a later phase reads changes back), and a separate colour-coded entry
//  the person can toggle in Google Calendar rather than a mix into their main
//  one. See `GoogleCalendarConfig` for how to change that.
//
//  ── Alarms, again ───────────────────────────────────────────────────────
//
//  `reminders.useDefault = false` with no overrides, for the same reason
//  `EventKitTarget` sets no `EKAlarm`: Routly already sends its own nudge, and
//  Google's account-level default would otherwise add a second one. Left
//  unspecified, Google *would* apply the default — so saying nothing here would
//  be choosing to notify twice.
//

import Foundation

// MARK: - Which calendar

/// Finds, or makes, the calendar Routly writes to.
///
/// The id is cached in the shared defaults rather than re-resolved per push: it
/// never changes for an account, and a `GET /calendars` before every event
/// would be a round trip bought for nothing. It is not a secret — an opaque
/// calendar id is not worth the Keychain.
enum GoogleCalendarDirectory {

    private static let key = "googleCalendarID"

    static var cachedCalendarID: String? {
        AppGroup.defaults.string(forKey: key)
    }

    static func remember(_ id: String) {
        AppGroup.defaults.set(id, forKey: key)
    }

    /// Cleared on sign-out. A stale id belonging to a previous account is worse
    /// than none: the next sign-in would write into a calendar the new account
    /// can't see, and every push would fail with a 404 nobody could explain.
    static func forgetCalendarID() {
        AppGroup.defaults.removeObject(forKey: key)
    }
}

// MARK: - Target

actor GoogleCalendarTarget: CalendarTarget {

    nonisolated let provider = CalendarProvider.google

    private let session: URLSession
    private let auth: GoogleAuthService

    init(session: URLSession = .shared, auth: GoogleAuthService? = nil) {
        self.session = session
        // Resolved lazily rather than as a default argument: `GoogleAuthService`
        // is main-actor isolated, and a default argument would be evaluated
        // wherever the target happens to be constructed.
        self.auth = auth ?? MainActor.assumeIsolated { GoogleAuthService.shared }
    }

    // MARK: Access

    /// Google has no OS permission to consult — "connected" means Routly holds
    /// a refresh token. The two other states are the ones the shared enum
    /// already has words for: nothing stored is `.notDetermined` (worth
    /// asking), and no client ID is `.restricted` (nothing to ask with).
    nonisolated func access() -> CalendarAccess {
        guard GoogleCalendarConfig.isConfigured else { return .restricted }
        return GoogleTokenStore.isSignedIn ? .full : .notDetermined
    }

    func requestAccess() async -> CalendarAccess {
        guard GoogleCalendarConfig.isConfigured else { return .restricted }
        do {
            try await auth.signIn()
            return .full
        } catch {
            // A cancelled sign-in leaves the state exactly as it was — the
            // person didn't refuse, they backed out, and the connect button
            // should still be there to try again.
            return GoogleTokenStore.isSignedIn ? .full : .notDetermined
        }
    }

    nonisolated var canDisconnect: Bool { true }

    func disconnect() async {
        await auth.signOut()
    }

    // MARK: Writes

    func create(_ payload: CalendarEventPayload) async throws -> CalendarEventRef {
        let token = try await accessToken()
        let calendarID = try await calendarID(token: token)
        let body = GoogleEventBody.json(for: payload)

        let data = try await send(
            method: "POST",
            path: "calendars/\(escape(calendarID))/events",
            token: token,
            body: body
        )
        return try ref(from: data, calendarID: calendarID)
    }

    func update(_ payload: CalendarEventPayload, at ref: CalendarEventRef) async throws -> CalendarEventRef {
        let token = try await accessToken()
        let calendarID = try await resolvedCalendarID(ref, token: token)
        let body = GoogleEventBody.json(for: payload)

        let data = try await send(
            method: "PATCH",
            path: "calendars/\(escape(calendarID))/events/\(escape(ref.externalID))",
            token: token,
            body: body
        )
        return try self.ref(from: data, calendarID: calendarID)
    }

    func remove(_ ref: CalendarEventRef) async throws {
        let token = try await accessToken()
        let calendarID = try await resolvedCalendarID(ref, token: token)

        _ = try await send(
            method: "DELETE",
            path: "calendars/\(escape(calendarID))/events/\(escape(ref.externalID))",
            token: token,
            body: nil,
            // Already gone is the outcome we wanted, per the protocol's
            // idempotence contract. Google answers 410 for an event it has
            // already deleted and 404 for one it never had; both mean "not
            // there", which is the goal.
            tolerating: [404, 410]
        )
    }

    // MARK: Plumbing

    private func accessToken() async throws -> String {
        do {
            return try await auth.accessToken()
        } catch let error as GoogleAuthError {
            throw CalendarTargetError.providerFailed(error.message)
        }
    }

    /// The calendar a link already names, or the Routly calendar.
    ///
    /// Written out rather than as `ref.calendarID ?? (try await …)`: `??` takes
    /// a *throwing* autoclosure, not an async one, so the compact form does not
    /// compile.
    private func resolvedCalendarID(_ ref: CalendarEventRef, token: String) async throws -> String {
        if let existing = ref.calendarID, !existing.isEmpty { return existing }
        return try await calendarID(token: token)
    }

    /// The Routly calendar's id, creating it the first time.
    private func calendarID(token: String) async throws -> String {
        if let fixed = GoogleCalendarConfig.destination.calendarIDIfFixed { return fixed }
        if let cached = GoogleCalendarDirectory.cachedCalendarID { return cached }

        guard case .dedicated(let name) = GoogleCalendarConfig.destination else {
            throw CalendarTargetError.noWritableCalendar
        }
        let data = try await send(
            method: "POST",
            path: "calendars",
            token: token,
            body: ["summary": name]
        )
        guard let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String,
              !id.isEmpty else {
            throw CalendarTargetError.noWritableCalendar
        }
        GoogleCalendarDirectory.remember(id)
        return id
    }

    private func ref(from data: Data, calendarID: String) throws -> CalendarEventRef {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty else {
            throw CalendarTargetError.noIdentifierReturned
        }
        return CalendarEventRef(
            calendarID: calendarID,
            externalID: id,
            // Google has no second identifier; the id is stable for the life of
            // the event, unlike EventKit's.
            externalStableID: nil,
            etag: object["etag"] as? String,
            remoteChangedAt: (object["updated"] as? String).flatMap(GoogleEventBody.parseTimestamp)
        )
    }

    @discardableResult
    private func send(
        method: String,
        path: String,
        token: String,
        body: [String: Any]?,
        tolerating tolerated: Set<Int> = []
    ) async throws -> Data {
        // Not `appendingPathComponent`: that percent-encodes what it is handed,
        // so an already-escaped id came back double-escaped (%40 → %2540) and
        // every request 404'd against a calendar that was sitting right there.
        guard let url = URL(string: GoogleCalendarConfig.calendarAPI.absoluteString + "/" + path) else {
            throw CalendarTargetError.providerFailed(
                String(localized: "Routly built an address Google couldn't read.")
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CalendarTargetError.providerFailed(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if tolerated.contains(status) { return data }
        guard (200..<300).contains(status) else {
            throw Self.failure(status: status, data: data)
        }
        return data
    }

    /// Escapes a path segment. Calendar ids are email-shaped and event ids are
    /// opaque; neither can be pasted into a URL unescaped.
    private func escape(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? segment
    }

    /// Turns Google's error body into one of ours.
    ///
    /// 401 is the one worth singling out: the token was refreshed a moment ago,
    /// so a 401 here means the grant itself is gone — revoked in the person's
    /// Google account, or expired. Reported as "connect again" rather than as a
    /// transient failure that a retry could fix.
    static func failure(status: Int, data: Data) -> CalendarTargetError {
        if status == 401 || status == 403 {
            return .providerFailed(GoogleAuthError.notSignedIn.message)
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        if let message = error?["message"] as? String, !message.isEmpty {
            return .providerFailed(message)
        }
        return .providerFailed(String(localized: "Google Calendar refused the request (\(status))."))
    }
}

// MARK: - Event JSON

/// The payload, in the shape Google's API wants. Pure and static so the mapping
/// is testable without a token, a network, or an account.
enum GoogleEventBody {

    static func json(
        for payload: CalendarEventPayload,
        timeZone: TimeZone = .current
    ) -> [String: Any] {
        var body: [String: Any] = [
            "summary": payload.title,
            "start": bound(payload.start, isAllDay: payload.isAllDay, timeZone: timeZone),
            "end": bound(payload.end, isAllDay: payload.isAllDay, timeZone: timeZone),
            // See the file note: silence here would mean the account's default
            // alarm fires on top of Routly's own notification.
            "reminders": ["useDefault": false, "overrides": [] as [Any]],
        ]
        if let notes = payload.notes, !notes.isEmpty {
            body["description"] = notes
        }
        return body
    }

    /// A start or end, in whichever of Google's two forms applies.
    ///
    /// An all-day event uses `date` and its end is **exclusive** — which is
    /// exactly what `CalendarPayloadBuilder` already produces, since EventKit
    /// wants the same thing. The two providers agreeing here is luck worth
    /// noting rather than relying on silently.
    static func bound(_ date: Date, isAllDay: Bool, timeZone: TimeZone) -> [String: Any] {
        if isAllDay {
            return ["date": dayString(date, timeZone: timeZone)]
        }
        return [
            "dateTime": timestamp(date),
            "timeZone": timeZone.identifier,
        ]
    }

    static func dayString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        // Fixed locale, not the user's: this is a wire format. A Persian or
        // Buddhist calendar locale would otherwise produce a year Google
        // rejects, on the devices of the people least likely to report it.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func parseTimestamp(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        // Google stamps `updated` with milliseconds; the plain internet-date
        // option rejects them, so both spellings are tried.
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
