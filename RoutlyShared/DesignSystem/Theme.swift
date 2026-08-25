//
//  Theme.swift
//  RoutineOrganizer
//
//  The visual language: light-first, a soft warm-paper canvas, one restrained
//  ink-blue accent, and separation carried by whitespace and hairlines rather
//  than a box around everything. Dark mode is a genuine peer, not the identity —
//  every token below resolves per trait collection, so a single appearance
//  setting flips the whole app without a call site knowing about it.
//
//  Two rules worth keeping:
//   • `background` is a *surface* colour. Never use it as a foreground. Text and
//     glyphs sitting on an accent fill use `onAccent`.
//   • Reach for `plainRow()` first. `surfaceCard()` is for things that genuinely
//     need to be set apart — a comparison, a stat, a distinct block.
//

import SwiftUI
import UIKit

enum Theme {

    // MARK: Colors

    enum Colors {

        // MARK: Surfaces

        /// The app canvas. Warm off-white in light, a soft charcoal in dark —
        /// neither stark white nor near-black, both of which read as cheap.
        static let background = adaptive(light: 0xF5F4F1, dark: 0x16161A)

        /// A raised surface for the things that still earn an enclosure.
        static let surface = adaptive(light: 0xFFFFFF, dark: 0x1F1F24)

        /// Higher again — modal overlays, the sheet that sits above a sheet.
        static let surfaceRaised = adaptive(light: 0xFFFFFF, dark: 0x2A2A31)

        /// A recessed fill: chips, segmented tracks, quiet tiles.
        static let surfaceSunken = adaptive(light: 0xECEAE5, dark: 0x26262C)

        // MARK: Accent

        /// One accent, used sparingly. Azure out of the box, but the user can
        /// change it, so this resolves through `ThemePalette` at draw time
        /// rather than baking a hex in.
        static var accent: Color {
            adaptive { ThemePalette.accent.hex(dark: $0) }
        }

        /// The accent as a wash, for selection fills and tinted surfaces.
        static var accentSoft: Color {
            adaptive(lightAlpha: 0.10, darkAlpha: 0.16) { ThemePalette.accent.hex(dark: $0) }
        }

        /// What sits *on* an accent fill.
        ///
        /// Derived from the chosen accent rather than fixed, which is what lets
        /// the palette offer genuinely pale swatches: a pastel accent gets dark
        /// text, a deep one gets white, and no call site has to know which. The
        /// old fixed white is why every selectable colour used to have to be
        /// dark enough to carry it, and why the "pastels" weren't pastel.
        static var onAccent: Color {
            adaptive { ThemePalette.accent.ink(dark: $0) }
        }

        /// A translucent fill behind selected cells and pills.
        static var selection: Color { accentSoft }

        // MARK: Text

        /// Warm near-black → mid grey → faint, so hierarchy comes from weight of
        /// colour rather than weight of type.
        static let textPrimary = adaptive(light: 0x1C1B19, dark: 0xF2F1EE)
        static let textSecondary = adaptive(light: 0x605D57, dark: 0xB4B1AB)
        static let textFaint = adaptive(light: 0x93908A, dark: 0x7E7B76)

        // MARK: Lines

        /// Dividers do the work shadows used to. Two weights: one for separating
        /// rows, a slightly stronger one for structural rules.
        static let hairline = adaptive(light: 0x000000, lightAlpha: 0.07,
                                       dark: 0xFFFFFF, darkAlpha: 0.08)
        static let separator = adaptive(light: 0x000000, lightAlpha: 0.12,
                                        dark: 0xFFFFFF, darkAlpha: 0.13)

        // MARK: Status

        /// The "current time" marker on a timeline. Muted, not neon — it should
        /// read as live without shouting over the schedule it sits on.
        /// Doubles as the destructive-action colour — "live" and "careful" are
        /// the same red in this app, and two near-identical reds would be worse.
        static let now = adaptive(light: 0xC8442F, dark: 0xFF6B5C)

        /// Completion green, shared by the consistency grid so "done" means one
        /// colour everywhere in the app.
        static let done = adaptive(light: 0x3E8A6B, dark: 0x62BE97)

        /// Ambient shadow. Almost nothing in light — the hairline carries it.
        static let shadow = adaptive(light: 0x000000, lightAlpha: 0.06,
                                     dark: 0x000000, darkAlpha: 0.40)

        // MARK: Categories

        /// Desaturated on light so a full week of blocks stays calm; lifted on
        /// dark so they don't sink into the canvas. Which hue each category gets
        /// is the user's to change, so this reads `ThemePalette` rather than a
        /// hard-coded switch.
        static func category(_ category: Category) -> Color {
            adaptive { ThemePalette.color(for: category).hex(dark: $0) }
        }

