import Foundation

/// Parsing of speaker labels out of a diarized transcript. The server writes
/// turns as "**Name:** text", so the UI can offer each distinct speaker for
/// renaming.
public enum SpeakerText {
    /// Distinct speaker labels, in order of first appearance. A bold run without
    /// a trailing colon is a notes heading, not a speaker, and is ignored.
    public static func names(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var seen: [String] = []
        let pattern = #"\*\*([^*:\n]{1,60}):\*\*"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges > 1 else { continue }
            let name = ns.substring(with: m.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !seen.contains(name) { seen.append(name) }
        }
        return seen
    }
}
