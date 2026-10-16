//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

@objcMembers public class NCLog: NSObject {

    private static let backgroundLogQueue = DispatchQueue(label: "\(bundleIdentifier).backgroundLogQueue", qos: .background)

    private static let logLineDateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "y-MM-dd H:mm:ss.SSSS"

        return dateFormatter
    }()

    private static let fileNameDateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        return dateFormatter
    }()

    // Logs live in the app group container, so the app can show the logs of its extensions.
    // Falls back to the documents directory of the current process if the container is not available.
    private static var logfilePath: URL? = {
        let fileManager = FileManager.default

        let baseDir = fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first

        guard let baseDir else { return nil }

        let logDir = baseDir.appendingPathComponent("logs")
        let logPath = logDir.path

        // Allow writing to files while the app is in the background
        if !fileManager.fileExists(atPath: logPath) {
            try? fileManager.createDirectory(atPath: logPath, withIntermediateDirectories: true, attributes: [FileAttributeKey.protectionKey: FileProtectionType.none])
        }

        return logDir
    }()

    // Before logs moved to the app group, the app wrote to its documents directory. Those files are still read and cleaned up.
    private static var legacyLogfilePath: URL? = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("logs")
    }()

    // Empty for the app, "ShareExtension" etc. for an app extension, so two processes never write to the same file
    private static let processName: String = {
        guard Bundle.main.bundleURL.pathExtension == "appex" else { return "" }
        return Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    }()

    static func logfileName(dateString: String, processName: String) -> String {
        let suffix = processName.isEmpty ? "" : "-\(processName)"
        return "debug-\(dateString)\(suffix).log"
    }

    private static func isLogfile(_ name: String) -> Bool {
        return name.hasPrefix("debug-") && name.hasSuffix(".log")
    }

    private static var allLogDirectories: [URL] {
        return [logfilePath, legacyLogfilePath].compactMap { $0 }.reduce(into: [URL]()) { result, url in
            if !result.contains(url) { result.append(url) }
        }
    }

    public static func log(_ message: String) {
        guard let logfilePath else { return }

        // Determine the queue here, as otherwise it will be always the backgroundQueue
        let currentQueueName = Thread.current.queueName

        backgroundLogQueue.async {
            do {
                let now = Date()

                var logMessage = "\(logLineDateFormatter.string(from: now)) "
                logMessage += "(\(currentQueueName)): \(message)\n"

                let dateString = fileNameDateFormatter.string(from: now)
                let logFileName = logfileName(dateString: dateString, processName: processName)
                let fullPath = logfilePath.appendingPathComponent(logFileName).path

                if let fileHandle = FileHandle(forWritingAtPath: fullPath) {
                    fileHandle.seekToEndOfFile()
                    // UTF-8 will never be nil
                    try fileHandle.write(contentsOf: logMessage.data(using: .utf8)!)
                    try fileHandle.close()
                } else {
                    if !FileManager.default.createFile(atPath: fullPath, contents: logMessage.data(using: .utf8)!) {
                        NSLog("Exception in NCLog.log: could not create logfile %@", fullPath)
                    }
                }

                NSLog("%@", logMessage)
            } catch {
                NSLog("Exception in NCLog.log: %@", error.localizedDescription)
                NSLog("Message: %@", message)
            }
        }
    }

    // Logs are exported by the user, so lines must not carry file names, paths or accounts.
    // The description of a file error can contain them, therefore log domain and code only.
    public static func errorCode(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }

    // Describes a file without its name
    public static func fileTraits(fileName: String) -> String {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        return fileExtension.isEmpty ? "file without extension" : "file with extension \(fileExtension)"
    }

    public static func getLogfiles() -> [URL] {
        return logfiles(in: allLogDirectories)
    }

    // Sort descending by file name so the most recent logfile is listed first
    static func logfiles(in directories: [URL]) -> [URL] {
        let fileManager = FileManager.default

        return directories
            .flatMap { (try? fileManager.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { isLogfile($0.lastPathComponent) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    public static func removeOldLogfiles() {
        let fileManager = FileManager.default

        var dayComponent = DateComponents()
        dayComponent.day = -10

        guard let thresholdDate = Calendar.current.date(byAdding: dayComponent, to: Date())
        else { return }

        for logDir in allLogDirectories {
            guard let enumerator = fileManager.enumerator(atPath: logDir.path) else { continue }

            while let file = enumerator.nextObject() as? String {
                let filePath = logDir.appendingPathComponent(file).path

                guard let creationDate = (try? fileManager.attributesOfItem(atPath: filePath))?[.creationDate] as? Date
                else { continue }

                if creationDate.compare(thresholdDate) == .orderedAscending && isLogfile(file) {
                    NSLog("Deleting old logfile %@", filePath)
                    try? fileManager.removeItem(atPath: filePath)
                }
            }
        }
    }
}
