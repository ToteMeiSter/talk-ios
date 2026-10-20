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

    private let delays: [TimeInterval]
    private let maxAttempts: Int

    /// Number of repeats that were handed out by `nextDelay()` since the last `reset()`
    private(set) var attempts = 0

    init(delays: [TimeInterval] = CallRejoinBackoff.defaultDelays, maxAttempts: Int = CallRejoinBackoff.defaultMaxAttempts) {
        self.delays = delays.isEmpty ? CallRejoinBackoff.defaultDelays : delays
        self.maxAttempts = max(0, maxAttempts)
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