        /// A category as a soft wash — the fill for calendar blocks and chips.
        /// Light mode needs a much gentler alpha than dark to read as tinted
        /// paper rather than a coloured slab.
        static func categoryTint(_ category: Category, strong: Bool = true) -> Color {
            adaptive(
                lightAlpha: strong ? 0.13 : 0.07,
                darkAlpha: strong ? 0.24 : 0.12
            ) { ThemePalette.color(for: category).hex(dark: $0) }
        }

        /// A barely-there top-lit gradient of a category tint, so a time block
        /// has a hint of dimension without becoming a glossy button.
        static func categoryGradient(_ category: Category, strong: Bool = true) -> LinearGradient {
            let base = categoryTint(category, strong: strong)
            return LinearGradient(
                colors: [base, base.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        /// The wash behind a whole row in "Obvious" tag mode. Stronger than
        /// `categoryTint` — the point of that setting is that you read the
        /// colour before you read the title.
        ///
        /// The strength comes from the swatch itself rather than being one
        /// constant, because equal alpha does not mean equal impression: a
        /// pastel and a vivid at the same alpha are a barely-there haze and a
        /// solid band. See `PaletteColor.lightFill`. Every combination still
        /// leaves body text above 7:1, so the row keeps the normal ink.
        static func categoryRowFill(_ category: Category) -> Color {
            adaptiveTinted { dark in
                let choice = ThemePalette.color(for: category)
                return (choice.hex(dark: dark), choice.rowFillAlpha(dark: dark))
            }
        }

        // MARK: Adaptive plumbing

        /// Resolves per trait collection, so every token above is theme-aware at
        /// draw time. This is what lets ~350 existing call sites stay untouched.
        private static func adaptive(
            light: UInt, lightAlpha: Double = 1,
            dark: UInt, darkAlpha: Double = 1
        ) -> Color {
            adaptive(lightAlpha: lightAlpha, darkAlpha: darkAlpha) { $0 ? dark : light }
        }

        /// The same, but for tokens whose hex isn't fixed at compile time. The
        /// closure runs *inside* the trait resolution, so a colour the user
        /// changes in Settings is picked up the next time anything draws — no
        /// call site has to know the palette is mutable.
        private static func adaptive(
            lightAlpha: Double = 1,
            darkAlpha: Double = 1,
            _ hex: @escaping (_ dark: Bool) -> UInt
        ) -> Color {
            Color(UIColor { traits in
                let isDark = traits.userInterfaceStyle == .dark
                return UIColor(hex: hex(isDark), alpha: isDark ? darkAlpha : lightAlpha)
            })
        }

        /// The same again, for the one case where the *alpha* is as dynamic as
        /// the hex: a row fill whose strength depends on which tier the user
        /// picked. Named rather than overloaded so a trailing closure can't
        /// quietly resolve to the wrong one.
        private static func adaptiveTinted(
            _ resolve: @escaping (_ dark: Bool) -> (hex: UInt, alpha: Double)
        ) -> Color {
            Color(UIColor { traits in
                let (hex, alpha) = resolve(traits.userInterfaceStyle == .dark)
                return UIColor(hex: hex, alpha: alpha)
            })
        }
    }

    // MARK: Motion

    /// One place for the app's motion vocabulary, so every transition feels like
    /// it came from the same hand. Springs, not durations, wherever something moves.
    enum Motion {
        /// Snappy selection changes — day taps, mode switches.
        static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.82)
        /// A softer settle for larger content moving (period changes, agenda swaps).
        static let smooth = Animation.spring(response: 0.42, dampingFraction: 0.88)
        /// A little life for controls that should feel tactile (checkmarks, pills).
        static let bouncy = Animation.spring(response: 0.34, dampingFraction: 0.66)
    }

    // MARK: Elevation

    /// Named shadow levels. Deliberately shallow — on the light canvas depth
    /// comes from the hairline border, not from a drop shadow.
    enum Elevation {
        case low, medium, high

        var radius: CGFloat {
            switch self {
            case .low: return 6
            case .medium: return 12
            case .high: return 22
            }
        }
        var yOffset: CGFloat {
            switch self {
            case .low: return 2
            case .medium: return 5
            case .high: return 10
            }
        }
        /// Scales the ambient shadow token rather than hard-coding black.
        var strength: Double {
            switch self {
            case .low: return 0.7
            case .medium: return 1.0
            case .high: return 1.4
            }
        }
    }

    // MARK: Spacing & shape

    enum Metrics {
        static let screenPadding: CGFloat = 20
        static let cardCornerRadius: CGFloat = 16
        static let cardPadding: CGFloat = 16
        static let itemSpacing: CGFloat = 10

        /// Vertical breathing room in a plain list row. Generous on purpose —
        /// this is the spacing that replaces the box around every item.
        static let rowPadding: CGFloat = 14

        /// The gap between two groups of content. Whitespace is the main tool
        /// for separation now, so it needs to be unmistakable.
        static let sectionSpacing: CGFloat = 26

        /// How far a row divider is inset from the leading edge, so it aligns
        /// under the text rather than cutting the whole screen in half.
        static let dividerInset: CGFloat = 20
    }

    // MARK: Typography

    /// Six steps, and no more. Body content is quiet — hierarchy comes from
    /// colour and space. Bold and oversized are reserved for the two or three
    /// things per screen that genuinely deserve the emphasis.
    enum Typography {
        /// Day labels and key numbers. The only place 34pt bold is allowed.
        static func display() -> Font {
            .system(size: 34, weight: .bold)
        }
        /// Screen and sheet headlines, empty-state titles.
        static func title() -> Font {
            .system(size: 22, weight: .semibold)
        }
        /// A list row's title. Regular weight — a schedule is a list of things,
        /// not a list of headlines.
        static func itemTitle() -> Font {
            .system(size: 17, weight: .regular)
        }
        /// Prose.
        static func body() -> Font {
            .system(size: 15, weight: .regular)
        }
        /// Metadata beneath a title, secondary detail.
        static func caption() -> Font {
            .system(size: 13, weight: .regular)
        }
        /// Section headers and form field labels. Small, spaced, uppercase —
        /// it labels the content instead of competing with it.
        static func label() -> Font {
            .system(size: 11, weight: .semibold)
        }
        /// Numerals and glyph labels that must stay legible when tiny.
        static func micro() -> Font {
            .system(size: 11, weight: .medium)
        }
    }
}

// MARK: - Section label

/// The uppercase, letter-spaced label that introduces a group. Replaces the
/// 20pt-bold all-caps headers that made every list feel like it was shouting.
///
/// It took a `String` and called `.uppercased()` on it, which meant every one of
/// its call sites skipped the string catalog: `Text(someString)` resolves to the
/// `StringProtocol` overload, which doesn't look anything up. Twenty-two section
/// headers across Settings, Today, the calendar and every sheet were English in
/// all three languages, silently and without a warning.
///
/// Uppercasing now goes through `.textCase(.uppercase)` rather than
/// `.uppercased()` — a key can't be uppercased before it's resolved, and the
/// modifier is the locale-aware form anyway.
struct SectionLabel: View {
    private let content: Text

