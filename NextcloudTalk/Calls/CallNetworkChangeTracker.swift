//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The kind of link the device reaches the network with. VPN tunnels and loopback are no physical link
/// and are not listed, so switching a VPN on or off is no change of the link.
enum CallNetworkInterface: Equatable {
    case wifi
    case cellular
    case wired
}

/// What the call needs to know about the system network path (`NWPath`), without the framework type
struct CallNetworkPath: Equatable {

    /// The device has a route to the network
    let isSatisfied: Bool

    /// The most preferred physical link of the path, nil if there is none (e.g. only a VPN tunnel)
    let primaryInterface: CallNetworkInterface?
}

enum CallNetworkChange: Equatable {

    /// The most preferred link changed, e.g. Wi-Fi to cellular and back
    case interfaceSwitched

    /// The network was gone and is back (airplane mode, Wi-Fi off and on, tunnel). The link may be the same,
    /// but the connections of the call were bound to the network that was gone
    case networkReturned
}

/// Decides whether an update of the network path means that the connections of a call (bound to the address of the
/// old network) have to be looked at. Path updates come in bursts and for reasons which do not touch the call
/// (VPN on or off, a second link appears next to the preferred one, low data mode), those are no change.
///
/// Switching a VPN on or off is no change, in both directions: while a tunnel is the only interface of the path
/// there is no physical link, so the link is compared with the last physical link seen, not with the previous path.
///
/// Not thread-safe: use it from one queue.
struct CallNetworkChangeTracker {

    private var lastPath: CallNetworkPath?

    /// The last physical link any path had. A path with a tunnel only does not forget it.
    private var lastPhysicalInterface: CallNetworkInterface?

    /// - Returns: the change, if the path update is one that matters for the call. The first update only
    ///   tells the starting point and never is a change.
    mutating func update(_ path: CallNetworkPath) -> CallNetworkChange? {
        let previous = lastPath
        let previousPhysical = lastPhysicalInterface

        lastPath = path
        lastPhysicalInterface = path.primaryInterface ?? previousPhysical

        guard let previous, path.isSatisfied else { return nil }

        if !previous.isSatisfied {
            return .networkReturned
        }

        // Without an earlier physical link (the call started behind a tunnel) there is nothing to compare with
        if let primary = path.primaryInterface, let previousPhysical, primary != previousPhysical {
            return .interfaceSwitched
        }

        return nil
    }
}

/// Limits how often a call reacts on a change of the network. A reaction resets the pauses between rejoins and
/// replaces the signaling socket, which is the right thing for a network that changed, but a network that flips
/// back and forth would repeat it all the time and never let a pause grow.
/// A change inside the pause is not lost: the caller does it when the pause is over.
///
/// Not thread-safe: use it from one queue.
struct CallNetworkReactionLimiter {

    /// Time between two reactions
    static let minInterval: TimeInterval = 10

    private var lastReaction: TimeInterval?

    /// - Parameter now: a monotonic clock, in seconds
    /// - Returns: 0 and takes the reaction if it is allowed now, otherwise the time to wait for it
    mutating func reserve(now: TimeInterval) -> TimeInterval {
        if let lastReaction, now - lastReaction < Self.minInterval {
            return Self.minInterval - (now - lastReaction)
        }

        lastReaction = now
        return 0
    }
}
