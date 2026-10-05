//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Everything that is needed to carry on with an upload of a file to a conversation after the app was
/// suspended, terminated or relaunched, and the rules for moving from one step to the next.
///
/// The type knows nothing about URLSession or UIKit. The uploader tells it what happened and gets back what
/// to do next, which keeps the rule "post exactly once" in one place that can be tested.
///
/// The key of an upload is the reference id of its temporary message in the chat.
struct ChatUploadState: Codable, Equatable {

    enum Step: String, Codable {
        /// The file is being transferred, or waits to be transferred again.
        case uploading
        /// The file is on the server and is not posted into the conversation yet.
        case uploaded
        /// The file is posted, nothing is left to do.
        case announced
        /// Gave up. The local copy is kept so the user can try again.
        case failed
    }

    enum DestinationKind: String, Codable {
        case draftFolder
        case attachmentFolder
    }

    enum Action: Equatable {
        /// Send the file again after the given pause.
        case startTransfer(after: TimeInterval)
        /// Post the file into the conversation after the given pause.
        case announce(after: TimeInterval)
        /// Posted, clean up.
        case finished
        /// Gave up, show the message as not sent.
        case failed
        /// Nothing to do, e.g. because the event is outdated.
        case none
    }

    /// The `talkMetaData` of the message, in a form that can be stored.
    struct Metadata: Codable, Equatable {
        var caption: String?
        var silent = false
        var threadId: Int?
        var replyTo: Int?
        var replyToToken: String?
        var isVoiceMessage = false

        init() {}

        init(_ metadata: ChatFileUploadMetadata) {
            self.caption = metadata.caption
            self.silent = metadata.silent
            self.threadId = metadata.threadId
            self.replyTo = metadata.replyTo
            self.replyToToken = metadata.replyToToken
            self.isVoiceMessage = metadata.isVoiceMessage
        }

        var uploadMetadata: ChatFileUploadMetadata {
            var metadata = ChatFileUploadMetadata()
            metadata.caption = self.caption
            metadata.silent = self.silent
            metadata.threadId = self.threadId
            metadata.replyTo = self.replyTo
            metadata.replyToToken = self.replyToToken
            metadata.isVoiceMessage = self.isVoiceMessage
            return metadata
        }
    }

    /// A temporary message is marked as failed after this long, so an upload is not carried on beyond it either.
    static let maxAge: TimeInterval = 12 * 60 * 60

    /// Reference id of the temporary message. Also the key of the upload.
    var id: String

    var accountId: String
    var roomToken: String

    /// Name of the file in the conversation.
    var fileName: String

    /// Name of the copy of the file in the upload directory. Not the full path, the path of the app
    /// container is not stable.
    var localFileName: String

    /// Where the file is uploaded to. All of these are `nil` until the destination is resolved, which
    /// needs the network and happens when the user sends the file.
    var destinationKind: DestinationKind?

    /// Path in the draft folder, only for `.draftFolder`.
    var draftPath: String?

    /// Path of the file relative to the files root of the user.
    var serverPath: String?

    /// Absolute URL the file is uploaded to.
    var serverURL: String?

    var allowUpdate = false
    var metadata = Metadata()

    var step = Step.uploading

    /// Whether the file reached the server. Stays set when announcing fails, so a retry does not upload again.
    var fileUploaded = false

    /// Errors answered by the server in the current step. Network errors are not counted.
    var serverErrorCount = 0

    /// Failures in a row in the current step, only used for the pause between attempts.
    var failureCount = 0

    var announceAttempts = 0

    /// A request to announce was started and has no result yet. If this is found set on a launch,
    /// the process died during the request and the file might have been announced.
    var announceInFlight = false

    /// An earlier request to announce ended without a definite answer.
    var announceMayHaveSucceeded = false

    /// Time of creation, seconds since 1970.
    var createdAt: TimeInterval

    /// Why the upload failed, for the log.
    var failureReason: String?

    var isDraftFolder: Bool {
        return self.destinationKind == .draftFolder
    }

    var destination: ChatFileUploadDestination? {
        guard let serverPath, let serverURL else { return nil }

        switch self.destinationKind {
        case .draftFolder:
            guard let draftPath else { return nil }
            return .draftFolder(draftPath: draftPath, serverPath: serverPath, serverURL: serverURL)
        case .attachmentFolder:
            return .attachmentFolder(serverPath: serverPath, serverURL: serverURL)
        case .none:
            return nil
        }
    }

