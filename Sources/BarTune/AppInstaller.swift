import AppKit
import Foundation

enum AppInstallError: LocalizedError, Equatable {
    case notInAppBundle
    case managedByHomebrew
    case folderNotWritable(String)
    case mountFailed(String)
    case appNotFoundInImage
    case bundleIdentifierMismatch(expected: String, found: String?)
    case replaceFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInAppBundle:
            return "BarTune isn't running from an app bundle, so it can't replace itself."
        case .managedByHomebrew:
            return "BarTune was installed with Homebrew. Run `brew upgrade --cask bartune` to update it."
        case let .folderNotWritable(path):
            return "BarTune can't write to \(path), so it can't replace itself."
        case let .mountFailed(detail):
            return "Couldn't open the downloaded disk image: \(detail)"
        case .appNotFoundInImage:
            return "The downloaded disk image doesn't contain BarTune.app."
        case let .bundleIdentifierMismatch(expected, found):
            return "The app in the disk image is \(found ?? "unidentified"), not \(expected)."
        case let .replaceFailed(detail):
            return "Couldn't replace BarTune: \(detail)"
        }
    }
}

struct AppInstaller: Sendable {
    typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String]) throws -> Void

    static let caskroomDirectories = [
        URL(fileURLWithPath: "/opt/homebrew/Caskroom/bartune", isDirectory: true),
        URL(fileURLWithPath: "/usr/local/Caskroom/bartune", isDirectory: true),
    ]

    let installedAppURL: URL
    let bundleIdentifier: String
    let caskroomDirectories: [URL]
    let runCommand: CommandRunner

    init(
        installedAppURL: URL,
        bundleIdentifier: String,
        caskroomDirectories: [URL] = AppInstaller.caskroomDirectories,
        runCommand: @escaping CommandRunner = AppInstaller.run
    ) {
        self.installedAppURL = installedAppURL
        self.bundleIdentifier = bundleIdentifier
        self.caskroomDirectories = caskroomDirectories
        self.runCommand = runCommand
    }

    static func current() -> AppInstaller {
        AppInstaller(installedAppURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    }

    /// Why this copy of BarTune can't replace itself, or nil when it can.
    func installBlocker() -> AppInstallError? {
        let fileManager = FileManager.default
        guard installedAppURL.pathExtension == "app", !bundleIdentifier.isEmpty else {
            return .notInAppBundle
        }
        if caskroomDirectories.contains(where: { fileManager.fileExists(atPath: $0.path) }) {
            return .managedByHomebrew
        }
        let folder = installedAppURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: folder.path) else {
            return .folderNotWritable(folder.path)
        }
        return nil
    }

    /// Mounts a verified DMG, then swaps its BarTune.app in for the installed one.
    func install(dmgURL: URL) throws {
        if let blocker = installBlocker() {
            throw blocker
        }

        let fileManager = FileManager.default
        let mountPoint = fileManager.temporaryDirectory
            .appendingPathComponent("BarTune-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        do {
            try runCommand("/usr/bin/hdiutil", [
                "attach", dmgURL.path, "-mountpoint", mountPoint.path,
                "-readonly", "-nobrowse", "-noautoopen",
            ])
        } catch {
            try? fileManager.removeItem(at: mountPoint)
            throw AppInstallError.mountFailed(error.localizedDescription)
        }
        defer {
            try? runCommand("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            try? fileManager.removeItem(at: mountPoint)
        }

        let newAppURL = mountPoint.appendingPathComponent("BarTune.app", isDirectory: true)
        guard fileManager.fileExists(atPath: newAppURL.path) else {
            throw AppInstallError.appNotFoundInImage
        }
        // Read Info.plist directly: Bundle(url:) caches by path and the mount path is fresh anyway.
        let info = NSDictionary(contentsOf: newAppURL.appendingPathComponent("Contents/Info.plist"))
        let foundIdentifier = info?["CFBundleIdentifier"] as? String
        guard foundIdentifier == bundleIdentifier else {
            throw AppInstallError.bundleIdentifierMismatch(expected: bundleIdentifier, found: foundIdentifier)
        }

        try replaceInstalledApp(with: newAppURL)
    }

    /// Copies next to the installed app first so the swap is two renames on one volume.
    func replaceInstalledApp(with sourceAppURL: URL) throws {
        let fileManager = FileManager.default
        let folder = installedAppURL.deletingLastPathComponent()
        let stagedURL = folder.appendingPathComponent(".BarTune-update-\(UUID().uuidString).app", isDirectory: true)
        let backupURL = folder.appendingPathComponent(".BarTune-previous-\(UUID().uuidString).app", isDirectory: true)

        do {
            try runCommand("/usr/bin/ditto", [sourceAppURL.path, stagedURL.path])
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            throw AppInstallError.replaceFailed(error.localizedDescription)
        }

        do {
            try fileManager.moveItem(at: installedAppURL, to: backupURL)
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            throw AppInstallError.replaceFailed(error.localizedDescription)
        }

        do {
            try fileManager.moveItem(at: stagedURL, to: installedAppURL)
        } catch {
            try? fileManager.moveItem(at: backupURL, to: installedAppURL)
            try? fileManager.removeItem(at: stagedURL)
            throw AppInstallError.replaceFailed(error.localizedDescription)
        }

        try? fileManager.removeItem(at: backupURL)
    }

    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(
                domain: "BarTune.AppInstaller",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.isEmpty
                    ? "\((executable as NSString).lastPathComponent) exited with status \(process.terminationStatus)"
                    : message]
            )
        }
    }

    /// Opens the app again once this process has exited, then quits.
    @MainActor
    static func relaunch(appURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "sh", String(ProcessInfo.processInfo.processIdentifier), appURL.path,
        ]
        try process.run()
        NSApp.terminate(nil)
    }
}
