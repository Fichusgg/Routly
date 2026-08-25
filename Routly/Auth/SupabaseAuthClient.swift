//
//  SupabaseAuthClient.swift
//  RoutineOrganizer
//
//  Supabase auth (GoTrue) over its documented REST interface, hand-rolled on
//  URLSession — the same approach `AnthropicParsingService` already takes for
//  the Messages API. Adding the official Swift SDK would mean the project's
//  first SPM dependency and a `project.pbxproj` edit for four endpoints, which
//  isn't a trade worth making at this size.
//
//  Every method returns a typed `AuthError` rather than a raw HTTP failure, so
//  the UI never has to interpret a status code.
//

import Foundation

struct SupabaseAuthClient {
    var session: URLSession = .shared

    // MARK: - Email

    func signUp(email: String, password: String) async throws -> AuthOutcome {
        let body: [String: Any] = ["email": email, "password": password]
        let data = try await post(path: "signup", body: body)

        // With email confirmation enabled the response is a user with no
        // tokens. That's a success — the person just has to go read their mail.
        guard let outcome = try? decodeSession(data, provider: .email) else {
            return .confirmationRequired(email: email)
        }
        return .session(outcome)
    }

    func signIn(email: String, password: String) async throws -> AuthOutcome {
        let body: [String: Any] = ["email": email, "password": password]
        let data = try await post(path: "token", query: ["grant_type": "password"], body: body)
        return .session(try decodeSession(data, provider: .email))
    }

    // MARK: - Apple

    /// Exchanges Apple's identity token for a Supabase session. `nonce` is the
    /// *raw* nonce — Apple's token carries its SHA256 hash, and the server
    /// compares the two, which is what stops a stolen token being replayed.
    func signInWithApple(idToken: String, nonce: String, displayName: String?) async throws -> AuthOutcome {
        let body: [String: Any] = [
            "provider": "apple",
            "id_token": idToken,
            "nonce": nonce,
        ]
        let data = try await post(path: "token", query: ["grant_type": "id_token"], body: body)
        var stored = try decodeSession(data, provider: .apple)

        // Apple sends the name exactly once, on the first authorization ever.
        // If we have it, keep it — there is no second chance to ask.
        if let displayName, !displayName.isEmpty, stored.user.displayName == nil {
            stored.user.displayName = displayName
        }
        return .session(stored)
    }

    // MARK: - Session lifecycle

    func refresh(refreshToken: String, provider: AuthProvider) async throws -> StoredSession {
        let body: [String: Any] = ["refresh_token": refreshToken]
        let data = try await post(path: "token", query: ["grant_type": "refresh_token"], body: body)
        return try decodeSession(data, provider: provider)
    }

    /// Best-effort server-side revocation. A failure here is not worth blocking
    /// on: the local session is cleared either way.
    func signOut(accessToken: String) async {
        _ = try? await post(path: "logout", body: [:], accessToken: accessToken)
    }

    /// Account deletion, required by App Store guideline 5.1.1(v) for any app
    /// offering account creation.
    ///
    /// A client holding only the anon key cannot delete a user — that needs the
    /// service role. The call therefore goes to a `delete_account` Postgres
    /// function that runs as SECURITY DEFINER and deletes `auth.uid()`; the SQL
    /// for it is in Docs/supabase-auth-setup.md. Until that function exists the
    /// server answers 404 and this surfaces an honest error rather than
    /// pretending the account is gone.
    func deleteAccount(accessToken: String) async throws {
        guard let base = SupabaseConfig.url, let anonKey = SupabaseConfig.anonKey else {
            throw AuthError.notConfigured
        }
        var request = URLRequest(url: base.appendingPathComponent("rest/v1/rpc/delete_account"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 30

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(from: data, status: http.statusCode)
        }
    }

    // MARK: - Transport

    private func post(
        path: String,
        query: [String: String] = [:],
        body: [String: Any],
        accessToken: String? = nil
    ) async throws -> Data {
        guard let base = SupabaseConfig.authBaseURL, let anonKey = SupabaseConfig.anonKey else {
            throw AuthError.notConfigured
        }

        var components = URLComponents(
            url: base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw AuthError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? anonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(from: data, status: http.statusCode)
        }
        return data
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                 .cannotFindHost, .dataNotAllowed, .internationalRoamingOff:
                throw AuthError.offline
            default:
                throw AuthError.server(error.localizedDescription)
            }
        }
    }

    // MARK: - Decoding

    /// GoTrue's token payload. Only the fields we actually use.
    private struct TokenResponse: Decodable {
        struct User: Decodable {
            let id: String
            let email: String?
            let user_metadata: [String: JSONValue]?
        }
        let access_token: String
        let refresh_token: String
        let expires_in: Double
        let user: User
    }

    private func decodeSession(_ data: Data, provider: AuthProvider) throws -> StoredSession {
        guard let payload = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthError.invalidResponse
        }
        let name = payload.user.user_metadata?["full_name"]?.stringValue
            ?? payload.user.user_metadata?["name"]?.stringValue

        return StoredSession(
            accessToken: payload.access_token,
            refreshToken: payload.refresh_token,
            expiresAt: Date().addingTimeInterval(payload.expires_in),
            user: AuthUser(
                id: payload.user.id,
                email: payload.user.email,
                displayName: name,
                provider: provider
            )
        )
    }

    /// GoTrue reports failures under several different keys depending on the
    /// endpoint and version, so all of them are checked before falling back to
    /// the status code.
    private static func error(from data: Data, status: Int) -> AuthError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["error_description"] as? String)
            ?? (json?["msg"] as? String)
            ?? (json?["message"] as? String)
            ?? (json?["error"] as? String)

        let lowered = message?.lowercased() ?? ""
        if lowered.contains("already registered") || lowered.contains("already been registered") {
            return .emailInUse
        }
        if lowered.contains("password") && lowered.contains("least") {
            return .weakPassword
        }
        if status == 400 || status == 401 {
            return lowered.contains("invalid") ? .invalidCredentials : .server(message ?? "Sign-in failed.")
        }
        return .server(message ?? "The server returned an error (\(status)).")
    }
}

/// Minimal JSON value, only so `user_metadata` can be read without modelling
/// every shape Supabase might put in it.
enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .null }
    }
}
