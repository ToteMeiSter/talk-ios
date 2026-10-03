//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import UIKit

/// What the record button next to an empty input field records
enum RecordButtonMode: String {
    case voice
    case video
}

/// Video messages: the record button records a short video instead of a voice message when it is in
/// video mode. The gestures are the ones of voice messages, see `handleLongPressInVoiceMessageRecordButton`.
extension BaseChatViewController {

    // MARK: - Availability

    var isVoiceMessageRecordingAvailable: Bool {
        return NCDatabaseManager.sharedInstance().roomHasTalkCapability(.voiceMessage, for: self.room) && !self.room.isFederated
    }

    /// Videos are sent as files, which is not possible in federated conversations (just like the attachment menu),
    /// and the camera is in use during a call.
    var isVideoMessageRecordingAvailable: Bool {
        return !self.room.isFederated
            && UIImagePickerController.isSourceTypeAvailable(.camera)
            && NCRoomsManager.shared.callViewController == nil
    }

    /// The mode that is used for recording, as the chosen mode might not be available in this conversation
    var effectiveRecordMode: RecordButtonMode {
        switch (self.isVoiceMessageRecordingAvailable, self.isVideoMessageRecordingAvailable) {
        case (true, false):
            return .voice
        case (false, true):
            return .video
        default:
            return self.recordButtonMode
        }
    }

    /// With scheduled messages the button is a clock that opens them, so it can not switch the mode
    private var canSwitchRecordButtonMode: Bool {
        return self.isVoiceMessageRecordingAvailable && self.isVideoMessageRecordingAvailable && !self.room.hasScheduledMessages
    }

    // MARK: - Mode switch

    func handleTapOnRecordButton() {
        if self.canSwitchRecordButtonMode {
            self.recordButtonMode = self.effectiveRecordMode == .voice ? .video : .voice
            self.showVoiceMessageRecordButton()
        }

        self.showRecordButtonHint()
    }

    private func showRecordButtonHint() {
        let hint: String

        if self.canSwitchRecordButtonMode {
            if self.effectiveRecordMode == .video {
                hint = NSLocalizedString("Tap and hold to record a video. Tap to switch to voice messages.", comment: "")
            } else {
                hint = NSLocalizedString("Tap and hold to record a voice message. Tap to switch to video messages.", comment: "")
            }
        } else if self.effectiveRecordMode == .video {
            hint = NSLocalizedString("Tap and hold to record a video, release the button to send it.", comment: "")
        } else {
            self.showVoiceMessageRecordHint()
            return
        }

        let toastPosition = CGPoint(x: self.textInputbar.center.x, y: self.textInputbar.center.y - self.textInputbar.frame.size.height)
        self.view.makeToast(hint, duration: 3, point: toastPosition, title: nil, image: nil, completion: nil)
    }

    // MARK: - Gesture

    /// Starts recording in the current mode when the record button is pressed and held
    func startRecordingForGesture() {
        // The mode is fixed for the whole gesture
        self.isVideoGestureActive = self.effectiveRecordMode == .video

        if self.isVideoGestureActive {
            self.checkPermissionsAndRecordVideoMessage()
        } else {
            self.checkPermissionAndRecordVoiceMessage()
        }

        self.setInputbarImage(UIImage(systemName: self.isVideoGestureActive ? "video" : "mic"), for: self.rightButton)
    }

    /// Stops what `startRecordingForGesture` started. A voice message is handled by its recorder, which
    /// sends it when it is finished, so `send` only applies to videos.
    func stopRecordingForGesture(send: Bool) {
        if self.isVideoGestureActive {
            self.finishVideoMessageRecording(send: send)
        } else {
            self.stopRecordingVoiceMessage()
        }
    }

    // MARK: - Permissions

    func checkPermissionsAndRecordVideoMessage() {
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        if cameraStatus == .authorized, microphoneStatus == .authorized {
            self.startRecordingVideoMessage()
            return
        }

        if cameraStatus == .denied || cameraStatus == .restricted {
            self.presentCaptureAccessDeniedAlert(title: NSLocalizedString("Could not access camera", comment: ""),
                                                 message: NSLocalizedString("Camera access is not allowed. Check your settings.", comment: ""))
            return
        }

        if microphoneStatus == .denied || microphoneStatus == .restricted {
            self.presentCaptureAccessDeniedAlert(title: NSLocalizedString("Could not access microphone", comment: ""),
                                                 message: NSLocalizedString("Microphone access is not allowed. Check your settings.", comment: ""))
            return
        }

        // Like for voice messages, the recording does not start while the system asks for the permission
        Self.requestCaptureAccessIfNeeded(for: .video) {
            Self.requestCaptureAccessIfNeeded(for: .audio) {}
        }
    }

    private static func requestCaptureAccessIfNeeded(for mediaType: AVMediaType, completion: @escaping () -> Void) {
        guard AVCaptureDevice.authorizationStatus(for: mediaType) == .notDetermined else {
            completion()
            return
        }

        AVCaptureDevice.requestAccess(for: mediaType) { granted in
            NSLog("Capture permission for %@ granted: %@", mediaType.rawValue, granted ? "YES" : "NO")
            completion()
        }
    }

    private func presentCaptureAccessDeniedAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        NCUserInterfaceController.sharedInstance().presentAlertViewController(alert)
    }

    // MARK: - Recording

    private func startRecordingVideoMessage() {
        // Playing a voice message and recording do not go together
        self.pauseVoiceMessagePlayer()

        let recorder = VideoMessageRecorder()
        recorder.onFailure = { [weak self, weak recorder] in
            guard let self, let recorder, self.videoMessageRecorder === recorder else { return }

            NCLog.log("Video message recording failed or was interrupted")
            self.finishVideoMessageRecording(send: false)
        }

        self.videoMessageRecorder = recorder

        self.showVoiceMessageRecordingView(iconName: "video.fill")
        self.showVideoMessagePreview(for: recorder)

        recorder.start { [weak self, weak recorder] success in
            guard let self, let recorder, self.videoMessageRecorder === recorder else { return }

            guard success else {
                NCLog.log("Could not start recording a video message")
                self.finishVideoMessageRecording(send: false)
                return
            }

            // The recording stops and is sent when the maximum duration is reached
            let timer = Timer(timeInterval: VideoMessageRecorder.maxDuration, repeats: false) { [weak self] _ in
                self?.finishVideoMessageRecording(send: true)
            }

            RunLoop.main.add(timer, forMode: .common)
            self.videoMessageLimitTimer = timer
        }
    }

    /// Stops recording, and sends the video unless it is cancelled or shorter than a second
    func finishVideoMessageRecording(send: Bool) {
        guard let recorder = self.videoMessageRecorder else { return }

        self.videoMessageRecorder = nil
        self.videoMessageLimitTimer?.invalidate()
        self.videoMessageLimitTimer = nil

        let isLongEnough = recorder.elapsed >= 1

        self.videoMessagePreviewView?.removeFromSuperview()
        self.videoMessagePreviewView = nil

        self.hideVoiceMessageRecordingView()
        self.handleCollapseVoiceRecording()
        self.resetVoiceRecordingLockButton()
        self.shouldLockInterfaceOrientation(lock: false)

        recorder.stop(keepFile: send && isLongEnough) { [weak self] fileURL in
            guard let fileURL else { return }

            self?.shareVideoMessage(fileURL: fileURL)
        }
    }

    private func showVideoMessagePreview(for recorder: VideoMessageRecorder) {
        let previewView = VideoMessagePreviewView(session: recorder.session, showsSwitchCameraButton: recorder.canSwitchCamera)
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.onSwitchCamera = { [weak recorder] in
            recorder?.switchCamera()
        }

        self.view.addSubview(previewView)
        self.videoMessagePreviewView = previewView

        NSLayoutConstraint.activate([
            previewView.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
            previewView.heightAnchor.constraint(equalTo: self.view.heightAnchor, multiplier: 0.42),
            previewView.widthAnchor.constraint(equalTo: previewView.heightAnchor, multiplier: 9.0 / 16.0),
            // Leaves room for the buttons of a locked recording
            previewView.bottomAnchor.constraint(equalTo: self.textInputbar.topAnchor, constant: -96)
        ])
    }

    // MARK: - Sending

    /// Uploads the video like a voice message, without a confirmation, but as an ordinary file: it has no
    /// message type, so everyone sees a regular video.
    private func shareVideoMessage(fileURL: URL) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let dateString = dateFormatter.string(from: Date())

        // Replace chars that are not allowed on the filesystem
        let notAllowedCharSet = CharacterSet(charactersIn: "\\/:%")
        var roomString = self.room.displayName.components(separatedBy: notAllowedCharSet).joined(separator: " ")

        // Replace multiple spaces with 1
        if let regex = try? NSRegularExpression(pattern: "  +") {
            roomString = regex.stringByReplacingMatches(in: roomString, range: .init(location: 0, length: roomString.count), withTemplate: " ")
        }

        var videoFileName = "Talk video from \(dateString) (\(roomString))"

        // Trim the file name if too long
        if videoFileName.count > 146 {
            videoFileName = String(videoFileName.prefix(146))
        }

        videoFileName += ".mp4"

        let chatFileController = NCChatFileController(account: self.account)
        let destinationFilePath = URL(fileURLWithPath: chatFileController.tempDirectoryPath).appendingPathComponent(videoFileName).path

        guard chatFileController.moveFileToTemporaryDirectory(fromSourcePath: fileURL.path, destinationPath: destinationFilePath) else {
            NCLog.log("Failed to move video message to temporary directory")
            return
        }

        var replyToMessage: NCChatMessage?
        if let replyMessageView, replyMessageView.isVisible {
            replyToMessage = replyMessageView.message
            replyMessageView.dismiss()
        }

        var metaData = ChatFileUploadMetadata()
        metaData.replyTo = replyToMessage?.messageId
        metaData.threadId = self.thread?.threadId

        // A parent living in another conversation means this is a private reply
        if let replyToToken = replyToMessage?.token, replyToToken != self.room.token {
            metaData.replyToToken = replyToToken
        }

        var upload = ChatFileUpload(localPath: destinationFilePath,
                                    fileName: videoFileName,
                                    room: self.room,
                                    account: self.account)
        upload.metadata = metaData

        self.upload(upload)
    }
}
