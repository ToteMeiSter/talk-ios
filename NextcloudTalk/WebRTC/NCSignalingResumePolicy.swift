//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Decides what happens to the messages which were queued while the external signaling websocket had no hello yet.
enum NCSignalingResumePolicy {

    /// What happens to a message that was queued while the websocket had no hello yet, once the hello arrives.
    enum QueuedMessageAction: Equatable {
        case send
        /// The message is dropped and its completion block is called with an error
        case drop
        /// The message is dropped and its completion block is not called, because the goal of the message is reached
        case dropSilently
    }

    /// Decides what to do with a queued message when the hello arrives.
    ///
    /// A queued message was produced for the old session: a `message` or `control` names sessions of the old call
    /// state (offer, candidate, mute, requestoffer), a `bye` closes a session which is gone already. With a new
    /// session none of them is valid, they would only disturb the call which is joined again.
    /// - Parameters:
    ///   - messageType: the `type` of the queued message
    ///   - sessionReplaced: the hello belongs to another session than the one the message was queued for
    static func queuedMessageAction(messageType: String?, sessionReplaced: Bool) -> QueuedMessageAction {
        guard sessionReplaced else { return .send }

        switch messageType {
        case "message", "control":
            return .drop
        case "bye":
            return .dropSilently
        default:
            return .send
        }
    }
}
