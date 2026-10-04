//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import UIKit
import XCTest
@testable import NextcloudTalk

final class UnitInAppCameraTest: XCTestCase {

    // MARK: - Flash mode

    func testFlashModeKeepsTheValuesOfTheSystemCamera() throws {
        XCTAssertEqual(InAppCameraFlashMode.off.rawValue, UIImagePickerController.CameraFlashMode.off.rawValue)
        XCTAssertEqual(InAppCameraFlashMode.auto.rawValue, UIImagePickerController.CameraFlashMode.auto.rawValue)
        XCTAssertEqual(InAppCameraFlashMode.on.rawValue, UIImagePickerController.CameraFlashMode.on.rawValue)
    }

    func testFlashModeFromStoredValue() throws {
        // Nothing stored is read as 0 by NCUserDefaults, which is auto
        XCTAssertEqual(InAppCameraFlashMode(storedValue: 0), .auto)
        XCTAssertEqual(InAppCameraFlashMode(storedValue: -1), .off)
        XCTAssertEqual(InAppCameraFlashMode(storedValue: 1), .on)
        XCTAssertEqual(InAppCameraFlashMode(storedValue: 42), .off)
    }

    func testFlashModeCyclesThroughAllModes() throws {
        XCTAssertEqual(InAppCameraFlashMode.off.next, .auto)
        XCTAssertEqual(InAppCameraFlashMode.auto.next, .on)
        XCTAssertEqual(InAppCameraFlashMode.on.next, .off)
    }

    func testFlashModeMapsToCaptureFlashMode() throws {
        XCTAssertEqual(InAppCameraFlashMode.off.captureFlashMode, .off)
        XCTAssertEqual(InAppCameraFlashMode.auto.captureFlashMode, .auto)
        XCTAssertEqual(InAppCameraFlashMode.on.captureFlashMode, .on)
    }

    func testFlashModesHaveDifferentSymbols() throws {
        let symbols = Set(InAppCameraFlashMode.allCases.map { $0.symbolName })
        XCTAssertEqual(symbols.count, InAppCameraFlashMode.allCases.count)
    }

    // MARK: - Files

    func testFileURLsAreInTheGivenDirectoryAndHaveTheExtensionOfTheKind() throws {
        let uuid = UUID()

        let photo = InAppCameraSupport.makeFileURL(for: .photo(isJPEG: true), directory: "/tmp/test", uuid: uuid)
        XCTAssertEqual(photo.path, "/tmp/test/in-app-camera-\(uuid.uuidString).jpg")

        let heic = InAppCameraSupport.makeFileURL(for: .photo(isJPEG: false), directory: "/tmp/test", uuid: uuid)
        XCTAssertEqual(heic.pathExtension, "heic")

        let video = InAppCameraSupport.makeFileURL(for: .video, directory: "/tmp/test", uuid: uuid)
        XCTAssertEqual(video.pathExtension, "mov")
    }

    func testEveryFileURLIsNew() throws {
        let first = InAppCameraSupport.makeFileURL(for: .video)
        let second = InAppCameraSupport.makeFileURL(for: .video)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.path.hasPrefix(NSTemporaryDirectory()) || first.path.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory()).path))
    }

    // MARK: - Duration

    func testFormattedDuration() throws {
        XCTAssertEqual(InAppCameraSupport.formattedDuration(0), "0:00")
        XCTAssertEqual(InAppCameraSupport.formattedDuration(7.9), "0:07")
        XCTAssertEqual(InAppCameraSupport.formattedDuration(60), "1:00")
        XCTAssertEqual(InAppCameraSupport.formattedDuration(754), "12:34")
        XCTAssertEqual(InAppCameraSupport.formattedDuration(3723), "1:02:03")
        XCTAssertEqual(InAppCameraSupport.formattedDuration(-5), "0:00")
    }

    // MARK: - Orientation

    func testCaptureOrientationFollowsTheDevice() throws {
        XCTAssertEqual(InAppCameraSupport.captureOrientation(device: .portrait, interface: .landscapeLeft), .portrait)
        XCTAssertEqual(InAppCameraSupport.captureOrientation(device: .portraitUpsideDown, interface: .portrait), .portraitUpsideDown)
        // The interface is rotated the other way round than the device in landscape
        XCTAssertEqual(InAppCameraSupport.captureOrientation(device: .landscapeLeft, interface: .portrait), .landscapeRight)
        XCTAssertEqual(InAppCameraSupport.captureOrientation(device: .landscapeRight, interface: .portrait), .landscapeLeft)
    }

    func testCaptureOrientationFallsBackToTheInterface() throws {
        XCTAssertEqual(InAppCameraSupport.captureOrientation(device: .faceUp, interface: .landscapeRight), .landscapeRight)
        XCTAssertEqual(InAppCameraSupport.captureOrientation(device: .unknown, interface: .landscapeLeft), .landscapeLeft)
        XCTAssertEqual(InAppCameraSupport.captureOrientation(device: .faceDown, interface: .unknown), .portrait)
    }
}
