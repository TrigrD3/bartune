@testable import BarTune
import Foundation
import XCTest

final class AppInstallerTests: XCTestCase {
    private let bundleID = "com.bartune.tests.app"

    func testInstallReplacesInstalledAppFromDiskImage() throws {
        let root = makeInstallerTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let installed = try makeTestAppBundle(in: applications, identifier: bundleID, version: "0.5.2")
        let dmg = try makeTestDiskImage(in: root, identifier: bundleID, version: "0.5.15")

        let installer = AppInstaller(installedAppURL: installed, bundleIdentifier: bundleID, caskroomDirectories: [])
        XCTAssertNil(installer.installBlocker())
        try installer.install(dmgURL: dmg)

        XCTAssertEqual(installedTestAppVersion(at: installed), "0.5.15")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: applications.path),
            ["BarTune.app"],
            "The staged copy and the backup of the old app must not be left behind"
        )
    }

    func testInstallRejectsDiskImageWithAnotherBundleIdentifier() throws {
        let root = makeInstallerTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let installed = try makeTestAppBundle(in: applications, identifier: bundleID, version: "0.5.2")
        let dmg = try makeTestDiskImage(in: root, identifier: "com.example.Other", version: "9.0.0")

        let installer = AppInstaller(installedAppURL: installed, bundleIdentifier: bundleID, caskroomDirectories: [])
        XCTAssertThrowsError(try installer.install(dmgURL: dmg)) { error in
            XCTAssertEqual(
                error as? AppInstallError,
                .bundleIdentifierMismatch(expected: bundleID, found: "com.example.Other")
            )
        }
        XCTAssertEqual(installedTestAppVersion(at: installed), "0.5.2")
    }

    func testFailedCopyLeavesInstalledAppUntouched() throws {
        let root = makeInstallerTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let installed = try makeTestAppBundle(in: applications, identifier: bundleID, version: "0.5.2")
        let source = try makeTestAppBundle(in: root.appendingPathComponent("new"), identifier: bundleID, version: "0.5.15")

        let installer = AppInstaller(
            installedAppURL: installed,
            bundleIdentifier: bundleID,
            caskroomDirectories: [],
            runCommand: { _, arguments in
                // Leave a partial copy behind, as an interrupted ditto would.
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: arguments[1]),
                    withIntermediateDirectories: true
                )
                throw CocoaError(.fileWriteOutOfSpace)
            }
        )
        XCTAssertThrowsError(try installer.replaceInstalledApp(with: source))
        XCTAssertEqual(installedTestAppVersion(at: installed), "0.5.2")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["BarTune.app"])
    }

    func testInstallBlockers() throws {
        let root = makeInstallerTestDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("Locked").path)
            try? FileManager.default.removeItem(at: root)
        }

        let notBundle = AppInstaller(
            installedAppURL: root.appendingPathComponent("debug", isDirectory: true),
            bundleIdentifier: bundleID,
            caskroomDirectories: []
        )
        XCTAssertEqual(notBundle.installBlocker(), .notInAppBundle)

        let caskroom = root.appendingPathComponent("Caskroom/bartune", isDirectory: true)
        try FileManager.default.createDirectory(at: caskroom, withIntermediateDirectories: true)
        let installed = try makeTestAppBundle(in: root.appendingPathComponent("Applications"), identifier: bundleID, version: "0.5.2")
        let homebrew = AppInstaller(installedAppURL: installed, bundleIdentifier: bundleID, caskroomDirectories: [caskroom])
        XCTAssertEqual(homebrew.installBlocker(), .managedByHomebrew)

        let locked = root.appendingPathComponent("Locked", isDirectory: true)
        let lockedApp = try makeTestAppBundle(in: locked, identifier: bundleID, version: "0.5.2")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let readOnly = AppInstaller(installedAppURL: lockedApp, bundleIdentifier: bundleID, caskroomDirectories: [])
        XCTAssertEqual(readOnly.installBlocker(), .folderNotWritable(locked.path))
    }
}

func makeInstallerTestDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("BarTuneInstallerTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
func makeTestAppBundle(in folder: URL, identifier: String, version: String) throws -> URL {
    let app = folder.appendingPathComponent("BarTune.app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(
        at: contents.appendingPathComponent("MacOS", isDirectory: true),
        withIntermediateDirectories: true
    )
    let info: NSDictionary = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version]
    try info.write(to: contents.appendingPathComponent("Info.plist"))
    try Data("#!/bin/sh\n".utf8).write(to: contents.appendingPathComponent("MacOS/BarTune"))
    return app
}

/// Builds a DMG laid out like build.sh --dmg: BarTune.app plus an Applications symlink.
func makeTestDiskImage(in root: URL, identifier: String, version: String) throws -> URL {
    let staging = root.appendingPathComponent("dmg-staging-\(UUID().uuidString)", isDirectory: true)
    try makeTestAppBundle(in: staging, identifier: identifier, version: version)
    try FileManager.default.createSymbolicLink(
        at: staging.appendingPathComponent("Applications"),
        withDestinationURL: URL(fileURLWithPath: "/Applications")
    )
    let dmg = root.appendingPathComponent("BarTune-\(version).dmg")
    try AppInstaller.run("/usr/bin/hdiutil", [
        "create", "-quiet", "-volname", "BarTune", "-srcfolder", staging.path, "-ov", "-format", "UDZO", dmg.path,
    ])
    try FileManager.default.removeItem(at: staging)
    return dmg
}

func installedTestAppVersion(at app: URL) -> String? {
    NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
}
