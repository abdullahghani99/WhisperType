import Foundation

/// Which network path the client uses to reach the dictation server.
///
/// The same machine is reachable two ways, and which one works depends on
/// where the speaker is and what the network is doing that day. On 2026-10-16
/// the Tailscale path to ms2 degraded to 2-4 KB/s with 50% packet loss — a
/// 500 KB dictation took four minutes and timed out — while the office route
/// over the Cloudflare WARP private network answered in 62 ms and uploaded at
/// 3.9 MB/s. Nothing was wrong with either machine.
///
/// So the route is a choice the speaker can make, not a constant compiled in.
/// By default it is not a choice at all: "automatic" probes both and uses the
/// first that answers. Pinning office by hand (2026-11-03) broke every dictation
/// on 2026-11-12, when office went dark and Tailscale had long recovered.
public enum ServerRoute: String, CaseIterable, Sendable {
    /// ms2 on the office LAN: direct when in the office, and over the Cloudflare
    /// WARP private network (127.0.0.1/24) when away.
    case office
    /// ms2 over Tailscale.
    case tailscale

    public static let defaultsKey = "vf_serverRoute"

    public var url: String {
        switch self {
        case .office:    return "http://192.0.2.10:8790"
        case .tailscale: return "http://198.51.100.10:8790"
        }
    }

    public var title: String {
        switch self {
        case .office:    return "Office / Cloudflare"
        case .tailscale: return "Tailscale"
        }
    }

    public static let automatic = "automatic"
    /// Tailscale reaches ms2 from anywhere; office needs the LAN or WARP.
    public static let automaticOrder: [ServerRoute] = [.tailscale, .office]

    /// The route to use: an explicit environment override (a test harness), then
    /// a route the speaker pinned, else automatic (`route` and `pinned` nil/false).
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               stored: String? = UserDefaults.standard.string(forKey: defaultsKey)) -> (url: String, route: ServerRoute?, pinned: Bool) {
        if let override = environment["VF_SERVER_URL"], !override.isEmpty {
            return (override, ServerRoute.allCases.first { $0.url == override }, true)
        }
        if let route = stored.flatMap(ServerRoute.init(rawValue:)) { return (route.url, route, true) }
        return (automaticOrder[0].url, nil, false)
    }
}

/// Picks the first candidate base URL that answers, in preference order. Shared
/// by every copy of the client, so one probe moves them all.
public final class RouteSelector: @unchecked Sendable {
    public let candidates: [String]
    private let lock = NSLock()
    private var chosen: String

    public init(candidates: [String]) {
        precondition(!candidates.isEmpty)
        self.candidates = candidates
        chosen = candidates[0]
    }

    public var current: String { lock.lock(); defer { lock.unlock() }; return chosen }

    /// Probes all candidates at once. Keeps the current one when none answer, so
    /// an offline Mac does not flap between two dead routes.
    @discardableResult
    public func reselect(reachable: @escaping @Sendable (String) async -> Bool) async -> String {
        let up = await withTaskGroup(of: (String, Bool).self) { group -> Set<String> in
            for base in candidates { group.addTask { (base, await reachable(base)) } }
            var answered = Set<String>()
            for await (base, ok) in group where ok { answered.insert(base) }
            return answered
        }
        lock.lock(); defer { lock.unlock() }
        if let best = candidates.first(where: up.contains) { chosen = best }
        return chosen
    }
}
