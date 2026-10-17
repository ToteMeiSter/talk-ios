//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// What is known about the kind of a call.
enum CallType: Equatable {
    /// The server did not tell (yet): no call flags capability, no answer, or nobody is in the call
    case unknown
    case voice
    case video
}

/// Decides how a call handles video. Kept free of UIKit/WebRTC calls so it can be unit tested.
enum CallVideoPolicy {

    /// The kind of a call is known only when the call flag of the server says someone is in the call.
    /// A flag without `.inCall` (0) was read before the call began or the caller has already hung up.
    /// - Parameters:
    ///   - callFlag: `callFlag` of a fresh room response from the server, `nil` if there is none
    ///   - hasCallFlagsCapability: whether the server supports call flags
    static func callType(callFlag: CallFlag?, hasCallFlagsCapability: Bool) -> CallType {
        guard hasCallFlagsCapability, let callFlag, callFlag.contains(.inCall) else { return .unknown }

        return callFlag.contains(.withVideo) ? .video : .voice
    }

    /// Whether the call screen of an answered incoming call starts as video call (with the own camera off).
    /// A call that is not known to be a video call starts as voice call. It still receives video, see `receivesRemoteVideo`.
    static func startsAsVideoCall(callKitHasVideo: Bool, serverCallType: CallType) -> Bool {
        return callKitHasVideo || serverCallType == .video
    }

    /// Whether video of the other participants is received. A voice call declines it, except for an answered incoming call:
    /// its kind may be unknown or outdated when it is answered, and the caller may turn the camera on later.
    /// Answering by voice gives up only the own camera.
    static func receivesRemoteVideo(isAudioOnly: Bool, keepsReceivingVideo: Bool) -> Bool {
        return !isAudioOnly || keepsReceivingVideo
    }
}
