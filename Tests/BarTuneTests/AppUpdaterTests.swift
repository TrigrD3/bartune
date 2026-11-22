@testable import BarTune
import CryptoKit
import Foundation
import XCTest

final class AppUpdaterTests: XCTestCase {
    func testParsesAndComparesSemanticVersions() throws {
        let v040 = try XCTUnwrap(AppVersion("0.4.0"))
        let v040Tag = try XCTUnwrap(AppVersion("v0.4.0"))
        let v0100 = try XCTUnwrap(AppVersion("V0.10.0"))
        let v04 = try XCTUnwrap(AppVersion("0.4"))
        let v040Build = try XCTUnwrap(AppVersion("0.4.0+build.5"))
        let rc1 = try XCTUnwrap(AppVersion("0.4.0-rc.1"))
        let rc2 = try XCTUnwrap(AppVersion("0.4.0-rc.2"))
        let rc10 = try XCTUnwrap(AppVersion("0.4.0-rc.10"))

        XCTAssertEqual(v040, v040Tag)
        XCTAssertEqual(v040, v04)
        XCTAssertEqual(v040, v040Build)
        XCTAssertEqual(v040.formatted, "0.4.0")
        XCTAssertEqual(v040.tagFormatted, "v0.4.0")
        XCTAssertTrue(v040 < v0100)
        XCTAssertTrue(rc1 < v040)
        XCTAssertTrue(rc2 < rc10)
        XCTAssertFalse(v040 < rc1)

        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("abc"))
        XCTAssertNil(AppVersion("1"))
        XCTAssertNil(AppVersion("1.2.3.4"))
        XCTAssertNil(AppVersion("1.0.0-"))
        XCTAssertNil(AppVersion("1.0.0+"))
        XCTAssertNil(AppVersion("1.0..0"))
    }

    func testFormatsBundleVersionInfo() {
        let bundled = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.4.0",
            "CFBundleVersion": "2",
        ])
        XCTAssertEqual(bundled.displayVersion, "v0.4.0 (2)")
        XCTAssertEqual(bundled.sidebarLabel, "BarTune v0.4.0")
        XCTAssertEqual(bundled.semanticVersion, AppVersion("0.4.0"))
        XCTAssertEqual(bundled.userAgentVersion, "0.4.0")

        let prefixed = AppVersionInfo(shortVersion: "v0.4.0", buildNumber: "2")
        XCTAssertEqual(prefixed.displayVersion, "v0.4.0 (2)")
        XCTAssertEqual(prefixed.sidebarLabel, "BarTune v0.4.0")

        let matchingBuild = AppVersionInfo(shortVersion: "0.4.0", buildNumber: "0.4.0")
        XCTAssertEqual(matchingBuild.displayVersion, "v0.4.0")

        let mainBuild = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.4.15",
            "CFBundleVersion": "130",
            "BarTuneGitCommit": "a1b2c3d",
            "BarTuneReleaseChannel": "dev",
        ])
        XCTAssertEqual(mainBuild.displayVersion, "v0.4.15 (dev · a1b2c3d)")
        XCTAssertEqual(mainBuild.semanticVersion, AppVersion("0.4.15"))

        let stableBuild = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.4.0",
            "CFBundleVersion": "98",
            "BarTuneGitCommit": "a1b2c3d",
            "BarTuneReleaseChannel": "stable",
        ])
        XCTAssertEqual(stableBuild.displayVersion, "v0.4.0 (98)")

        let dev = AppVersionInfo(infoDictionary: nil)
        XCTAssertEqual(dev.displayVersion, "Dev Build")
        XCTAssertEqual(dev.sidebarLabel, "BarTune (Dev)")
        XCTAssertNil(dev.semanticVersion)
        XCTAssertEqual(dev.userAgentVersion, "dev")
    }

    func testParsesGitHubReleaseAndPrefersBarTuneDMG() throws {
        let digestHex = String(repeating: "a", count: 64)
        let json = """
        {
          "tag_name": "v0.4.0",
          "name": "BarTune v0.4.0",
          "html_url": "https://github.com/TrigrD3/bartune/releases/tag/v0.4.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "OtherInstaller.dmg",
              "browser_download_url": "https://github.com/TrigrD3/bartune/releases/download/v0.4.0/OtherInstaller.dmg",
              "size": 1234
            },
            {
              "name": "BarTune-0.4.0.dmg",
              "browser_download_url": "https://github.com/TrigrD3/bartune/releases/download/v0.4.0/BarTune-0.4.0.dmg",
              "size": 2999060,
              "digest": "sha256:\(digestHex.uppercased())"
            },
            {
              "name": "BarTune-0.4.0.dmg.sha256",
              "browser_download_url": "https://github.com/TrigrD3/bartune/releases/download/v0.4.0/BarTune-0.4.0.dmg.sha256",
              "size": 84
            }
          ]
        }
        """

        let release = try AppReleaseParser.parseLatestRelease(data: Data(json.utf8))
        XCTAssertEqual(release.tagName, "v0.4.0")
        XCTAssertEqual(release.version, AppVersion("0.4.0"))
        XCTAssertEqual(release.name, "BarTune v0.4.0")
        XCTAssertEqual(release.htmlURL.absoluteString, "https://github.com/TrigrD3/bartune/releases/tag/v0.4.0")
        XCTAssertEqual(release.dmgAsset?.name, "BarTune-0.4.0.dmg")
        XCTAssertEqual(release.dmgAsset?.sizeBytes, 2_999_060)
        XCTAssertEqual(release.dmgAsset?.sha256Digest, digestHex)
        XCTAssertEqual(
            release.checksumAssetURL?.absoluteString,
            "https://github.com/TrigrD3/bartune/releases/download/v0.4.0/BarTune-0.4.0.dmg.sha256"
        )
    }

    func testIgnoresDMGsThatAreNotTheVersionedBarTuneInstaller() throws {
        let json = """
        {
          "tag_name": "v0.4.0",
          "html_url": "https://github.com/TrigrD3/bartune/releases/tag/v0.4.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "OtherInstaller.dmg",
              "browser_download_url": "https://github.com/TrigrD3/bartune/releases/download/v0.4.0/OtherInstaller.dmg",
              "size": 1234
            },
            {
              "name": "BarTune-0.3.0.dmg",
              "browser_download_url": "https://github.com/TrigrD3/bartune/releases/download/v0.4.0/BarTune-0.3.0.dmg",
              "size": 1234
            }
          ]
        }
        """

        let release = try AppReleaseParser.parseLatestRelease(data: Data(json.utf8))
        XCTAssertNil(release.dmgAsset)
        XCTAssertNil(release.checksumAssetURL)
    }

    func testRejectsDraftPrereleaseAndUntrustedURLs() throws {
        let draftJSON = """
        {
          "tag_name": "v0.5.0",
          "html_url": "https://github.com/TrigrD3/bartune/releases/tag/v0.5.0",
          "draft": true,
          "prerelease": false,
          "assets": []
        }
        """
        XCTAssertThrowsError(try AppReleaseParser.parseLatestRelease(data: Data(draftJSON.utf8))) { error in
            XCTAssertEqual(error as? AppUpdateError, .noReleaseFound)
        }

        let prereleaseJSON = """
        {
          "tag_name": "v0.5.0-rc.1",
          "html_url": "https://github.com/TrigrD3/bartune/releases/tag/v0.5.0-rc.1",
          "draft": false,
          "prerelease": true,
          "assets": []
        }
        """
        XCTAssertThrowsError(try AppReleaseParser.parseLatestRelease(data: Data(prereleaseJSON.utf8))) { error in
            XCTAssertEqual(error as? AppUpdateError, .noReleaseFound)
        }

        let untrustedPageJSON = """
        {
          "tag_name": "v0.4.0",
          "html_url": "https://evil.example.com/TrigrD3/bartune/releases/tag/v0.4.0",
          "draft": false,
          "prerelease": false,
          "assets": []
        }
        """
        XCTAssertThrowsError(try AppReleaseParser.parseLatestRelease(data: Data(untrustedPageJSON.utf8))) { error in
            XCTAssertEqual(
                error as? AppUpdateError,
                .untrustedURL("https://evil.example.com/TrigrD3/bartune/releases/tag/v0.4.0")
            )
        }

        let untrustedAssetsJSON = """
        {
          "tag_name": "v0.4.0",
          "html_url": "https://github.com/TrigrD3/bartune/releases/tag/v0.4.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "../BarTune-0.4.0.dmg",
              "browser_download_url": "https://github.com/TrigrD3/bartune/releases/download/v0.4.0/BarTune-0.4.0.dmg",
              "size": 100
            },
            {
              "name": "BarTune-0.4.0.dmg",
              "browser_download_url": "https://evil.example.com/BarTune-0.4.0.dmg",
              "size": 100
            }
          ]
        }
        """
        let release = try AppReleaseParser.parseLatestRelease(data: Data(untrustedAssetsJSON.utf8))
        XCTAssertNil(release.dmgAsset)
        XCTAssertNil(release.checksumAssetURL)
    }

    func testParsesSHA256FileFormatsAndRejectsMismatchedFilename() {
        let hex = "cbfb1f4c79b9f47690e5cb4c04933d2edfe2fd1bed5e8d6bf5d2b553335f4bc5"
        XCTAssertEqual(
            AppReleaseParser.parseSHA256File("\(hex.uppercased())  BarTune-0.4.0.dmg\n", expectedFilename: "BarTune-0.4.0.dmg"),
            hex
        )
        XCTAssertEqual(
            AppReleaseParser.parseSHA256File("\(hex) *BarTune-0.4.0.dmg", expectedFilename: "BarTune-0.4.0.dmg"),
            hex
        )
        XCTAssertEqual(
            AppReleaseParser.parseSHA256File("  \(hex)  \n", expectedFilename: "BarTune-0.4.0.dmg"),
            hex
        )
        XCTAssertNil(AppReleaseParser.parseSHA256File("\(hex)  OtherApp.dmg", expectedFilename: "BarTune-0.4.0.dmg"))
        XCTAssertNil(AppReleaseParser.parseSHA256File("not-a-hash  BarTune-0.4.0.dmg", expectedFilename: "BarTune-0.4.0.dmg"))
        XCTAssertNil(AppReleaseParser.parseSHA256File("xyz\(String(repeating: "0", count: 61))", expectedFilename: nil))
    }

    func testDownloadUpdateVerifiesSHA256FromDigestAndChecksumAsset() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let payloadA = Data("valid-dmg-payload-from-digest".utf8)
        let hashA = sha256Hex(payloadA)
        let destA = tempRoot.appendingPathComponent("dest-a", isDirectory: true)
        let releaseA = try makeSampleRelease(sha256Digest: hashA, checksumAssetURL: nil)

        let serviceA = AppUpdateService(
            dataLoader: { _ in
                XCTFail("Unexpected dataLoader call when inline digest is present")
                throw AppUpdateError.invalidResponse
            },
            fileDownloader: { request in
                let tempFile = tempRoot.appendingPathComponent("download-a-\(UUID().uuidString).tmp")
                try payloadA.write(to: tempFile)
                let response = try self.httpResponse(url: XCTUnwrap(request.url), statusCode: 200)
                return (tempFile, response)
            },
            destinationDirectory: { destA }
        )

        let resultA = try await serviceA.downloadUpdate(for: releaseA)
        XCTAssertEqual(resultA.lastPathComponent, "BarTune-0.4.0.dmg")
        XCTAssertEqual(try Data(contentsOf: resultA), payloadA)

        let payloadB = Data("valid-dmg-payload-from-sha256-asset".utf8)
        let hashB = sha256Hex(payloadB)
        let destB = tempRoot.appendingPathComponent("dest-b", isDirectory: true)
        let checksumURL = try XCTUnwrap(
            URL(string: "https://github.com/TrigrD3/bartune/releases/download/v0.4.0/BarTune-0.4.0.dmg.sha256")
        )
        let releaseB = try makeSampleRelease(sha256Digest: nil, checksumAssetURL: checksumURL)

        let serviceB = AppUpdateService(
            dataLoader: { request in
                let response = try self.httpResponse(url: XCTUnwrap(request.url), statusCode: 200)
                return (Data("\(hashB)  BarTune-0.4.0.dmg\n".utf8), response)
            },
            fileDownloader: { request in
                let tempFile = tempRoot.appendingPathComponent("download-b-\(UUID().uuidString).tmp")
                try payloadB.write(to: tempFile)
                let response = try self.httpResponse(url: XCTUnwrap(request.url), statusCode: 200)
                return (tempFile, response)
            },
            destinationDirectory: { destB }
        )

        let resultB = try await serviceB.downloadUpdate(for: releaseB)
        XCTAssertEqual(resultB.lastPathComponent, "BarTune-0.4.0.dmg")
        XCTAssertEqual(try Data(contentsOf: resultB), payloadB)
    }

    func testDownloadUpdateRefusesReleaseWithoutTrustedChecksum() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let destDir = tempRoot.appendingPathComponent("downloads", isDirectory: true)
        let downloadCount = LockedBox(0)
        let fileDownloader: AppUpdateService.FileDownloader = { request in
            downloadCount.withLock { $0 += 1 }
            let tmp = tempRoot.appendingPathComponent("unverified-\(UUID().uuidString).tmp")
            try Data("unverified".utf8).write(to: tmp)
            return try (tmp, self.httpResponse(url: XCTUnwrap(request.url), statusCode: 200))
        }

        let noChecksum = AppUpdateService(fileDownloader: fileDownloader, destinationDirectory: { destDir })
        do {
            _ = try await noChecksum.downloadUpdate(for: makeSampleRelease(sha256Digest: nil, checksumAssetURL: nil))
            XCTFail("Expected missingChecksum error")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .missingChecksum)
        }

        let checksumURL = try XCTUnwrap(
            URL(string: "https://github.com/TrigrD3/bartune/releases/download/v0.4.0/BarTune-0.4.0.dmg.sha256")
        )
        let evilURL = try XCTUnwrap(URL(string: "https://evil.example.com/BarTune-0.4.0.dmg.sha256"))
        let redirectedChecksum = AppUpdateService(
            dataLoader: { _ in
                let hash = String(repeating: "a", count: 64)
                return try (Data("\(hash)  BarTune-0.4.0.dmg".utf8), self.httpResponse(url: evilURL, statusCode: 200))
            },
            fileDownloader: fileDownloader,
            destinationDirectory: { destDir }
        )
        do {
            _ = try await redirectedChecksum.downloadUpdate(
                for: makeSampleRelease(sha256Digest: nil, checksumAssetURL: checksumURL)
            )
            XCTFail("Expected untrustedURL error")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .untrustedURL(evilURL.absoluteString))
        }

        XCTAssertEqual(downloadCount.withLock { $0 }, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("BarTune-0.4.0.dmg").path))
    }

    func testDownloadUpdateRejectsCorruptedFileOnChecksumMismatch() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let destDir = tempRoot.appendingPathComponent("downloads", isDirectory: true)
        let expectedHash = sha256Hex(Data("expected-dmg".utf8))
        let release = try makeSampleRelease(sha256Digest: expectedHash, checksumAssetURL: nil)
        let tempFileURL = tempRoot.appendingPathComponent("corrupt.tmp")

        let service = AppUpdateService(
            fileDownloader: { request in
                try Data("corrupted-bytes".utf8).write(to: tempFileURL)
                let response = try self.httpResponse(url: XCTUnwrap(request.url), statusCode: 200)
                return (tempFileURL, response)
            },
            destinationDirectory: { destDir }
        )

        do {
            _ = try await service.downloadUpdate(for: release)
            XCTFail("Expected checksumMismatch error")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .checksumMismatch)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFileURL.path))
        let destContents = try FileManager.default.contentsOfDirectory(atPath: destDir.path)
        XCTAssertTrue(destContents.isEmpty)
    }

    func testDownloadUpdateReusesVerifiedExistingFileAndAvoidsOverwritingDifferentFile() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let destDir = tempRoot.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let expectedPayload = Data("authentic-dmg-content".utf8)
        let expectedHash = sha256Hex(expectedPayload)
        let release = try makeSampleRelease(sha256Digest: expectedHash, checksumAssetURL: nil)

        let existingFile = destDir.appendingPathComponent("BarTune-0.4.0.dmg")
        try expectedPayload.write(to: existingFile)

        let downloadCount = LockedBox(0)
        let serviceReuse = AppUpdateService(
            fileDownloader: { request in
                downloadCount.withLock { $0 += 1 }
                let tmp = tempRoot.appendingPathComponent("unused.tmp")
                try expectedPayload.write(to: tmp)
                return try (tmp, self.httpResponse(url: XCTUnwrap(request.url), statusCode: 200))
            },
            destinationDirectory: { destDir }
        )

        let reusedResult = try await serviceReuse.downloadUpdate(for: release)
        XCTAssertEqual(reusedResult.standardizedFileURL, existingFile.standardizedFileURL)
        XCTAssertEqual(downloadCount.withLock { $0 }, 0)

        let differentContent = Data("user-modified-file".utf8)
        try differentContent.write(to: existingFile)

        let serviceUnique = AppUpdateService(
            fileDownloader: { request in
                downloadCount.withLock { $0 += 1 }
                let tmp = tempRoot.appendingPathComponent("fresh-\(UUID().uuidString).tmp")
                try expectedPayload.write(to: tmp)
                return try (tmp, self.httpResponse(url: XCTUnwrap(request.url), statusCode: 200))
            },
            destinationDirectory: { destDir }
        )

        let uniqueResult = try await serviceUnique.downloadUpdate(for: release)
        XCTAssertEqual(uniqueResult.lastPathComponent, "BarTune-0.4.0-2.dmg")
        XCTAssertEqual(try Data(contentsOf: uniqueResult), expectedPayload)
        XCTAssertEqual(try Data(contentsOf: existingFile), differentContent)
        XCTAssertEqual(downloadCount.withLock { $0 }, 1)
    }

    @MainActor
    func testUpdaterModelTransitionsForAvailableUpToDateDevBuildAndRetry() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let suiteName = "com.bartune.tests.updatetransitions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let payload = Data("bar-tune-0.4.0-dmg".utf8)
        let digest = sha256Hex(payload)
        let releaseJSON = makeReleaseJSON(version: "v0.4.0", sha256Digest: digest)
        let capturedHeaders = LockedBox<[String: String]>([:])
        let shouldFailDownload = LockedBox(true)

        let service = AppUpdateService(
            dataLoader: { request in
                capturedHeaders.withLock { $0 = request.allHTTPHeaderFields ?? [:] }
                let response = try self.httpResponse(url: XCTUnwrap(request.url), statusCode: 200)
                return (Data(releaseJSON.utf8), response)
            },
            fileDownloader: { request in
                if shouldFailDownload.withLock({ $0 }) {
                    throw URLError(.timedOut)
                }
                let tmp = tempRoot.appendingPathComponent("model-\(UUID().uuidString).tmp")
                try payload.write(to: tmp)
                let response = try self.httpResponse(url: XCTUnwrap(request.url), statusCode: 200)
                return (tmp, response)
            },
            destinationDirectory: { tempRoot.appendingPathComponent("downloads", isDirectory: true) }
        )

        let outdatedModel = AppUpdaterModel(
            currentVersion: AppVersionInfo(shortVersion: "0.3.0", buildNumber: "2"),
            service: service,
            isAppleSilicon: true,
            defaults: defaults
        )
        XCTAssertEqual(outdatedModel.state, .idle)
        await outdatedModel.checkForUpdates()?.value

        guard case let .updateAvailable(release, isDevBuild) = outdatedModel.state else {
            XCTFail("Expected .updateAvailable state, got \(outdatedModel.state)")
            return
        }
        XCTAssertEqual(release.version, AppVersion("0.4.0"))
        XCTAssertFalse(isDevBuild)
        XCTAssertTrue(outdatedModel.hasAvailableUpdate)

        let headers = capturedHeaders.withLock { $0 }
        XCTAssertEqual(headers["Accept"], "application/vnd.github+json")
        XCTAssertEqual(headers["User-Agent"], "BarTune/0.3.0")

        await outdatedModel.downloadLatestUpdate()?.value
        guard case let .failed(_, failedRelease) = outdatedModel.state else {
            XCTFail("Expected .failed state on download error, got \(outdatedModel.state)")
            return
        }
        XCTAssertEqual(failedRelease, release)

        shouldFailDownload.withLock { $0 = false }
        await outdatedModel.downloadLatestUpdate()?.value
        guard case let .downloaded(_, fileURL) = outdatedModel.state else {
            XCTFail("Expected .downloaded state after retry, got \(outdatedModel.state)")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let currentModel = AppUpdaterModel(
            currentVersion: AppVersionInfo(shortVersion: "0.4.0", buildNumber: "2"),
            service: service,
            isAppleSilicon: true,
            defaults: defaults
        )
        await currentModel.checkForUpdates()?.value
        XCTAssertEqual(currentModel.state, .upToDate(release))
        XCTAssertFalse(currentModel.hasAvailableUpdate)

        let devModel = AppUpdaterModel(
            currentVersion: AppVersionInfo(infoDictionary: nil),
            service: service,
            isAppleSilicon: true,
            defaults: defaults
        )
        await devModel.checkForUpdates()?.value
        XCTAssertEqual(devModel.state, .updateAvailable(release, isDevBuild: true))
        XCTAssertFalse(devModel.hasAvailableUpdate)
    }

    func testParsesRollingMainPrereleaseByItsDMGName() throws {
        let digestHex = String(repeating: "b", count: 64)
        let json = makeMainReleaseJSON(version: "0.4.15", sha256Digest: digestHex)

        let release = try AppReleaseParser.parseLatestRelease(data: Data(json.utf8), channel: .main)
        XCTAssertEqual(release.version, AppVersion("0.4.15"))
        XCTAssertEqual(release.dmgAsset?.name, "BarTune-0.4.15.dmg")
        XCTAssertEqual(release.dmgAsset?.sha256Digest, digestHex)
        XCTAssertEqual(
            release.checksumAssetURL?.absoluteString,
            "https://github.com/TrigrD3/bartune/releases/download/dev/BarTune-0.4.15.dmg.sha256"
        )

        // The stable channel never accepts the rolling pre-release.
        XCTAssertThrowsError(try AppReleaseParser.parseLatestRelease(data: Data(json.utf8), channel: .stable)) { error in
            XCTAssertEqual(error as? AppUpdateError, .noReleaseFound)
        }

        // The main channel only accepts the dev tag, not other pre-releases.
        let otherTag = json.replacingOccurrences(of: "\"tag_name\": \"dev\"", with: "\"tag_name\": \"v0.5.0-rc.1\"")
        XCTAssertThrowsError(try AppReleaseParser.parseLatestRelease(data: Data(otherTag.utf8), channel: .main)) { error in
            XCTAssertEqual(error as? AppUpdateError, .noReleaseFound)
        }

        // A dev tag that isn't marked pre-release is not the rolling build.
        let notPrerelease = json.replacingOccurrences(of: "\"prerelease\": true", with: "\"prerelease\": false")
        XCTAssertThrowsError(try AppReleaseParser.parseLatestRelease(data: Data(notPrerelease.utf8), channel: .main)) { error in
            XCTAssertEqual(error as? AppUpdateError, .noReleaseFound)
        }

        // A non-canonical name that parses as a higher version doesn't hide the real installer.
        let stray = json.replacingOccurrences(of: "\"assets\": [", with: """
        "assets": [
            {
              "name": "BarTune-0.5.dmg",
              "browser_download_url": "https://github.com/TrigrD3/bartune/releases/download/dev/BarTune-0.5.dmg",
              "size": 3000000
            },
        """)
        let withStray = try AppReleaseParser.parseLatestRelease(data: Data(stray.utf8), channel: .main)
        XCTAssertEqual(withStray.version, AppVersion("0.4.15"))
        XCTAssertEqual(withStray.dmgAsset?.name, "BarTune-0.4.15.dmg")
        XCTAssertTrue(withStray.canDownload)

        // Names must match exactly, including case.
        let lowercased = json.replacingOccurrences(of: "BarTune-0.4.15.dmg", with: "bartune-0.4.15.dmg")
        XCTAssertThrowsError(try AppReleaseParser.parseLatestRelease(data: Data(lowercased.utf8), channel: .main)) { error in
            XCTAssertEqual(error as? AppUpdateError, .noReleaseFound)
        }
        let stableLowercased = makeReleaseJSON(version: "v0.4.0", sha256Digest: digestHex)
            .replacingOccurrences(of: "BarTune-0.4.0.dmg", with: "bartune-0.4.0.dmg")
        XCTAssertNil(try AppReleaseParser.parseLatestRelease(data: Data(stableLowercased.utf8)).dmgAsset)
    }

    @MainActor
    func testUnreadableChecksumFileDropsTheOfferInsteadOfRetrying() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let suiteName = "com.bartune.tests.badchecksum.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // No inline digest, so the .sha256 asset is the only checksum source, and it is malformed.
        let json = makeMainReleaseJSON(version: "0.4.15", sha256Digest: "")
            .replacingOccurrences(of: "\"digest\": \"sha256:\"", with: "\"digest\": null")
        let service = AppUpdateService(
            dataLoader: { request in
                let url = try XCTUnwrap(request.url)
                let body = url.absoluteString.hasSuffix(".sha256") ? "not a checksum" : json
                return try (Data(body.utf8), self.httpResponse(url: url, statusCode: 200))
            },
            fileDownloader: { _ in
                XCTFail("The installer must not be downloaded without a readable checksum")
                throw URLError(.cancelled)
            },
            destinationDirectory: { tempRoot.appendingPathComponent("downloads", isDirectory: true) }
        )
        let model = AppUpdaterModel(
            currentVersion: AppVersionInfo(shortVersion: "0.4.12", buildNumber: "120"),
            service: service,
            isAppleSilicon: true,
            defaults: defaults
        )
        model.channel = .main
        await model.checkForUpdates()?.value
        guard case let .updateAvailable(release, _) = model.state else {
            XCTFail("Expected the main build to be offered, got \(model.state)")
            return
        }
        XCTAssertNil(release.dmgAsset?.sha256Digest)
        XCTAssertTrue(release.canDownload)

        await model.downloadLatestUpdate()?.value
        guard case .failed(_, nil) = model.state else {
            XCTFail("Expected the offer to be dropped after an unreadable checksum, got \(model.state)")
            return
        }
    }

    func testReleaseWithoutChecksumIsNotDownloadable() throws {
        XCTAssertFalse(try makeSampleRelease(sha256Digest: nil, checksumAssetURL: nil).canDownload)
        XCTAssertTrue(try makeSampleRelease(sha256Digest: String(repeating: "a", count: 64), checksumAssetURL: nil).canDownload)
    }

    @MainActor
    func testMainChannelDropsAReplacedBuildInsteadOfRetryingIt() async throws {
        let tempRoot = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let suiteName = "com.bartune.tests.replacedbuild.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mainJSON = makeMainReleaseJSON(version: "0.4.15", sha256Digest: String(repeating: "b", count: 64))
        let stableJSON = makeReleaseJSON(version: "v0.5.0", sha256Digest: String(repeating: "a", count: 64))
        let service = AppUpdateService(
            dataLoader: { request in
                let url = try XCTUnwrap(request.url)
                let body = url.absoluteString.hasSuffix("/releases/tags/dev") ? mainJSON : stableJSON
                return try (Data(body.utf8), self.httpResponse(url: url, statusCode: 200))
            },
            fileDownloader: { request in
                let tmp = tempRoot.appendingPathComponent("gone-\(UUID().uuidString).tmp")
                try Data().write(to: tmp)
                return try (tmp, self.httpResponse(url: XCTUnwrap(request.url), statusCode: 404))
            },
            destinationDirectory: { tempRoot.appendingPathComponent("downloads", isDirectory: true) }
        )
        let model = AppUpdaterModel(
            currentVersion: AppVersionInfo(shortVersion: "0.4.12", buildNumber: "120"),
            service: service,
            isAppleSilicon: true,
            defaults: defaults
        )

        model.channel = .main
        await model.checkForUpdates()?.value
        guard case .updateAvailable = model.state else {
            XCTFail("Expected the main build to be offered before downloading, got \(model.state)")
            return
        }
        await model.downloadLatestUpdate()?.value
        guard case .failed(_, nil) = model.state else {
            XCTFail("Expected the replaced main build to be dropped, got \(model.state)")
            return
        }

        // A stable release isn't replaced in place, so a 404 there keeps the offer for a retry.
        model.channel = .stable
        await model.checkForUpdates()?.value
        await model.downloadLatestUpdate()?.value
        guard case .failed(_, .some) = model.state else {
            XCTFail("Expected the stable release to stay offered, got \(model.state)")
            return
        }
    }

    @MainActor
    func testUpdateChannelsCompareTheRightVersionsAndPersist() async throws {
        let suiteName = "com.bartune.tests.updatechannel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let requestedURLs = LockedBox<[String]>([])
        let stableJSON = LockedBox(makeReleaseJSON(version: "v0.4.0", sha256Digest: String(repeating: "a", count: 64)))
        let mainJSON = makeMainReleaseJSON(version: "0.4.15", sha256Digest: String(repeating: "b", count: 64))
        let service = AppUpdateService(dataLoader: { request in
            let url = try XCTUnwrap(request.url)
            requestedURLs.withLock { $0.append(url.absoluteString) }
            let body = url.absoluteString.hasSuffix("/releases/tags/dev") ? mainJSON : stableJSON.withLock { $0 }
            return try (Data(body.utf8), self.httpResponse(url: url, statusCode: 200))
        })

        // A main build ahead of the 0.4.0 release is not offered that older release.
        let mainBuild = AppVersionInfo(shortVersion: "0.4.12", buildNumber: "120", gitCommit: "a1b2c3d", releaseChannel: "dev")
        let model = AppUpdaterModel(currentVersion: mainBuild, service: service, isAppleSilicon: true, defaults: defaults)
        XCTAssertEqual(model.channel, .stable)
        await model.checkForUpdates()?.value
        guard case .upToDate = model.state else {
            XCTFail("Expected .upToDate on stable, got \(model.state)")
            return
        }

        // Switching channel resets the result and is remembered.
        model.channel = .main
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(defaults.string(forKey: AppUpdaterModel.channelDefaultsKey), "main")
        await model.checkForUpdates()?.value
        guard case let .updateAvailable(mainRelease, false) = model.state else {
            XCTFail("Expected main build 0.4.15 to update 0.4.12, got \(model.state)")
            return
        }
        XCTAssertEqual(mainRelease.version, AppVersion("0.4.15"))
        XCTAssertEqual(requestedURLs.withLock { $0 }.last, AppUpdateService.mainChannelReleaseURLString)

        let reloaded = AppUpdaterModel(currentVersion: mainBuild, service: service, isAppleSilicon: true, defaults: defaults)
        XCTAssertEqual(reloaded.channel, .main)

        // The same or an older main build is not an update.
        let newestMain = AppVersionInfo(shortVersion: "0.4.15", buildNumber: "130")
        let upToDateMain = AppUpdaterModel(currentVersion: newestMain, service: service, isAppleSilicon: true, defaults: defaults)
        await upToDateMain.checkForUpdates()?.value
        guard case .upToDate = upToDateMain.state else {
            XCTFail("Expected .upToDate for the newest main build, got \(upToDateMain.state)")
            return
        }

        // The next stable release (0.5.0) is offered to a main build on the stable channel.
        stableJSON.withLock { $0 = self.makeReleaseJSON(version: "v0.5.0", sha256Digest: String(repeating: "a", count: 64)) }
        model.channel = .stable
        await model.checkForUpdates()?.value
        guard case let .updateAvailable(stableRelease, false) = model.state else {
            XCTFail("Expected 0.5.0 to be offered, got \(model.state)")
            return
        }
        XCTAssertEqual(stableRelease.version, AppVersion("0.5.0"))
        XCTAssertEqual(stableRelease.dmgAsset?.name, "BarTune-0.5.0.dmg")
    }

    @MainActor
    func testUpdaterModelDoesNotOfferAppleSiliconReleaseToIntelMacs() async {
        let requests = LockedBox(0)
        let service = AppUpdateService(dataLoader: { request in
            requests.withLock { $0 += 1 }
            let json = self.makeReleaseJSON(version: "v0.4.0", sha256Digest: String(repeating: "a", count: 64))
            return try (Data(json.utf8), self.httpResponse(url: XCTUnwrap(request.url), statusCode: 200))
        })
        let model = AppUpdaterModel(
            currentVersion: AppVersionInfo(shortVersion: "0.3.0", buildNumber: "2"),
            service: service,
            isAppleSilicon: false
        )

        await model.checkForUpdates()?.value

        XCTAssertEqual(
            model.state,
            .failed(message: AppUpdateError.unsupportedArchitecture.localizedDescription, release: nil)
        )
        XCTAssertFalse(model.hasAvailableUpdate)
        XCTAssertEqual(requests.withLock { $0 }, 0)
    }

    private func makeTemporaryDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTuneAppUpdaterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func httpResponse(url: URL, statusCode: Int) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
    }

    private func makeSampleRelease(sha256Digest: String?, checksumAssetURL: URL?) throws -> AppReleaseInfo {
        let dmgURL = try XCTUnwrap(
            URL(string: "https://github.com/TrigrD3/bartune/releases/download/v0.4.0/BarTune-0.4.0.dmg")
        )
        let htmlURL = try XCTUnwrap(URL(string: "https://github.com/TrigrD3/bartune/releases/tag/v0.4.0"))
        let version = try XCTUnwrap(AppVersion("0.4.0"))
        return AppReleaseInfo(
            tagName: "v0.4.0",
            version: version,
            name: "BarTune v0.4.0",
            htmlURL: htmlURL,
            dmgAsset: AppReleaseAsset(
                name: "BarTune-0.4.0.dmg",
                downloadURL: dmgURL,
                sizeBytes: 2_999_060,
                sha256Digest: sha256Digest
            ),
            checksumAssetURL: checksumAssetURL
        )
    }

    private func makeMainReleaseJSON(version: String, sha256Digest: String) -> String {
        let dmg = "BarTune-\(version).dmg"
        return """
        {
          "tag_name": "dev",
          "name": "Latest (main)",
          "html_url": "https://github.com/TrigrD3/bartune/releases/tag/dev",
          "draft": false,
          "prerelease": true,
          "assets": [
            {
              "name": "\(dmg)",
              "browser_download_url": "https://github.com/TrigrD3/bartune/releases/download/dev/\(dmg)",
              "size": 3000000,
              "digest": "sha256:\(sha256Digest)"
            },
            {
              "name": "\(dmg).sha256",
              "browser_download_url": "https://github.com/TrigrD3/bartune/releases/download/dev/\(dmg).sha256",
              "size": 90
            }
          ]
        }
        """
    }

    private func makeReleaseJSON(version: String, sha256Digest: String) -> String {
        """
        {
          "tag_name": "\(version)",
          "name": "BarTune \(version)",
          "html_url": "https://github.com/TrigrD3/bartune/releases/tag/\(version)",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "BarTune-\(version.dropFirst()).dmg",
              "browser_download_url": "https://github.com/TrigrD3/bartune/releases/download/\(version)/BarTune-\(version.dropFirst()).dmg",
              "size": 2999060,
              "digest": "sha256:\(sha256Digest)"
            }
          ]
        }
        """
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
