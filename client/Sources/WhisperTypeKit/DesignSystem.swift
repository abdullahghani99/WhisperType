import SwiftUI

/// The single source of truth for VoiceFlow's visual language. Every surface
/// imports these tokens; no raw hex lives anywhere else in the app.
///
/// Warm-shifted throughout: there are no cold greys and no system colours here.
/// Shadows use warm ink (#1A1714), never black — black shadows over warm
/// surfaces read as dirt.
public enum VF {

    // MARK: - Colour

    public enum Color {
        private static func hex(_ v: UInt32, _ alpha: Double = 1) -> SwiftUI.Color {
            SwiftUI.Color(.sRGB,
                          red: Double((v >> 16) & 0xFF) / 255,
                          green: Double((v >> 8) & 0xFF) / 255,
                          blue: Double(v & 0xFF) / 255,
                          opacity: alpha)
        }

        /// Window background. Barely-warm — never clinical white.
        public static func canvas(dark: Bool) -> SwiftUI.Color { dark ? hex(0x1A1714) : hex(0xFEFCFA) }
        /// Cards and panels.
        public static func surface(dark: Bool) -> SwiftUI.Color { dark ? hex(0x2A2320) : hex(0xFFFFFF) }
        /// Hover / selected rows.
        public static func surfaceHover(dark: Bool) -> SwiftUI.Color { dark ? hex(0x3A322E) : hex(0xF7F5F3) }
        /// Hairlines and dividers.
        public static func border(dark: Bool) -> SwiftUI.Color { dark ? hex(0x3A322E) : hex(0xE5E1DD, 0.6) }
        /// Headings and primary text.
        public static func ink(dark: Bool) -> SwiftUI.Color { dark ? hex(0xF7F5F3) : hex(0x1A1714) }
        /// Body copy.
        public static func body(dark: Bool) -> SwiftUI.Color { dark ? hex(0xEFEDEB) : hex(0x3D3833) }
        /// Secondary text and labels.
        public static func muted(dark: Bool) -> SwiftUI.Color { dark ? hex(0x928A81) : hex(0x6B6560) }
        /// Placeholders and disabled text.
        public static func faint(dark: Bool) -> SwiftUI.Color { dark ? hex(0x6B6560) : hex(0xA8A29E) }

        /// The heartbeat. Action and live state ONLY — never decoration.
        public static let accent = hex(0xE7000B)

        public static func healthy(dark: Bool) -> SwiftUI.Color { dark ? hex(0x5CB87A) : hex(0x2D8A56) }
        public static func attention(dark: Bool) -> SwiftUI.Color { dark ? hex(0xE0A63C) : hex(0xB8860B) }
    }

    // MARK: - Type
    //
    // New York (serif) carries display/title/sectionHeading — it is what makes a
    // meeting read as a document rather than a database row. Inter carries all
    // UI and body text. The two never mix within a line.

    public enum Font {
        /// Set by the app at launch once Inter is registered; falls back to the
        /// system sans when registration fails so text always renders.
        public static var interAvailable = false

        private static func sans(_ size: CGFloat, _ weight: SwiftUI.Font.Weight) -> SwiftUI.Font {
            interAvailable
                ? .custom(interName(weight), size: size)
                : .system(size: size, weight: weight)
        }

        private static func interName(_ weight: SwiftUI.Font.Weight) -> String {
            switch weight {
            case .semibold, .bold: return "Inter-SemiBold"
            case .medium: return "Inter-Medium"
            default: return "Inter-Regular"
            }
        }

        private static func serif(_ size: CGFloat, _ weight: SwiftUI.Font.Weight) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .serif)
        }

        public static let display = serif(32, .semibold)
        public static let title = serif(22, .semibold)
        public static let sectionHeading = serif(15, .semibold)

        public static let heading = sans(15, .semibold)
        public static let body = sans(14, .regular)
        public static let callout = sans(13, .regular)
        public static let caption = sans(11, .medium)
    }

    /// Tracking (letter spacing) per style, in points at the style's size.
    public enum Tracking {
        public static let display: CGFloat = -0.64   // -0.02em at 32pt
        public static let title: CGFloat = -0.22     // -0.01em at 22pt
        public static let caption: CGFloat = 0.22    // +0.02em at 11pt
    }

    /// Line spacing (SwiftUI's extra leading) per style.
    public enum Leading {
        public static let display: CGFloat = 3
        public static let body: CGFloat = 8          // ~1.6 at 14pt
        public static let caption: CGFloat = 4
    }

    // MARK: - Spacing (4px grid — no off-grid values anywhere)

    public enum Space {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 48
        public static let xxxxl: CGFloat = 64
    }

    public enum Radius {
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let pill: CGFloat = 24
    }

    // MARK: - Shadow (warm ink, never black)

    public enum Shadow {
        private static let ink = SwiftUI.Color(.sRGB, red: 26/255, green: 23/255, blue: 20/255, opacity: 1)
        public static let layer1: (color: SwiftUI.Color, radius: CGFloat, y: CGFloat) = (ink.opacity(0.06), 3, 1)
        public static let layer2: (color: SwiftUI.Color, radius: CGFloat, y: CGFloat) = (ink.opacity(0.08), 12, 4)
        public static let layer3: (color: SwiftUI.Color, radius: CGFloat, y: CGFloat) = (ink.opacity(0.12), 24, 8)
    }

    // MARK: - Display helpers (pure, testable)

    /// Reading time at 225 wpm, rounded up. Sets expectation before the human
    /// commits to reading — the small courtesy Wispr gets right.
    public static func readTime(wordCount: Int) -> String {
        guard wordCount > 0 else { return "under a minute" }
        let minutes = Int((Double(wordCount) / 225.0).rounded(.up))
        return minutes <= 1 ? "under a minute" : "\(minutes) min read"
    }

    /// Sentence case: capitalise the first word, lower the rest — but leave
    /// all-caps tokens (VAT, D365, AE7) alone, since those are acronyms and
    /// product codes, not Title Case.
    public static func sentenceCase(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let words = trimmed.split(separator: " ", omittingEmptySubsequences: false)
        let mapped = words.enumerated().map { idx, w -> String in
            let word = String(w)
            guard !word.isEmpty else { return word }
            let letters = word.filter { $0.isLetter }
            // All-caps (or digit-bearing) tokens are acronyms/codes — keep verbatim.
            if !letters.isEmpty, letters.allSatisfy({ $0.isUppercase }) { return word }
            if word.contains(where: { $0.isNumber }) { return word }
            if idx == 0 { return word.prefix(1).uppercased() + word.dropFirst().lowercased() }
            return word.lowercased()
        }
        return mapped.joined(separator: " ")
    }
}