    /// The ordinary case: a literal, looked up in the catalog.
    init(_ key: LocalizedStringKey) { self.content = Text(key) }

    /// Text that is already final — a formatted date, or a string that has been
    /// through `String(localized:)` itself. Deliberately not looked up: a
    /// formatted date is not a catalog key, and asking for one would only ever
    /// miss.
    init(verbatim text: String) { self.content = Text(verbatim: text) }

    var body: some View {
        content
            .textCase(.uppercase)
            .font(Theme.Typography.label())
            .tracking(0.8)
            .foregroundStyle(Theme.Colors.textFaint)
    }
}

// MARK: - Row divider

/// A hairline between plain rows, inset to sit under the text.
struct RowDivider: View {
    var inset: CGFloat = Theme.Metrics.dividerInset

    var body: some View {
        Rectangle()
            .fill(Theme.Colors.hairline)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

// MARK: - Containers

/// The enclosure for content that genuinely needs setting apart: a comparison,
/// a stat, a distinct block. Not the default wrapper for a list item.
struct SurfaceCard: ViewModifier {
    var raised: Bool = false
    var padding: CGFloat = Theme.Metrics.cardPadding

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardCornerRadius, style: .continuous)
                    .fill(raised ? Theme.Colors.surfaceRaised : Theme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(Theme.Colors.hairline, lineWidth: 1)
            )
            .elevation(.low)
    }
}

/// A plain list row: no box, no shadow — just space, and a divider below if the
/// caller wants one. The default presentation for anything in a list.
struct PlainRow: ViewModifier {
    var horizontal: CGFloat = Theme.Metrics.screenPadding

    func body(content: Content) -> some View {
        content
            .padding(.vertical, Theme.Metrics.rowPadding)
            .padding(.horizontal, horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

extension View {
    /// An enclosure, for the cases that earn one.
    func surfaceCard(raised: Bool = false, padding: CGFloat = Theme.Metrics.cardPadding) -> some View {
        modifier(SurfaceCard(raised: raised, padding: padding))
    }

    /// A plain, unenclosed list row.
    func plainRow(horizontal: CGFloat = Theme.Metrics.screenPadding) -> some View {
        modifier(PlainRow(horizontal: horizontal))
    }

    /// A consistent ambient shadow at one of the named depths. Resolves through
    /// the adaptive shadow token, so light mode stays nearly flat.
    func elevation(_ level: Theme.Elevation) -> some View {
        shadow(
            color: Theme.Colors.shadow.opacity(level.strength),
            radius: level.radius,
            x: 0,
            y: level.yOffset
        )
    }
}

// MARK: - Pressable button style

/// A universal tactile press: the control dips slightly and dims, then springs
/// back — the small physical cue that separates a polished app from a flat one.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.Motion.bouncy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

// MARK: - Color hex helpers

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension UIColor {
    convenience init(hex: UInt, alpha: Double = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}
