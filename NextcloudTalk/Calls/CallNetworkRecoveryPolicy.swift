//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The state of the ICE connection of our own publisher, as far as the decision needs it
enum CallPublisherLink: Equatable {

    /// We do not publish (no local audio and video: a listener without the right to publish, or microphone and
    /// camera denied). There is nothing of ours to replace, only the connections we receive on can be dead.
    case absent

    /// connected or completed
    case connected

    /// failed or closed
    case lost

    /// new, checking, disconnected: it may come back
    case unknown
}

enum CallNetworkRecoveryAction: Equatable {

    /// Join the call again with a new session
    case rejoin

    /// Look at the publisher connection again after `CallNetworkRecoveryPolicy.recheckDelay`
    case recheck

    /// The connection is fine, keep the call
    case keep

    /// Without a publisher: ask for a new offer on every connection we receive on which did not come back.
    /// The call is not joined again, the other participants keep seeing us.
    case refreshSubscribers
}

/// Decides what happens to a call with a MCU after the device changed its network.
///
/// Joining again is the last resort, the other participants see us leave. The ICE of the publisher often finds the
/// way over the new network by itself (it gathers candidates on the new link), so it gets a few seconds
/// before the call is joined again. Only a connection which did not come back is replaced.
enum CallNetworkRecoveryPolicy {

    /// Time between two looks at the publisher connection
    static let recheckDelay: TimeInterval = 3

    /// Number of looks after which a connection which did not come back is replaced: 3 * 3 s = 9 s
    static let maxRechecks = 3

    static func onNetworkChanged(publisher: CallPublisherLink) -> CallNetworkRecoveryAction {
        return publisher == .lost ? .rejoin : .recheck
    }

    /// - Parameter recheck: the number of this look, starting with 1
    static func onRecheck(publisher: CallPublisherLink, recheck: Int) -> CallNetworkRecoveryAction {
        switch publisher {
        case .absent:
            return .refreshSubscribers
        case .connected:
            return .keep
        case .lost:
            return .rejoin
        case .unknown:
            return recheck >= maxRechecks ? .rejoin : .recheck
        }
    }
}
