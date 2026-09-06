import Foundation

/// A narrow fallback after server cleanup. Only an explicitly announced,
/// complete sequence becomes a list; item wording is never generated or edited.
public enum SpokenListFormatter {
    public static func format(_ text: String, destinationName: String?) -> String {
        guard let destinationName = destinationName, !destinationName.isEmpty else { return text }
        let app = destinationName.lowercased()
        let codeApps = ["terminal", "warp", "iterm", "iterm2", "code", "visual studio code", "xcode", "cursor", "zed", "jetbrains", "idea", "pycharm", "webstorm", "sublime", "emacs", "vim", "bbedit"]
        guard !codeApps.contains(where: { app == $0 || app.hasPrefix($0 + " ") }),
              !text.contains("\n"), !text.contains("`"),
              text.range(of: #"[{}$<>]|\b(command|script|code|terminal)\b"#, options: .regularExpression.union(.caseInsensitive)) == nil else { return text }
        let source = text as NSString
        let introPattern = #"\b(two|three|four|five|[2-5])\s+(things|points|items|questions|steps)\s*[.!?:]\s+"#
        let intros = matches(introPattern, text)
        guard intros.count == 1, let intro = intros.first else { return text }
        let numbers = ["one", "two", "three", "four", "five", "six"]
        let announced = source.substring(with: intro.range(at: 1)).lowercased()
        let count = Int(announced) ?? numbers.firstIndex(of: announced).map { $0 + 1 } ?? 0
        let start = NSMaxRange(intro.range)
        let tail = source.substring(from: start)
        let markers = matches(#"(?:^|(?<=[.!?])\s+)(one|two|three|four|five|six|[1-6])[,.):]\s+"#, tail)
        guard markers.count == count, markers.first?.range.location == 0 else { return text }
        let body = tail as NSString
        var items: [String] = []
        for (index, marker) in markers.enumerated() {
            let word = body.substring(with: marker.range(at: 1)).lowercased()
            guard word == numbers[index] || word == String(index + 1) else { return text }
            let itemStart = NSMaxRange(marker.range)
            let itemEnd = index + 1 < count ? markers[index + 1].range.location : body.length
            let item = body.substring(with: NSRange(location: itemStart, length: itemEnd - itemStart)).trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { return text }
            items.append("\(index + 1). \(item)")
        }
        return source.substring(to: start).trimmingCharacters(in: .whitespaces) + "\n\n" + items.joined(separator: "\n")
    }

    private static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
