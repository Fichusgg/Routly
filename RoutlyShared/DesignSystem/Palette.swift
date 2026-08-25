//
//  Palette.swift
//  RoutineOrganizer
//
//  The colours a person is allowed to choose from, and the live palette the
//  Theme tokens resolve against.
//
//  The set is systematic rather than hand-picked: seven base hues — red, orange,
//  yellow, green, blue, purple, pink — each rendered at three tiers. Every tier
//  is one fixed lightness/chroma target in OKLCH applied to all seven hue
//  angles, so "pastel blue" and "muted blue" are provably the same hue at
//  different settings rather than two swatches that happen to sit near each
//  other. Adding a hue means adding one angle, not eyeballing three new hexes.
//
//  Every option is a *pair* — one value for light mode, a retuned one for dark —
//  because a single hex can't serve both.
//
//  What a colour carries on top is derived, not assumed. `ink(dark:)` picks
//  white or near-black by measuring contrast against the swatch itself, which is
//  what lets the pastel tier be genuinely pale: the old set had to keep every
//  light value dark enough for white text, so its "pastels" were really just
//  muted mid-tones. `Theme.Colors.onAccent` resolves through that, so a pale
//  accent gets dark text and a deep one gets white, with no call site involved.
//
//  `ThemePalette` is deliberately dumb and non-observable: `Theme.Colors`
//  resolves through it inside a UIColor trait closure, which can run at any
//  time, so it must not touch the observable settings object. `AppSettings`
//  pushes into it whenever a choice changes.
//
import Foundation

/// Which of the three styles a swatch belongs to. The tier is what the picker
/// groups by, and it also decides how heavily the colour fills a row in
/// "Obvious" tag mode — see `rowFillAlpha(dark:)`.
enum PaletteTier: String, CaseIterable, Identifiable, Sendable {
    case pastel
    case vivid
    case muted
    /// Greys, which have no hue and so can't be a variant of anything. Kept
    /// apart from the three tiers rather than dropped into whichever one looks
    /// closest, so the hue grid above stays honest.
    case neutral

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pastel: return String(localized: "Soft pastel")
        case .vivid: return String(localized: "Saturated")
        case .muted: return String(localized: "Muted")
        case .neutral: return String(localized: "Neutral")
        }
    }

    var detail: String {
        switch self {
        case .pastel: return String(localized: "Light and low-saturation.")
        case .vivid: return String(localized: "Clean and punchy.")
        case .muted: return String(localized: "Desaturated and quiet.")
        case .neutral: return String(localized: "No hue at all.")
        }
    }

}

/// One named choice, as a light/dark hex pair plus the strength it fills a row
/// at in each theme.
struct PaletteColor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let tier: PaletteTier
    let light: UInt
    let dark: UInt
    /// How much of the colour washes a whole row in "Obvious" tag mode.
    ///
    /// Per swatch, not one constant, because equal alpha does not produce equal
    /// impression: at the flat 0.22 this used to be, a vivid hue shifts the row
    /// about 28% off the canvas while a pastel shifts it 6% — the pastels would
    /// have been invisible in the one mode whose whole point is being visible.
    /// Each value is the alpha at which that specific colour reaches the same
    /// perceptual depth (~0.085 OKLab lightness) against its theme's canvas,
    /// solved offline rather than at draw time.
    ///
    /// Pastels invert between themes, which looks like a bug and isn't: on the
    /// light canvas a pastel row is essentially the pastel itself, while on the
    /// dark canvas that same pale colour at full strength would be a glaring
    /// slab, so it stays a whisper.
    let lightFill: Double
    let darkFill: Double
}

extension PaletteColor {
    /// The right hex for the trait collection currently resolving.
    func hex(dark: Bool) -> UInt { dark ? self.dark : light }

    /// The row-fill strength for the trait collection currently resolving.
    func rowFillAlpha(dark: Bool) -> Double { dark ? darkFill : lightFill }

    /// What text and glyphs sitting *on* this colour should be, measured rather
    /// than assumed: whichever of white or near-black has more contrast against
    /// the swatch. Every swatch in `all` clears 4.5:1 against its own ink — the
    /// invariant that replaces the old "white must work on everything" rule, and
    /// the one `AppSettingsTests` enforces.
    func ink(dark: Bool) -> UInt {
        let base = hex(dark: dark)
        return contrast(base, Ink.onLight) >= contrast(base, Ink.onDark)
            ? Ink.onLight
            : Ink.onDark
    }

    enum Ink {
        static let onLight: UInt = 0xFFFFFF
        static let onDark: UInt = 0x14141A
    }

