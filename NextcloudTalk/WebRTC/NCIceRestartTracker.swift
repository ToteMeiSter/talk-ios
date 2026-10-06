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

    /// Time in seconds after a failed ICE connection, in which the connection needs to be established again
    /// (by an ICE restart of us or of the other side). A restart usually takes a few seconds, so 15s leaves room
    /// for slow networks, but is still short enough to not leave the user in a silent call.
    static let recoveryTimeout: TimeInterval = 15

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

    /// The recovery watchdog is armed on the first failure and stays armed until the connection is established again
    static func shouldArmRecoveryWatchdog(hasMCU: Bool, isFailed: Bool, isAlreadyArmed: Bool) -> Bool {
        return !hasMCU && isFailed && !isAlreadyArmed
    }

    /// When the watchdog fires and the connection is still not established, the ICE restart did not help
    /// (we are not the offerer, the limit was reached, or the offer or its answer got lost).
    /// Then we fall back to joining the call again, which is what happened before ICE restarts.
    static func shouldFallBackToRejoin(hasMCU: Bool, isConnected: Bool) -> Bool {
        return !hasMCU && !isConnected
    }

    /// To be called when the connection (re-)established
    mutating func reset() {
        attempts = 0
    }
}
