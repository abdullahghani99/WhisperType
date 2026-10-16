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

    /// The route to use, in priority order: an explicit environment override
    /// (so a test harness can point somewhere else), then the speaker's stored
    /// choice, then the office route — which works both on the LAN and, via
    /// WARP, away from it.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               stored: String? = UserDefaults.standard.string(forKey: defaultsKey)) -> (url: String, route: ServerRoute?) {
        if let override = environment["VF_SERVER_URL"], !override.isEmpty {
            return (override, ServerRoute.allCases.first { $0.url == override })
        }
        let route = stored.flatMap(ServerRoute.init(rawValue:)) ?? .office
        return (route.url, route)
    }
}