    // ── Soft pastel ────────────────────────────────────────────────────────
    // OKLCH L 0.870 / C 0.075 light, L 0.885 / C 0.065 dark — one setting across
    // all seven hues. Genuinely pale in both themes; all of them carry dark ink.
    static let pastelRed = PaletteColor(id: "pastelRed", name: "Blush", tier: .pastel, light: 0xFFC3BC, dark: 0xFFCBC4, lightFill: 0.87, darkFill: 0.11)
    static let pastelOrange = PaletteColor(id: "pastelOrange", name: "Peach", tier: .pastel, light: 0xFCC8A6, dark: 0xFCCFB1, lightFill: 0.88, darkFill: 0.11)
    static let pastelYellow = PaletteColor(id: "pastelYellow", name: "Butter", tier: .pastel, light: 0xE3D49C, dark: 0xE6D9A9, lightFill: 0.86, darkFill: 0.11)
    static let pastelGreen = PaletteColor(id: "pastelGreen", name: "Mint", tier: .pastel, light: 0xB2E3BB, dark: 0xBBE6C3, lightFill: 0.88, darkFill: 0.11)
    static let pastelBlue = PaletteColor(id: "pastelBlue", name: "Sky", tier: .pastel, light: 0xB4D8FF, dark: 0xBDDDFF, lightFill: 0.87, darkFill: 0.11)
    static let pastelPurple = PaletteColor(id: "pastelPurple", name: "Lilac", tier: .pastel, light: 0xDBCAFF, dark: 0xDFD0FF, lightFill: 0.87, darkFill: 0.11)
    static let pastelPink = PaletteColor(id: "pastelPink", name: "Petal", tier: .pastel, light: 0xFBC1DB, dark: 0xFCC8DF, lightFill: 0.88, darkFill: 0.11)

    // ── Saturated ──────────────────────────────────────────────────────────
    // 92% of the maximum chroma sRGB can hold for each hue — but at a lightness
    // that varies per hue, which is the one place this palette deliberately
    // isn't one flat setting. Chroma peaks at a different lightness for every
    // hue (yellow near 0.89, purple near 0.55), so holding all seven at one
    // value starves exactly the hues that need height: pinned at 0.535 this
    // tier's yellow could reach only 0.11 chroma against purple's 0.29, and
    // read as olive rather than gold. Each hue sits near its own peak instead.
    static let vividRed = PaletteColor(id: "vividRed", name: "Ruby", tier: .vivid, light: 0xCC2123, dark: 0xF9786C, lightFill: 0.18, darkFill: 0.15)
    static let vividOrange = PaletteColor(id: "vividOrange", name: "Tangerine", tier: .vivid, light: 0xC96E20, dark: 0xF98F3A, lightFill: 0.25, darkFill: 0.14)
    static let vividYellow = PaletteColor(id: "vividYellow", name: "Gold", tier: .vivid, light: 0xCEAF2C, dark: 0xEFCC35, lightFill: 0.40, darkFill: 0.12)
    static let vividGreen = PaletteColor(id: "vividGreen", name: "Emerald", tier: .vivid, light: 0x239A4D, dark: 0x35D96F, lightFill: 0.23, darkFill: 0.14)
    static let vividBlue = PaletteColor(id: "vividBlue", name: "Azure", tier: .vivid, light: 0x1B76C3, dark: 0x61ADF8, lightFill: 0.20, darkFill: 0.15)
    static let vividPurple = PaletteColor(id: "vividPurple", name: "Violet", tier: .vivid, light: 0x8D25F0, dark: 0xB082F8, lightFill: 0.18, darkFill: 0.16)
    static let vividPink = PaletteColor(id: "vividPink", name: "Magenta", tier: .vivid, light: 0xC52084, dark: 0xF969B5, lightFill: 0.18, darkFill: 0.16)

    // ── Muted ──────────────────────────────────────────────────────────────
    // OKLCH L 0.530 / C 0.062 light, L 0.700 / C 0.055 dark. Same seven hues
    // with most of the chroma taken out — but not all of it: below about 0.05
    // the warm half of the wheel collapses, and red, orange and pink become
    // three shades of the same brown in the picker.
    static let mutedRed = PaletteColor(id: "mutedRed", name: "Brick", tier: .muted, light: 0x8C5E58, dark: 0xBE928C, lightFill: 0.21, darkFill: 0.15)
    static let mutedOrange = PaletteColor(id: "mutedOrange", name: "Clay", tier: .muted, light: 0x886249, dark: 0xBA967E, lightFill: 0.21, darkFill: 0.15)
    static let mutedYellow = PaletteColor(id: "mutedYellow", name: "Olive", tier: .muted, light: 0x776C41, dark: 0xA99F78, lightFill: 0.21, darkFill: 0.15)
    static let mutedGreen = PaletteColor(id: "mutedGreen", name: "Sage", tier: .muted, light: 0x527659, dark: 0x87A98D, lightFill: 0.21, darkFill: 0.15)
    static let mutedBlue = PaletteColor(id: "mutedBlue", name: "Slate", tier: .muted, light: 0x506F8F, dark: 0x85A2C0, lightFill: 0.21, darkFill: 0.15)
    static let mutedPurple = PaletteColor(id: "mutedPurple", name: "Mauve", tier: .muted, light: 0x71648B, dark: 0xA397BC, lightFill: 0.21, darkFill: 0.16)
    static let mutedPink = PaletteColor(id: "mutedPink", name: "Rosewood", tier: .muted, light: 0x885D71, dark: 0xBA91A3, lightFill: 0.21, darkFill: 0.15)

