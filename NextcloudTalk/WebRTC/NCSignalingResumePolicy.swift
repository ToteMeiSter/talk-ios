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
}
