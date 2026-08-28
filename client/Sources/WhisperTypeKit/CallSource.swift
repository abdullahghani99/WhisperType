import Foundation

/// Naming what we heard, in words a person would use.
///
/// macOS reports the process that holds the microphone, which is often a helper:
/// "Microsoft Teams ModuleHost", "Google Chrome Helper (Renderer)". Showing that
/// raw is the difference between a tool that feels finished and one that feels
/// like a debug build.
public enum CallSource {

    private static let known: [(needle: String, name: String)] = [
        ("microsoft teams", "Teams"),
        ("zoom", "Zoom"),
        ("webex", "Webex"),
        ("facetime", "FaceTime"),
        ("slack", "Slack"),
        ("discord", "Discord"),
        ("google chrome", "Chrome"),
        ("safari", "Safari"),
        ("microsoft edge", "Edge"),
        ("skype", "Skype"),
        ("google meet", "Meet"),
    ]

    /// The app a capturing process belongs to.
    public static func friendlyName(_ raw: String) -> String {
        let lower = raw.lowercased()
        for k in known where lower.contains(k.needle) { return k.name }

        // Unknown app: strip helper scaffolding but keep its identity, because a
        // real name is more useful than a generic one.
        var s = raw
        for suffix in [" Helper", " ModuleHost", " (Renderer)", " (Plugin)", " (GPU)"] {
            s = s.replacingOccurrences(of: suffix, with: "")
        }
        if let paren = s.firstIndex(of: "(") {
            s = String(s[s.startIndex..<paren])
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// The line shown in the offer. Never produces "a call call".
    public static func offerTitle(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.lowercased() != "a call",
              !trimmed.hasPrefix("pid ") else { return "Call detected" }
        let name = friendlyName(trimmed)
        guard !name.isEmpty else { return "Call detected" }
        return name.lowercased().hasSuffix("call") ? name : "\(name) call"
    }
}
