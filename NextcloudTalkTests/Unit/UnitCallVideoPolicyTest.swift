//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitCallVideoPolicyTest: XCTestCase {

    // MARK: - callType

    func testVideoCallIsRecognized() {
        let flag: CallFlag = [.inCall, .withAudio, .withVideo]
        XCTAssertEqual(CallVideoPolicy.callType(callFlag: flag, hasCallFlagsCapability: true), .video)
    }

    func testVoiceCallIsRecognized() {
        let flag: CallFlag = [.inCall, .withAudio]
        XCTAssertEqual(CallVideoPolicy.callType(callFlag: flag, hasCallFlagsCapability: true), .voice)
    }

    func testTypeIsUnknownWithoutCapability() {
        let flag: CallFlag = [.inCall, .withAudio, .withVideo]
        XCTAssertEqual(CallVideoPolicy.callType(callFlag: flag, hasCallFlagsCapability: false), .unknown)
    }

    func testTypeIsUnknownWithoutServerAnswer() {
        XCTAssertEqual(CallVideoPolicy.callType(callFlag: nil, hasCallFlagsCapability: true), .unknown)
    }

    func testTypeIsUnknownWhenNobodyIsInTheCall() {
        // A flag of 0 was read before the call began (or after it ended), it says nothing about the kind
        XCTAssertEqual(CallVideoPolicy.callType(callFlag: CallFlag(rawValue: 0), hasCallFlagsCapability: true), .unknown)
    }

    // MARK: - startsAsVideoCall

    func testVideoCallKitCallStartsAsVideoCall() {
        for type in [CallType.unknown, .voice, .video] {
            XCTAssertTrue(CallVideoPolicy.startsAsVideoCall(callKitHasVideo: true, serverCallType: type))
        }
    }

    func testFreshServerAnswerMakesVideoCallOutOfVoiceCallKitCall() {
        // Answered before CallKit knew the type, or the request of CallKit failed
        XCTAssertTrue(CallVideoPolicy.startsAsVideoCall(callKitHasVideo: false, serverCallType: .video))
    }

    func testVoiceAndUnknownCallsStartAsVoiceCall() {
        XCTAssertFalse(CallVideoPolicy.startsAsVideoCall(callKitHasVideo: false, serverCallType: .voice))
        XCTAssertFalse(CallVideoPolicy.startsAsVideoCall(callKitHasVideo: false, serverCallType: .unknown))
    }

    // MARK: - receivesRemoteVideo

    func testVideoCallReceivesVideo() {
        XCTAssertTrue(CallVideoPolicy.receivesRemoteVideo(isAudioOnly: false, keepsReceivingVideo: false))
        XCTAssertTrue(CallVideoPolicy.receivesRemoteVideo(isAudioOnly: false, keepsReceivingVideo: true))
    }

    func testOwnVoiceCallDeclinesVideo() {
        XCTAssertFalse(CallVideoPolicy.receivesRemoteVideo(isAudioOnly: true, keepsReceivingVideo: false))
    }

    func testAnsweredVoiceCallStillReceivesVideo() {
        XCTAssertTrue(CallVideoPolicy.receivesRemoteVideo(isAudioOnly: true, keepsReceivingVideo: true))
    }
}
