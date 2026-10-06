//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Decides whether a peer connection should restart ICE, like the web client does for calls without a MCU.
/// With a MCU the connection to the MCU is re-established instead, so ICE restarts are never used there.
struct NCIceRestartTracker {

    static let maxAttempts = 5

    /// Time in seconds a peer needs to stay "disconnected" before ICE is restarted
    static let disconnectedDelay: TimeInterval = 5

    private(set) var attempts = 0

    var isExhausted: Bool {
        return attempts >= Self.maxAttempts
    }

    /// Returns true and counts an attempt, if ICE should be restarted now.
    /// - Parameters:
    ///   - hasMCU: The call uses a MCU
    ///   - isOfferer: Our local description is an offer. Only the side that sent the offer restarts ICE (with a new offer)
    ///   - isSignalingStable: No negotiation is running
    mutating func startRestart(hasMCU: Bool, isOfferer: Bool, isSignalingStable: Bool) -> Bool {
        guard !hasMCU, isOfferer, isSignalingStable, !isExhausted else { return false }

        attempts += 1
        return true
    }

    /// To be called when the connection (re-)established
    mutating func reset() {
        attempts = 0
    }
}
