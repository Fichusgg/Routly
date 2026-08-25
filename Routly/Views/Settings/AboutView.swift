//
//  AboutView.swift
//  RoutineOrganizer
//
//  What the app is and which build you're looking at.
//
//  It exists mainly so a bug report can name a version. Everything here is read
//  from the bundle rather than written down, because a hardcoded version number
//  is wrong the first time anyone forgets to change it.
//

import SwiftUI

struct AboutView: View {
    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Version")

                        VStack(spacing: 0) {
                            row(title: String(localized: "Version"), value: Self.version)
                            Divider().padding(.leading, Theme.Metrics.cardPadding)
                            row(title: String(localized: "Build"), value: Self.build)
                        }
                        .surfaceCard(padding: 0)
                    }

                    Text("Routine Organizer keeps your schedule on this phone. Capture by voice is transcribed on device wherever the language allows it, and an account, if you make one, only adds a backup.")
                        .font(Theme.Typography.caption())
                        .foregroundStyle(Theme.Colors.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(verbatim: title)
                .font(Theme.Typography.itemTitle())
                .foregroundStyle(Theme.Colors.textPrimary)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Colors.textFaint)
        }
        .padding(.horizontal, Theme.Metrics.cardPadding)
        .padding(.vertical, Theme.Metrics.rowPadding)
    }

    // MARK: - Bundle values

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    /// The one-line summary the settings row shows without opening the page.
    static var versionLine: String { "\(version) (\(build))" }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
