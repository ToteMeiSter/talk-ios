/**
 * SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Foundation
import NextcloudKit

/// Uploads files to the server and posts them into a conversation.
@MainActor
enum ChatFileUploader {

    /// Uploads a file to the server and posts it into the conversation it belongs to.
    ///
    /// - Parameter progress: Called with the fraction of the file that has been uploaded so far.
    ///
    /// The destination is determined once and every attempt goes into that same destination. A short loss of the
    /// network is waited for (see `ChatFileUploadRetryPolicy`), only the announcement is repeated after the file
    /// arrived, and an announcement that already went through is not repeated.
    /// - Parameter maxNetworkWait: How long to wait for the network to come back before giving up.
    static func upload(_ upload: ChatFileUpload,
                       maxNetworkWait: TimeInterval = ChatFileUploadRetryPolicy.maxNetworkWait,
                       progress: ((Double) -> Void)? = nil) async throws {
        let destination = try await self.retrying(maxNetworkWait: maxNetworkWait) { try await self.resolveDestination(for: upload) }

        try await self.transfer(upload, to: destination, maxNetworkWait: maxNetworkWait, progress: progress)
    }

    /// Uploads the file into the destination and posts it. Each of both steps is repeated on its own.
    private static func transfer(_ upload: ChatFileUpload,
                                 to destination: ChatFileUploadDestination,
                                 maxNetworkWait: TimeInterval,
                                 progress: ((Double) -> Void)?) async throws {
        try await self.retrying(maxNetworkWait: maxNetworkWait) {
            try await self.put(upload, to: destination, progress: progress, mayCreateAttachmentFolder: true)
        }

        try await self.announceOnce(upload, at: destination, maxNetworkWait: maxNetworkWait)
    }

    /// Uploads several files to the server and posts them into the conversation they belong to.
    ///
    /// All uploads need to be for the same conversation and account: with conversation subfolders
    /// enabled, the draft folder is requested once for all of them.
    ///
    /// - Parameter progress: Called with the index of an upload and the fraction of it that has been
    ///                       uploaded so far.
    /// - Throws: When the draft folder could not be prepared, in which case nothing was uploaded.
    /// - Returns: One result per upload, in the order the uploads were given in.
    static func upload(_ uploads: [ChatFileUpload],
                       maxNetworkWait: TimeInterval = ChatFileUploadRetryPolicy.maxNetworkWait,
                       progress: ((_ index: Int, _ fractionCompleted: Double) -> Void)? = nil) async throws -> [Result<Void, Error>] {
        guard let firstUpload = uploads.first else { return [] }

        // One draft folder is enough for the whole batch, so it is requested before uploading
        // anything: without it there is nowhere to upload to at all.
        var draftFolder: String?

        if firstUpload.room.supportsConversationSubfolders {
            // All uploads of a batch share the folder, so they share the permission of it as well
            draftFolder = try await self.retrying(maxNetworkWait: maxNetworkWait) {
                try await self.probeDraftFolder(for: firstUpload.room,
                                                account: firstUpload.account,
                                                fileNames: uploads.map { $0.fileName },
                                                allowUpdate: firstUpload.allowUpdate)
            }
        }

        return await withTaskGroup(of: (index: Int, result: Result<Void, Error>).self) { group in
            for (index, upload) in uploads.enumerated() {
                group.addTask {
                    do {
                        let destination: ChatFileUploadDestination

                        if let draftFolder {
                            destination = try await self.draftFolderDestination(in: draftFolder, for: upload)
                        } else {
                            destination = try await self.retrying(maxNetworkWait: maxNetworkWait) { try await self.resolveDestination(for: upload) }
                        }

                        try await self.transfer(upload, to: destination, maxNetworkWait: maxNetworkWait, progress: { progress?(index, $0) })

                        return (index, .success(()))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            var results = [Result<Void, Error>](repeating: .success(()), count: uploads.count)

            for await taskResult in group {
                results[taskResult.index] = taskResult.result
            }

            return results
        }
    }

    // MARK: - Retries

    /// Runs the operation again after a pause as long as the retry policy says so.
    private static func retrying<T>(maxNetworkWait: TimeInterval = ChatFileUploadRetryPolicy.maxNetworkWait,
                                    _ operation: () async throws -> T) async throws -> T {
        var serverErrorCount = 0
        var failureCount = 0
        var networkWaitStart: Date?

        while true {
            do {
                return try await operation()
            } catch {
                let failure = self.failure(for: error)

                failureCount += 1

                if ChatFileUploadRetryPolicy.classify(failure) == .server {
                    serverErrorCount += 1
                }

                if ChatFileUploadRetryPolicy.classify(failure) == .network, networkWaitStart == nil {
                    networkWaitStart = Date()
                }

                let networkWait = networkWaitStart.map { Date().timeIntervalSince($0) }

                guard case .retry(let delay) = ChatFileUploadRetryPolicy.decision(for: failure,
                                                                                 serverErrorCount: serverErrorCount,
                                                                                 failureCount: failureCount,
                                                                                 networkWait: networkWait,
                                                                                 maxNetworkWait: maxNetworkWait)
                else { throw error }

                NCLog.log("Upload request failed, trying again in \(delay) seconds. Error: \(error.localizedDescription)")

                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Reduces the errors of this file to what the retry policy looks at.
    static func failure(for error: Error) -> ChatFileUploadFailure {
        switch error {
        case ChatFileUploadError.uploadFailed(let errorCode, _):
            if errorCode >= 100 {
                return ChatFileUploadFailure(httpStatusCode: errorCode)
            }

            return ChatFileUploadFailure(urlErrorCode: errorCode)
        case ChatFileUploadError.quotaExceeded:
            return ChatFileUploadFailure(httpStatusCode: 507)
        case ChatFileUploadError.tooManyRequests:
            return ChatFileUploadFailure(httpStatusCode: 429)
        case ChatFileUploadError.destinationUnavailable(let underlyingError):
            guard let underlyingError else { return ChatFileUploadFailure() }
            return ChatFileUploadFailure(error: underlyingError)
        case ChatFileUploadError.shareFailed(let underlyingError):
            return ChatFileUploadFailure(error: underlyingError)
        default:
            return ChatFileUploadFailure(error: error)
        }
    }

    /// Posts the file into the conversation, repeating the request when it got no answer.
    ///
    /// A request without an answer might have gone through, so the next one for a file in the draft folder is
    /// allowed to find it gone: that means it has been posted already, see `isAlreadyAnnounced`.
    private static func announceOnce(_ upload: ChatFileUpload, at destination: ChatFileUploadDestination, maxNetworkWait: TimeInterval) async throws {
        var earlierAttemptMayHaveSucceeded = false

        var isDraftFolder = false
        if case .draftFolder = destination { isDraftFolder = true }

        // swiftlint:disable:next redundant_void_return
        try await self.retrying(maxNetworkWait: maxNetworkWait) { () async throws -> Void in
            do {
                try await self.announce(upload, at: destination)
            } catch {
                let failure = self.failure(for: error)

                if ChatFileUploadRetryPolicy.isAlreadyAnnounced(failure, viaDraftFolder: isDraftFolder, earlierAttemptMayHaveSucceeded: earlierAttemptMayHaveSucceeded) {
                    NCLog.log("Announcing \(upload.fileName) was done by an earlier attempt already. Answer: \(ChatFileUploadRetryPolicy.responseBody(of: error) ?? "none")")
                    return
                }

                // Without a definite answer the request might have been processed
                if ChatFileUploadRetryPolicy.classify(failure) != .permanent {
                    earlierAttemptMayHaveSucceeded = true
                }

                throw error
            }
        }
    }

    // MARK: - Destination

    /// Determines where to upload the file to, which is the only place that knows about the two
    /// different ways of getting a file into a conversation.
    static func resolveDestination(for upload: ChatFileUpload) async throws -> ChatFileUploadDestination {
        return try await self.resolveDestination(in: upload.room, account: upload.account, fileName: upload.fileName, allowUpdate: upload.allowUpdate)
    }

    /// Like `resolveDestination(for:)`, waiting for the network as long as the retry policy says so.
    static func resolveDestinationWithRetries(in room: NCRoom, account: TalkAccount, fileName: String, allowUpdate: Bool) async throws -> ChatFileUploadDestination {
        return try await self.retrying {
            let destination = try await self.resolveDestination(in: room, account: account, fileName: fileName, allowUpdate: allowUpdate)

            // Nobody is there to create the folder when the transfer runs without the app, so it has to exist
            // before the transfer is handed over to the system
            if case .attachmentFolder = destination {
                try await self.ensureAttachmentFolder(for: account)
            }

            return destination
        }
    }

    /// Makes sure the attachment folder of the user exists, and creates it when it does not.
    static func ensureAttachmentFolder(for account: TalkAccount) async throws {
        let statusCode: Int = await withCheckedContinuation { continuation in
            NCAPIController.sharedInstance().checkOrCreateAttachmentFolder(forAccount: account) { created, statusCode in
                // The callback reports 0 for a folder that is there already, and false for "not created". Any other
                // code is an error, including the one for an account without a folder URL.
                continuation.resume(returning: created ? 0 : statusCode)
            }
        }

        guard statusCode == 0 else {
            throw ChatFileUploadError.uploadFailed(errorCode: statusCode, errorDescription: "Could not check or create the attachment folder")
        }
    }

    static func resolveDestination(in room: NCRoom, account: TalkAccount, fileName: String, allowUpdate: Bool) async throws -> ChatFileUploadDestination {
        guard room.supportsConversationSubfolders else {
            do {
                let uniqueName = try await NCAPIController.sharedInstance().uniqueNameForFileUpload(withName: fileName, isOriginalName: true, forAccount: account)

                return .attachmentFolder(serverPath: uniqueName.fileServerPath, serverURL: uniqueName.fileServerURL)
            } catch {
                throw ChatFileUploadError.destinationUnavailable(underlyingError: error)
            }
        }

        let draftFolder = try await self.probeDraftFolder(for: room,
                                                          account: account,
                                                          fileNames: [fileName],
                                                          allowUpdate: allowUpdate)

        return try await self.draftFolderDestination(in: draftFolder, fileName: fileName, account: account)
    }

    /// Makes sure the conversation subfolder exists and returns the draft folder to upload into.
    private static func probeDraftFolder(for room: NCRoom, account: TalkAccount, fileNames: [String], allowUpdate: Bool) async throws -> String {
        do {
            return try await NCAPIController.sharedInstance().probeConversationAttachmentFolder(inRoom: room.token, withFileNames: fileNames, allowUpdate: allowUpdate, forAccount: account).folder
        } catch {
            throw ChatFileUploadError.destinationUnavailable(underlyingError: error)
        }
    }

    private static func draftFolderDestination(in draftFolder: String, for upload: ChatFileUpload) async throws -> ChatFileUploadDestination {
        return try await self.draftFolderDestination(in: draftFolder, fileName: upload.fileName, account: upload.account)
    }

    private static func draftFolderDestination(in draftFolder: String, fileName: String, account: TalkAccount) async throws -> ChatFileUploadDestination {
        // The file is uploaded under a temporary name, it only gets its final name when the
        // attachment endpoint moves it out of the draft folder.
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension
        let temporaryName = UUID().uuidString + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
        let draftPath = "\(draftFolder)/\(temporaryName)"
        let serverPath = "/\(draftPath)"

        guard let serverURL = NCAPIController.sharedInstance().serverFileURL(forfilePath: serverPath, forAccount: account)
        else { throw ChatFileUploadError.destinationUnavailable(underlyingError: nil) }

        return .draftFolder(draftPath: draftPath, serverPath: serverPath, serverURL: serverURL)
    }

    // MARK: - Upload

    private static func put(_ upload: ChatFileUpload,
                            to destination: ChatFileUploadDestination,
                            progress: ((Double) -> Void)?,
                            mayCreateAttachmentFolder: Bool) async throws {
        let apiController = NCAPIController.sharedInstance()
        apiController.setupNCCommunication(forAccount: upload.account)

        do {
            try await self.putFile(upload, to: destination, progress: progress)
        } catch let error as ChatFileUploadError {
            // A missing folder can only happen in the attachment folder flow, as the draft folder
            // is created by the probe request while resolving the destination.
            guard mayCreateAttachmentFolder,
                  case .attachmentFolder = destination,
                  case .uploadFailed(let errorCode, _) = error,
                  errorCode == 404 || errorCode == 409
            else { throw error }

            guard await apiController.checkOrCreateAttachmentFolder(forAccount: upload.account)
            else { throw ChatFileUploadError.attachmentFolderUnavailable }

            // Retry into the same destination, the name we picked before is still free
            try await self.put(upload, to: destination, progress: progress, mayCreateAttachmentFolder: false)
        }
    }

    private static func putFile(_ upload: ChatFileUpload,
                                to destination: ChatFileUploadDestination,
                                progress: ((Double) -> Void)?) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            NextcloudKit.shared.upload(serverUrlFileName: destination.serverURL,
                                       fileNameLocalPath: upload.localPath,
                                       progressHandler: { uploadProgress in
                progress?(uploadProgress.fractionCompleted)
            }, completionHandler: { _, _, _, _, _, _, error in
                switch error.errorCode {
                case 0:
                    continuation.resume()
                case 507:
                    continuation.resume(throwing: ChatFileUploadError.quotaExceeded)
                case 429:
                    continuation.resume(throwing: ChatFileUploadError.tooManyRequests)
                default:
                    continuation.resume(throwing: ChatFileUploadError.uploadFailed(errorCode: error.errorCode, errorDescription: error.errorDescription))
                }
            })
        }
    }

    // MARK: - Announce

    /// Posts the already uploaded file as a message into the conversation.
    private static func announce(_ upload: ChatFileUpload, at destination: ChatFileUploadDestination) async throws {
        try await self.announce(inRoom: upload.room.token,
                                account: upload.account,
                                fileName: upload.fileName,
                                referenceId: upload.referenceId,
                                metadata: upload.metadata,
                                allowUpdate: upload.allowUpdate,
                                at: destination)
    }

    // swiftlint:disable:next function_parameter_count
    static func announce(inRoom token: String,
                         account: TalkAccount,
                         fileName: String,
                         referenceId: String?,
                         metadata: ChatFileUploadMetadata,
                         allowUpdate: Bool,
                         at destination: ChatFileUploadDestination) async throws {
        let apiController = NCAPIController.sharedInstance()
        let talkMetaData = metadata.asDictionary()

        do {
            switch destination {
            case .draftFolder(let draftPath, _, _):
                try await apiController.postConversationAttachment(inRoom: token,
                                                                   filePath: draftPath,
                                                                   fileName: fileName,
                                                                   referenceId: referenceId,
                                                                   talkMetaData: talkMetaData,
                                                                   allowUpdate: allowUpdate,
                                                                   forAccount: account)
            case .attachmentFolder(let serverPath, _):
                // The files sharing API has no way to grant update permissions, which is why the
                // option is not offered at all without conversation subfolders.
                try await apiController.shareFileOrFolder(forAccount: account,
                                                          atPath: serverPath,
                                                          toRoom: token,
                                                          withTalkMetaData: talkMetaData,
                                                          withReferenceId: referenceId)
            }
        } catch {
            throw ChatFileUploadError.shareFailed(underlyingError: error)
        }
    }
}
