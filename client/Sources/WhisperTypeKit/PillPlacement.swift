import Foundation

/// Geometry describes the visible capsule, not its large transparent window.
public enum PillEdge: String, Codable, CaseIterable { case top, bottom, left, right }
public enum PillGeometry {
    public static func clamp(_ point: CGPoint, size: CGSize, in frame: CGRect, gap: CGFloat = 14) -> CGPoint {
        let x = min(size.width / 2 + gap, frame.width / 2)
        let y = min(size.height / 2 + gap, frame.height / 2)
        return CGPoint(x: min(max(point.x, frame.minX + x), frame.maxX - x),
                       y: min(max(point.y, frame.minY + y), frame.maxY - y))
    }
    public static func center(edge: PillEdge, size: CGSize, in frame: CGRect) -> CGPoint {
        var point = CGPoint(x: frame.midX, y: frame.midY)
        switch edge {
        case .top: point.y = frame.maxY
        case .bottom: point.y = frame.minY
        case .left: point.x = frame.minX
        case .right: point.x = frame.maxX
        }
        return clamp(point, size: size, in: frame)
    }
    public static func nearestEdge(to point: CGPoint, in frame: CGRect, previous: PillEdge? = nil) -> PillEdge {
        let distances: [(PillEdge, CGFloat)] = [(.top, abs(frame.maxY - point.y)), (.bottom, abs(point.y - frame.minY)),
                                              (.left, abs(point.x - frame.minX)), (.right, abs(frame.maxX - point.x))]
        let nearest = distances.min { $0.1 < $1.1 }!
        if let previous, let old = distances.first(where: { $0.0 == previous }), old.1 <= nearest.1 + 14 { return previous }
        return nearest.0
    }
    public static func normalized(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - frame.minX) / max(1, frame.width))),
                y: min(1, max(0, (point.y - frame.minY) / max(1, frame.height))))
    }
}

public final class PillPlacement {
    public struct Choice: Codable, Equatable {
        public var edge: PillEdge
        public var x: Double
        public var y: Double
        fileprivate var legacyFree = false
        private enum CodingKeys: String, CodingKey { case edge, x, y }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try c.decode(String.self, forKey: .edge)
            legacyFree = raw == "free"
            guard legacyFree || PillEdge(rawValue: raw) != nil else {
                throw DecodingError.dataCorruptedError(forKey: .edge, in: c, debugDescription: "Unknown pill edge")
            }
            edge = PillEdge(rawValue: raw) ?? .bottom
            x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            // Preserve disconnected displays' legacy coordinates until their
            // actual frame is available. Free placement is never selectable.
            try c.encode(legacyFree ? "free" : edge.rawValue, forKey: .edge)
            try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        }
        public init(edge: PillEdge = .bottom, x: Double = 0.5, y: Double = 0.5) { self.edge = edge; self.x = x; self.y = y }
    }
    private struct Saved: Codable { var display: String?; var choices: [String: Choice] }
    private var saved = Saved(display: nil, choices: [:])
    private let store: UserDefaults
    public static let key = "vf_pillPlacement_v2"
    public var preferredDisplay: String? { saved.display }
    public init(store: UserDefaults) {
        self.store = store
        if let data = store.data(forKey: Self.key), let decoded = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = decoded
            saved.choices = saved.choices.filter { $0.value.x.isFinite && $0.value.y.isFinite }
        }
    }
    public func choice(for display: String, in frame: CGRect? = nil) -> Choice? {
        guard var choice = saved.choices[display] else { return nil }
        if choice.legacyFree {
            guard let frame else { return nil }
            let point = CGPoint(x: frame.minX + choice.x * frame.width, y: frame.minY + choice.y * frame.height)
            choice = Choice(edge: PillGeometry.nearestEdge(to: point, in: frame))
            saved.choices[display] = choice
            persist()
        }
        return choice
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { store.set(data, forKey: Self.key) }
    }
    public func remember(_ choice: Choice, display: String) {
        guard choice.x.isFinite, choice.y.isFinite else { return }
        saved.display = display; saved.choices[display] = choice
        persist()
    }
}
