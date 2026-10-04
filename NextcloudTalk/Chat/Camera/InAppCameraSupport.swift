//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import Foundation
import UIKit

/// The flash mode of the in-app camera. The raw values are the ones of `UIImagePickerController.CameraFlashMode`,
/// so the mode that is stored in `NCUserDefaults` is shared with the camera of the system.
enum InAppCameraFlashMode: Int, CaseIterable {
    case off = -1
    case auto = 0
    case on = 1

    /// The stored value, a value that is not known switches the flash off like the system camera does here
    init(storedValue: Int) {
        self = InAppCameraFlashMode(rawValue: storedValue) ?? .off
    }

    /// The mode a tap on the flash button switches to
    var next: InAppCameraFlashMode {
        switch self {
        case .off: return .auto
        case .auto: return .on
        case .on: return .off
        }
    }

    var captureFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: return .off
        case .auto: return .auto
        case .on: return .on
        }
    }

    var symbolName: String {
        switch self {
        case .off: return "bolt.slash.fill"
        case .auto: return "bolt.badge.a.fill"
        case .on: return "bolt.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .off: return NSLocalizedString("Flash off", comment: "")
        case .auto: return NSLocalizedString("Flash auto", comment: "")
        case .on: return NSLocalizedString("Flash on", comment: "")
        }
    }
}

enum InAppCameraMediaKind {
    case photo(isJPEG: Bool)
    case video

    var fileExtension: String {
        switch self {
        case .photo(let isJPEG): return isJPEG ? "jpg" : "heic"
        case .video: return "mov"
        }
    }
}

enum InAppCameraSupport {

    /// A recording ends by itself after this time
    static let maxVideoDuration: TimeInterval = 300

    /// A new file in the temporary directory. Every capture has a file of its own, the owner of the file is
    /// whoever receives it from the camera.
    static func makeFileURL(for kind: InAppCameraMediaKind, directory: String = NSTemporaryDirectory(), uuid: UUID = UUID()) -> URL {
        return URL(fileURLWithPath: directory)
            .appendingPathComponent("in-app-camera-\(uuid.uuidString).\(kind.fileExtension)")
    }

    /// The orientation to capture in. It is the one the device is held in, so a photo is upright even when the
    /// rotation of the interface is locked. Without a usable device orientation (flat on a table) it is the one
    /// of the interface.
    static func captureOrientation(device: UIDeviceOrientation, interface: UIInterfaceOrientation) -> UIInterfaceOrientation {
        switch device {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        // The device and the interface are rotated the other way round in landscape
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return interface == .unknown ? .portrait : interface
        }
    }

    /// The time of a recording like "0:07" or "12:34", or "1:02:03" after an hour
    static func formattedDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }
}
