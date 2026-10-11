//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Decides whether the external signaling session may be resumed with a `resumeid`.
/// The server drops a session some time after its connection was lost, so we only try to resume within that window.
enum NCSignalingResumePolicy {

    /// The window (in seconds) in which a session can be resumed after the connection was lost
    static let resumeWindow: TimeInterval = 30

    /// The moment to remember when the connection is lost. An already remembered moment is kept,
    /// because failed reconnect attempts must not extend the window.
    static func connectionLostTime(existing: TimeInterval?, now: TimeInterval) -> TimeInterval {
        return existing ?? now
    }

    static func canResume(resumeId: String?, connectionLostTime: TimeInterval?, now: TimeInterval) -> Bool {
        guard let resumeId, !resumeId.isEmpty, let connectionLostTime else { return false }

        return now - connectionLostTime < resumeWindow
    }

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
    /// A room join is kept, unless the re-join of the room follows: it fetches a fresh room session itself.
    /// - Parameters:
    ///   - messageType: the `type` of the queued message
    ///   - sessionReplaced: the hello belongs to another session than the one the message was queued for
    ///   - rejoinFollows: the room is joined again after the hello
    static func queuedMessageAction(messageType: String?, sessionReplaced: Bool, rejoinFollows: Bool) -> QueuedMessageAction {
        guard sessionReplaced else { return .send }

        switch messageType {
        case "message", "control":
            return .drop
        case "bye":
            return .dropSilently
        case "room":
            return rejoinFollows ? .drop : .send
        default:
            return .send
        }
    }
}