    // ── Neutral ────────────────────────────────────────────────────────────
    /// The "no colour" tag, for a category that shouldn't compete. Carried over
    /// from the previous palette unchanged, id included, so anyone already on it
    /// stays on it.
    static let graphite = PaletteColor(id: "graphite", name: "Graphite", tier: .neutral, light: 0x4C4A47, dark: 0xA9A6A0, lightFill: 0.17, darkFill: 0.14)

    /// The full swatch set, in tier order — soft → punchy → quiet → grey. Within
    /// a tier the order is the hue wheel, so the same column is the same hue in
    /// every tier of the picker.
    static let all: [PaletteColor] = pastels + vivids + muteds + neutrals

    static let pastels: [PaletteColor] = [
        .pastelRed, .pastelOrange, .pastelYellow, .pastelGreen, .pastelBlue, .pastelPurple, .pastelPink,
    ]
    static let vivids: [PaletteColor] = [
        .vividRed, .vividOrange, .vividYellow, .vividGreen, .vividBlue, .vividPurple, .vividPink,
    ]
    static let muteds: [PaletteColor] = [
        .mutedRed, .mutedOrange, .mutedYellow, .mutedGreen, .mutedBlue, .mutedPurple, .mutedPink,
    ]
    static let neutrals: [PaletteColor] = [.graphite]

    static func tier(_ tier: PaletteTier) -> [PaletteColor] {
        switch tier {
        case .pastel: return pastels
        case .vivid: return vivids
        case .muted: return muteds
        case .neutral: return neutrals
        }
    }

    /// Resolve a stored id, translating the ids the previous palette used.
    /// Without the second lookup every saved choice would silently snap back to
    /// a default on the update that shipped this file.
    static func named(_ id: String?) -> PaletteColor? {
        guard let id else { return nil }
        if let match = all.first(where: { $0.id == id }) { return match }
        return legacyIDs[id].flatMap { renamed in all.first { $0.id == renamed } }
    }

    /// Old id → its nearest survivor. `graphite` is absent because it kept its
    /// id; `teal` and `fog` have no equivalent hue in the seven-hue grid and go
    /// to the closest one that does.
    private static let legacyIDs: [String: String] = [
        "blush": "pastelRed",
        "lavender": "pastelPurple",
        "mint": "pastelGreen",
        "inkBlue": "vividBlue",
        "teal": "vividGreen",
        "forest": "vividGreen",
        "plum": "vividPurple",
        "rose": "vividPink",
        "terracotta": "vividOrange",
        "amber": "vividYellow",
        "slate": "mutedBlue",
        "sage": "mutedGreen",
        "fog": "mutedBlue",
        "mauve": "mutedPurple",
    ]
}

// MARK: - Contrast

/// WCAG contrast ratio between two opaque hexes, 1…21.
func contrast(_ a: UInt, _ b: UInt) -> Double {
    let la = relativeLuminance(a), lb = relativeLuminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

/// WCAG relative luminance. The channels are gamma-decoded first, which a plain
/// weighted average of the sRGB values doesn't do and gets wrong by enough to
/// matter around the 4.5:1 line.
func relativeLuminance(_ hex: UInt) -> Double {
    func channel(_ raw: UInt) -> Double {
        let c = Double(raw) / 255
        return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel((hex >> 16) & 0xFF)
        + 0.7152 * channel((hex >> 8) & 0xFF)
        + 0.0722 * channel(hex & 0xFF)
}

/// The palette currently in force. Read by `Theme.Colors` at colour-resolution
/// time; written by `AppSettings`. Plain statics on purpose — see the file note.
enum ThemePalette {
    nonisolated(unsafe) static var accent: PaletteColor = .vividBlue
    nonisolated(unsafe) static var categories: [Category: PaletteColor] = ThemePalette.defaultCategories
    /// What the app shipped with, and what "Reset" goes back to.
    static let defaultAccent: PaletteColor = .vividBlue
    static let defaultCategories: [Category: PaletteColor] = [
        .work: .mutedBlue,
        .personal: .vividPurple,
        .health: .vividGreen,
    ]
    static func color(for category: Category) -> PaletteColor {
        categories[category] ?? defaultCategories[category] ?? .mutedBlue
    }
}
