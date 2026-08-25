//
//  SupabaseConfig.swift
//  RoutineOrganizer
//
//  Where the auth layer gets its settings. Both values come from the gitignored
//  Secrets.plist (see Secrets.example.plist), read through the same helper the
//  parsing layer already uses, so there is one secrets mechanism in the app
//  rather than two.
//
//  Unlike the LLM key, the Supabase *anon* key is designed to be public — it
//  identifies the project, and Row Level Security is what protects the data.
//  Shipping it in the binary is the intended usage, not a compromise.
//
//  With nothing configured the app stays in guest mode permanently and every
//  local feature keeps working; sign-in simply isn't offered.
//

import Foundation

enum SupabaseConfig {
    /// Project URL, e.g. https://abcdefgh.supabase.co
    static var url: URL? {
        AnthropicConfig.secret("SupabaseURL").flatMap(URL.init(string:))
    }

    /// The publishable anon key.
    static var anonKey: String? { AnthropicConfig.secret("SupabaseAnonKey") }

    /// True only when both values are present. Every auth entry point checks
    /// this first so a half-configured build degrades to guest-only rather than
    /// failing at the network layer.
    static var isConfigured: Bool { url != nil && anonKey != nil }

    /// Base for the GoTrue (auth) REST API.
    static var authBaseURL: URL? { url?.appendingPathComponent("auth/v1") }
}
