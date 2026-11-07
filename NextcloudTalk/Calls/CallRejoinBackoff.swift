//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Counter and pause for repeated attempts to join a call again (after the signaling session was lost,
/// or after the ICE connection failed). A short loss of the network must not end the call, so an attempt
/// that fails for a reason which can pass (no network, server busy) is repeated with a growing pause.
/// An attempt that fails for good (no permission, lobby) is not repeated.
///
/// The type holds no timer and knows no clock: the caller waits for `nextDelay()` seconds and then tries again.
/// One instance covers one "episode" of joining again, `reset()` ends the episode when the call is joined.
struct CallRejoinBackoff {

    /// The pause before the 1st, 2nd, 3rd, ... repeat. The last value is used for all further repeats.
    static let defaultDelays: [TimeInterval] = [2, 4, 8, 15]

    /// 2 + 4 + 8 + 15 + 15 + 15 = 59 s, that is two signaling resume windows (30 s each) of waiting for the network
    static let defaultMaxAttempts = 6

    /// The pause between the rejoins of a call whose ICE connection failed: the first rejoin at once, so a single
    /// glitch heals as fast as it did without a pause, then 2, 4, 8 and 15 s. 15 s stays the ceiling and the number of
    /// attempts is not limited, because the call is not lost for the user: the user sees it reconnecting and ends it.
    /// This is what the Android client does.
    static let failedIceDelays: [TimeInterval] = [0, 2, 4, 8, 15]

    /// The time a connection has to stay connected, without a break, before the pause starts over. It has to be
    /// longer than the longest pause (15 s) and than the cycle of a connection which comes up and fails again
    /// after 10 to 30 s (TURN lets the checks pass, the media does not), otherwise such a cycle rejoins at once, always.
    static let failedIceStableTime: TimeInterval = 60

    /// The counter for the rejoins after a failed ICE connection, see `failedIceDelays`
    static func forFailedIce() -> CallRejoinBackoff {
        return CallRejoinBackoff(delays: failedIceDelays, maxAttempts: Int.max, stableTime: failedIceStableTime)
    }

    private let delays: [TimeInterval]
    private let maxAttempts: Int
    private let stableTime: TimeInterval

    /// Since when the connection holds without a break, nil if it does not
    private var connectedSince: TimeInterval?

    /// Number of repeats that were handed out by `nextDelay()` since the last `reset()`
    private(set) var attempts = 0

    init(delays: [TimeInterval] = CallRejoinBackoff.defaultDelays, maxAttempts: Int = CallRejoinBackoff.defaultMaxAttempts, stableTime: TimeInterval = .infinity) {
        self.delays = delays.isEmpty ? CallRejoinBackoff.defaultDelays : delays
        self.maxAttempts = max(0, maxAttempts)
        self.stableTime = stableTime
    }

    /// No more repeats are allowed
    var isExhausted: Bool {
        return attempts >= maxAttempts
    }

    /// Takes one repeat and returns the pause to wait before it, or nil if all repeats are used up.
    mutating func nextDelay() -> TimeInterval? {
        guard !isExhausted else { return nil }

        let delay = delays[min(attempts, delays.count - 1)]
        attempts += 1

        return delay
    }

    /// The call is joined (or given up), the next loss of the connection starts with the shortest pause again
    mutating func reset() {
        attempts = 0
    }

    /// The connection is up. The first call of a run counts, the later ones (connected, then completed) do not.
    /// - Parameter now: a monotonic clock, in seconds
    mutating func noteConnected(now: TimeInterval) {
        if connectedSince == nil {
            connectedSince = now
        }
    }

    /// The connection is shaky (disconnected), so the time it held does not count
    mutating func noteDisturbed() {
        connectedSince = nil
    }

    /// The connection failed. If it held for `stableTime` before, the failure is a new one and the pause starts over,
    /// otherwise the failure goes on with the growing pause. Call it before `nextDelay()`.
    mutating func noteFailed(now: TimeInterval) {
        if let connectedSince, now - connectedSince >= stableTime {
            reset()
        }

        connectedSince = nil
    }

    /// Tells if an attempt that failed with this HTTP status may succeed when repeated.
    ///
    /// - 0 (no response, no network), 408, 429 and 5xx: the network or the server is busy, it can pass
    /// - 404: the session is gone at the server (it expired while the network was down). The same request
    ///   fails again, but a new session helps, so it is repeated after a new session was created
    /// - all other 4xx are final: 400 (recording consent), 401 (account), 403 (read-only or no permission),
    ///   409 (conflict), 412 (lobby, not a moderator)
    /// - codes outside of HTTP (e.g. a failed join at the signaling server) are no answer of the server about
    ///   the request, so they are repeated
    static func isRetryable(statusCode: Int) -> Bool {
        switch statusCode {
        case 404, 408, 429:
            return true
        case 400..<500:
            return false
        default:
            return true
        }
    }
}