    mutating func setDestination(_ destination: ChatFileUploadDestination) {
        switch destination {
        case .draftFolder(let draftPath, let serverPath, let serverURL):
            self.destinationKind = .draftFolder
            self.draftPath = draftPath
            self.serverPath = serverPath
            self.serverURL = serverURL
        case .attachmentFolder(let serverPath, let serverURL):
            self.destinationKind = .attachmentFolder
            self.draftPath = nil
            self.serverPath = serverPath
            self.serverURL = serverURL
        }
    }

    // MARK: - Transitions

    /// The transfer of the file ended.
    ///
    /// - Parameter failure: What went wrong, `nil` when the server accepted the file.
    mutating func transferFinished(failure: ChatFileUploadFailure?, now: TimeInterval) -> Action {
        guard self.step == .uploading else { return .none }

        guard let failure else {
            self.fileUploaded = true
            self.step = .uploaded
            self.serverErrorCount = 0
            self.failureCount = 0
            return .announce(after: 0)
        }

        return self.handle(failure, now: now, next: { .startTransfer(after: $0) })
    }

    /// Call before the request that announces the file is started, and store the state before sending it.
    ///
    /// - Returns: Whether there is something to announce.
    mutating func beginAnnounce() -> Bool {
        guard self.step == .uploaded, self.fileUploaded else { return false }

        self.announceAttempts += 1
        self.announceInFlight = true
        return true
    }

    /// The request that announces the file ended.
    ///
    /// - Parameter failure: What went wrong, `nil` when the file was announced.
    mutating func announceFinished(failure: ChatFileUploadFailure?, now: TimeInterval) -> Action {
        guard self.step == .uploaded else { return .none }

        self.announceInFlight = false

        guard let failure else {
            self.step = .announced
            return .finished
        }

        if ChatFileUploadRetryPolicy.isAlreadyAnnounced(failure, viaDraftFolder: self.isDraftFolder, earlierAttemptMayHaveSucceeded: self.announceMayHaveSucceeded) {
            self.step = .announced
            return .finished
        }

        // Anything but a definite refusal might have been processed by the server
        if ChatFileUploadRetryPolicy.classify(failure) != .permanent {
            self.announceMayHaveSucceeded = true
        }

        return self.handle(failure, now: now, next: { .announce(after: $0) })
    }

    /// To be called on every state read from disk after the process was restarted.
    mutating func recoverAfterRelaunch() {
        if self.announceInFlight {
            self.announceInFlight = false
            self.announceMayHaveSucceeded = true
        }
    }

    /// The upload cannot go on, e.g. because the system cancelled the transfer when the app was killed.
    mutating func fail(reason: String) {
        guard self.step != .announced else { return }

        self.step = .failed
        self.failureReason = reason
    }

    /// The user wants to try again after a failure.
    ///
    /// A file that is on the server is not uploaded again, only announced.
    mutating func prepareRetry(now: TimeInterval) -> Action {
        guard self.step == .failed else { return .none }

        self.serverErrorCount = 0
        self.failureCount = 0
        self.failureReason = nil
        self.createdAt = now

        if self.fileUploaded {
            self.step = .uploaded
            return .announce(after: 0)
        }

        self.step = .uploading
        return .startTransfer(after: 0)
    }

    private mutating func handle(_ failure: ChatFileUploadFailure, now: TimeInterval, next: (TimeInterval) -> Action) -> Action {
        self.failureCount += 1

        if ChatFileUploadRetryPolicy.classify(failure) == .server {
            self.serverErrorCount += 1
        }

        if now - self.createdAt > Self.maxAge {
            self.fail(reason: "expired")
            return .failed
        }

        // The system waits for the network by itself, so there is no ceiling for that here
        let decision = ChatFileUploadRetryPolicy.decision(for: failure, serverErrorCount: self.serverErrorCount, failureCount: self.failureCount)

        guard case .retry(let delay) = decision else {
            self.fail(reason: "http \(failure.httpStatusCode ?? 0), url error \(failure.urlErrorCode ?? 0)")
            return .failed
        }

        return next(delay)
    }
}
