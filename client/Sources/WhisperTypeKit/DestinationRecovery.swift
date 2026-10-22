import Foundation

/// A bounded grace period for the ORIGINAL destination, never a retarget.
public struct DestinationRecovery {
    public enum Decision { case ready, wait, stop }
    private var samples = 0
    private var consecutiveMatches = 0
    public init() {}
    public mutating func observe(matches: Bool, applicationChangedOnly: Bool, cancelled: Bool) -> Decision {
        guard !cancelled else { return .stop }
        samples += 1
        if matches {
            consecutiveMatches += 1
            if samples == 1 || consecutiveMatches >= 2 { return .ready }
        } else {
            consecutiveMatches = 0
            // Changed fields/windows, denied permissions and secure fields are
            // not a transient application-focus mismatch.
            if !applicationChangedOnly { return .stop }
        }
        return samples >= 9 ? .stop : .wait
    }
}
