//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Helpers to keep the list of users of a call when the external signaling server only sends part of it.
///
/// A `participants` `update` event can name only some of the sessions in the room. A session that is not
/// named keeps the state it had before. The same is done by the web client (`usersChanged` in `webrtc.js`).
/// A session leaves the call with an `inCall` of 0, with a room `leave` event, or with an `all` update.
enum CallUsersMerge {

    /// Returns `known` with every entry of `update` written over the entry of the same session.
    /// New sessions are appended, sessions that are not in `update` stay as they are.
    static func merging(_ update: [[String: Any]], into known: [[String: Any]]) -> [[String: Any]] {
        var result = known

        for user in update {
            guard let sessionId = user["sessionId"] as? String else { continue }

            if let index = result.firstIndex(where: { $0["sessionId"] as? String == sessionId }) {
                result[index] = user
            } else {
                result.append(user)
            }
        }

        return result
    }

    /// Returns `known` without the entries of the given sessions.
    static func removing(sessionIds: [String], from known: [[String: Any]]) -> [[String: Any]] {
        return known.filter { user in
            guard let sessionId = user["sessionId"] as? String else { return true }

            return !sessionIds.contains(sessionId)
        }
    }
}
