import CryptoKit
import Foundation

struct AppVersion: Comparable, Equatable, Hashable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    init?(_ raw: String) {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }

        if let plusIndex = trimmed.firstIndex(of: "+") {
            let buildMetadata = trimmed[trimmed.index(after: plusIndex)...]
            guard !buildMetadata.isEmpty else { return nil }
            trimmed = String(trimmed[..<plusIndex])
        }

        let coreString: String
        let prereleaseString: String?
        if let dashIndex = trimmed.firstIndex(of: "-") {
            coreString = String(trimmed[..<dashIndex])
            let pre = String(trimmed[trimmed.index(after: dashIndex)...])
            guard !pre.isEmpty,
                  !pre.contains(where: \.isWhitespace),
                  !pre.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty)
            else { return nil }
            prereleaseString = pre
        } else {
            coreString = trimmed
            prereleaseString = nil
        }

        let parts = coreString.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return nil
            }
        }

        guard let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = parts.count == 3 ? Int(parts[2]) : 0
        else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prereleaseString
    }

    var formatted: String {
        if let prerelease {
            return "\(major).\(minor).\(patch)-\(prerelease)"
        }
        return "\(major).\(minor).\(patch)"
    }

    var tagFormatted: String {
        "v\(formatted)"
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case let (lPre?, rPre?):
            let lParts = lPre.split(separator: ".", omittingEmptySubsequences: false)
            let rParts = rPre.split(separator: ".", omittingEmptySubsequences: false)
            for idx in 0..<min(lParts.count, rParts.count) {
                let left = lParts[idx]
                let right = rParts[idx]
                if left == right { continue }

                let leftNumeric = left.allSatisfy { $0.isASCII && $0.isNumber } ? Int(left) : nil
                let rightNumeric = right.allSatisfy { $0.isASCII && $0.isNumber } ? Int(right) : nil
                switch (leftNumeric, rightNumeric) {
                case let (lNum?, rNum?):
                    return lNum < rNum
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return left < right
                }
            }
            return lParts.count < rParts.count
        }
    }
}

struct AppVersionInfo: Equatable, Sendable {
    let shortVersion: String?
    let buildNumber: String?
    let gitCommit: String?
    /// "stable" for tagged releases, "dev" for builds from main or a local checkout.
    let releaseChannel: String?

    init(shortVersion: String?, buildNumber: String?, gitCommit: String? = nil, releaseChannel: String? = nil) {
        let trimmedShort = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBuild = buildNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommit = gitCommit?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.shortVersion = (trimmedShort?.isEmpty == false) ? trimmedShort : nil
        self.buildNumber = (trimmedBuild?.isEmpty == false) ? trimmedBuild : nil
        self.gitCommit = (trimmedCommit?.isEmpty == false) ? trimmedCommit : nil
        self.releaseChannel = releaseChannel
    }

    init(infoDictionary: [String: Any]?) {
        self.init(
            shortVersion: infoDictionary?["CFBundleShortVersionString"] as? String,
            buildNumber: infoDictionary?["CFBundleVersion"] as? String,
            gitCommit: infoDictionary?["BarTuneGitCommit"] as? String,
            releaseChannel: infoDictionary?["BarTuneReleaseChannel"] as? String
        )
    }

    static func fromBundle(_ bundle: Bundle = .main) -> AppVersionInfo {
        AppVersionInfo(infoDictionary: bundle.infoDictionary)
    }

    var normalizedShortVersion: String? {
        guard var version = shortVersion else { return nil }
        if version.hasPrefix("v") || version.hasPrefix("V") {
            version.removeFirst()
        }
        return version.isEmpty ? nil : version
    }

    var semanticVersion: AppVersion? {
        shortVersion.flatMap(AppVersion.init)
    }

    var displayVersion: String {
        guard let version = normalizedShortVersion else {
            return "Dev Build"
        }
        if releaseChannel == "dev", let gitCommit {
            return "v\(version) (dev · \(gitCommit))"
        }
        if let build = buildNumber, build != version {
            return "v\(version) (\(build))"
        }
        return "v\(version)"
    }

    var sidebarLabel: String {
        guard let version = normalizedShortVersion else {
            return "BarTune (Dev)"
        }
        return "BarTune v\(version)"
    }

    var userAgentVersion: String {
        normalizedShortVersion ?? "dev"
    }
}

struct AppReleaseAsset: Equatable, Sendable {
    let name: String
    let downloadURL: URL
    let sizeBytes: Int64
    let sha256Digest: String?
}

struct AppReleaseInfo: Equatable, Sendable {
    let tagName: String
    let version: AppVersion
    let name: String
    let htmlURL: URL
    let dmgAsset: AppReleaseAsset?
    let checksumAssetURL: URL?

    /// The installer can only be downloaded when it has a checksum to verify against.
    var canDownload: Bool {
        guard let dmgAsset else { return false }
        return dmgAsset.sha256Digest != nil || checksumAssetURL != nil
    }
}

enum AppUpdateError: LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case httpError(Int)
    case invalidResponse
    case noReleaseFound
    case untrustedURL(String)
    case missingInstallerAsset
    case invalidChecksumFile
    case missingChecksum
    case checksumMismatch
    case unsupportedArchitecture

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Invalid GitHub release endpoint URL."
        case let .httpError(statusCode):
            if statusCode == 403 || statusCode == 429 {
                return "GitHub API rate limit reached (HTTP \(statusCode)). Please try again later."
            }
            return "Update check failed with HTTP \(statusCode)."
        case .invalidResponse:
            return "Received an unexpected response from GitHub Releases."
        case .noReleaseFound:
            return "No published BarTune release was found on GitHub."
        case let .untrustedURL(urlString):
            return "Blocked an untrusted update URL: \(urlString)"
        case .missingInstallerAsset:
            return "The latest release does not contain a macOS .dmg installer."
        case .invalidChecksumFile:
            return "Could not parse the release SHA-256 checksum file."
        case .missingChecksum:
            return "The release has no SHA-256 checksum, so the installer was not downloaded."
        case .checksumMismatch:
            return "Downloaded installer failed SHA-256 verification and was discarded."
        case .unsupportedArchitecture:
            return "BarTune releases are built for Apple Silicon only. Build from source to update on an Intel Mac."
        }
    }
}

enum AppReleaseURLValidator {
    static let repositoryPathPrefix = "/trigrd3/bartune/"

    static func isTrustedReleasePageURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "github.com"
            && url.path.lowercased().hasPrefix(repositoryPathPrefix)
    }

    static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }

        if host == "github.com" {
            return url.path.lowercased().hasPrefix("\(repositoryPathPrefix)releases/download/")
        }

        return host == "objects.githubusercontent.com"
            || host == "release-assets.githubusercontent.com"
            || host.hasSuffix(".githubusercontent.com")
    }

    static func isSafeFilename(_ name: String) -> Bool {
        !name.isEmpty
            && !name.hasPrefix(".")
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains("..")
            && URL(fileURLWithPath: name).lastPathComponent == name
    }
}

enum AppReleaseParser {
    private struct GitHubReleaseDTO: Decodable {
        let tagName: String
        let name: String?
        let htmlURL: String
        let draft: Bool
        let prerelease: Bool
        let assets: [GitHubReleaseAssetDTO]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case draft
            case prerelease
            case assets
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tagName = try container.decode(String.self, forKey: .tagName)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            htmlURL = try container.decode(String.self, forKey: .htmlURL)
            draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
            prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
            assets = try container.decodeIfPresent([GitHubReleaseAssetDTO].self, forKey: .assets)
        }
    }

    private struct GitHubReleaseAssetDTO: Decodable {
        let name: String
        let browserDownloadURL: String
        let size: Int64?
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
            case digest
        }
    }

    static func parseLatestRelease(data: Data, channel: UpdateChannel = .stable) throws -> AppReleaseInfo {
        let dto: GitHubReleaseDTO
        do {
            dto = try JSONDecoder().decode(GitHubReleaseDTO.self, from: data)
        } catch {
            throw AppUpdateError.invalidResponse
        }

        switch channel {
        case .stable:
            guard !dto.draft, !dto.prerelease else { throw AppUpdateError.noReleaseFound }
        case .main:
            guard !dto.draft, dto.prerelease, dto.tagName == AppUpdateService.mainChannelTag else {
                throw AppUpdateError.noReleaseFound
            }
        }

        guard let htmlURL = URL(string: dto.htmlURL),
              AppReleaseURLValidator.isTrustedReleasePageURL(htmlURL)
        else {
            throw AppUpdateError.untrustedURL(dto.htmlURL)
        }

        let assets = dto.assets ?? []
        let validDMGs: [AppReleaseAsset] = assets.compactMap { asset in
            guard AppReleaseURLValidator.isSafeFilename(asset.name),
                  asset.name.lowercased().hasSuffix(".dmg"),
                  let downloadURL = URL(string: asset.browserDownloadURL),
                  AppReleaseURLValidator.isTrustedDownloadURL(downloadURL)
            else { return nil }

            return AppReleaseAsset(
                name: asset.name,
                downloadURL: downloadURL,
                sizeBytes: max(0, asset.size ?? 0),
                sha256Digest: parseSHA256Digest(asset.digest)
            )
        }

        let version: AppVersion
        switch channel {
        case .stable:
            guard let tagVersion = AppVersion(dto.tagName) else {
                throw AppUpdateError.invalidResponse
            }
            version = tagVersion
        case .main:
            // The rolling pre-release keeps one tag, so the build is identified by its DMG name.
            guard let newest = validDMGs.compactMap({ releaseVersion(fromDMGName: $0.name) }).max() else {
                throw AppUpdateError.noReleaseFound
            }
            version = newest
        }

        // Exact names only: release.yml publishes "BarTune-<version>.dmg" and nothing else counts.
        let expectedDMGName = "BarTune-\(version.formatted).dmg"
        let preferredDMG = validDMGs.first { $0.name == expectedDMGName }

        var checksumAssetURL: URL?
        if let dmg = preferredDMG {
            let expectedChecksumName = "\(dmg.name).sha256"
            if let checksumDTO = assets.first(where: {
                AppReleaseURLValidator.isSafeFilename($0.name)
                    && $0.name == expectedChecksumName
            }),
                let url = URL(string: checksumDTO.browserDownloadURL),
                AppReleaseURLValidator.isTrustedDownloadURL(url) {
                checksumAssetURL = url
            }
        }

        let trimmedName = dto.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let releaseName = trimmedName.isEmpty ? dto.tagName : trimmedName

        return AppReleaseInfo(
            tagName: dto.tagName,
            version: version,
            name: releaseName,
            htmlURL: htmlURL,
            dmgAsset: preferredDMG,
            checksumAssetURL: checksumAssetURL
        )
    }

    private static func releaseVersion(fromDMGName name: String) -> AppVersion? {
        let lower = name.lowercased()
        guard lower.hasPrefix("bartune-"), lower.hasSuffix(".dmg") else { return nil }
        let raw = lower.dropFirst("bartune-".count).dropLast(".dmg".count)
        // Only the exact name build.sh writes, so "BarTune-0.5.dmg" can't outrank a real installer.
        guard let version = AppVersion(String(raw)), version.prerelease == nil,
              name == "BarTune-\(version.formatted).dmg"
        else { return nil }
        return version
    }

    static func parseSHA256Digest(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("sha256:") else { return nil }
        let hex = String(trimmed.dropFirst("sha256:".count))
        return isValidSHA256Hex(hex) ? hex.lowercased() : nil
    }

    static func parseSHA256File(_ text: String, expectedFilename: String? = nil) -> String? {
        guard let line = text
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else { return nil }

        let hashPart: String
        var filenamePart: String?
        if let wsIndex = line.firstIndex(where: \.isWhitespace) {
            hashPart = String(line[..<wsIndex])
            var rest = line[wsIndex...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("*") {
                rest.removeFirst()
            }
            if !rest.isEmpty {
                filenamePart = rest
            }
        } else {
            hashPart = line
        }

        guard isValidSHA256Hex(hashPart) else { return nil }

        if let expectedFilename, let filenamePart {
            guard filenamePart.lowercased() == expectedFilename.lowercased() else {
                return nil
            }
        }

        return hashPart.lowercased()
    }

    private static func isValidSHA256Hex(_ hex: String) -> Bool {
        hex.count == 64 && hex.allSatisfy {
            ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") || ($0 >= "A" && $0 <= "F")
        }
    }
}

struct AppUpdateService: Sendable {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias FileDownloader = @Sendable (URLRequest) async throws -> (URL, URLResponse)
    typealias DestinationProvider = @Sendable () -> URL

    static let latestReleaseURLString = "https://api.github.com/repos/TrigrD3/bartune/releases/latest"
    static let mainChannelTag = "dev"
    static let mainChannelReleaseURLString = "https://api.github.com/repos/TrigrD3/bartune/releases/tags/\(mainChannelTag)"
    static let repositoryURLString = "https://github.com/TrigrD3/bartune"
    static let releasesPageURLString = "https://github.com/TrigrD3/bartune/releases"

    private let dataLoader: DataLoader
    private let fileDownloader: FileDownloader
    private let destinationDirectory: DestinationProvider

    init(
        dataLoader: @escaping DataLoader = { try await URLSession.shared.data(for: $0) },
        fileDownloader: @escaping FileDownloader = { try await URLSession.shared.download(for: $0) },
        destinationDirectory: @escaping DestinationProvider = { AppUpdateService.defaultDownloadsDirectory() }
    ) {
        self.dataLoader = dataLoader
        self.fileDownloader = fileDownloader
        self.destinationDirectory = destinationDirectory
    }

    static func defaultDownloadsDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    func fetchLatestRelease(channel: UpdateChannel = .stable, userAgentVersion: String = "dev") async throws -> AppReleaseInfo {
        let urlString = channel == .stable ? Self.latestReleaseURLString : Self.mainChannelReleaseURLString
        guard let url = URL(string: urlString) else {
            throw AppUpdateError.invalidEndpoint
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("BarTune/\(userAgentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await dataLoader(request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                throw AppUpdateError.noReleaseFound
            }
            guard (200...299).contains(http.statusCode) else {
                throw AppUpdateError.httpError(http.statusCode)
            }
        }

        return try AppReleaseParser.parseLatestRelease(data: data, channel: channel)
    }

    func downloadUpdate(
        for release: AppReleaseInfo,
        userAgentVersion: String = "dev"
    ) async throws -> URL {
        guard let asset = release.dmgAsset else {
            throw AppUpdateError.missingInstallerAsset
        }
        guard AppReleaseURLValidator.isSafeFilename(asset.name) else {
            throw AppUpdateError.invalidResponse
        }
        guard AppReleaseURLValidator.isTrustedDownloadURL(asset.downloadURL) else {
            throw AppUpdateError.untrustedURL(asset.downloadURL.absoluteString)
        }

        let expectedSHA256 = try await resolveExpectedSHA256(
            for: asset,
            checksumAssetURL: release.checksumAssetURL,
            userAgentVersion: userAgentVersion
        )

        let destDir = destinationDirectory()
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let existingURL = destDir.appendingPathComponent(asset.name)
        if FileManager.default.fileExists(atPath: existingURL.path) {
            let existingHash = try? await Task.detached(priority: .utility) {
                try Self.sha256Hex(ofFileAt: existingURL)
            }.value
            if existingHash == expectedSHA256 {
                return existingURL
            }
        }

        var downloadRequest = URLRequest(url: asset.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
        downloadRequest.setValue("BarTune/\(userAgentVersion)", forHTTPHeaderField: "User-Agent")

        let (tempURL, response) = try await fileDownloader(downloadRequest)
        var movedTempFile = false
        defer {
            if !movedTempFile {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AppUpdateError.httpError(http.statusCode)
        }
        if let finalResponseURL = response.url {
            guard AppReleaseURLValidator.isTrustedDownloadURL(finalResponseURL) else {
                throw AppUpdateError.untrustedURL(finalResponseURL.absoluteString)
            }
        }

        let actualSHA256 = try await Task.detached(priority: .utility) {
            try Self.sha256Hex(ofFileAt: tempURL)
        }.value
        guard actualSHA256 == expectedSHA256 else {
            throw AppUpdateError.checksumMismatch
        }

        let finalURL = Self.uniqueDestinationURL(in: destDir, preferredName: asset.name)
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
        movedTempFile = true

        return finalURL
    }

    private func resolveExpectedSHA256(
        for asset: AppReleaseAsset,
        checksumAssetURL: URL?,
        userAgentVersion: String
    ) async throws -> String {
        if let digest = asset.sha256Digest {
            return digest
        }
        guard let checksumAssetURL else {
            throw AppUpdateError.missingChecksum
        }
        guard AppReleaseURLValidator.isTrustedDownloadURL(checksumAssetURL) else {
            throw AppUpdateError.untrustedURL(checksumAssetURL.absoluteString)
        }

        var request = URLRequest(url: checksumAssetURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("BarTune/\(userAgentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await dataLoader(request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AppUpdateError.httpError(http.statusCode)
        }
        if let finalResponseURL = response.url, !AppReleaseURLValidator.isTrustedDownloadURL(finalResponseURL) {
            throw AppUpdateError.untrustedURL(finalResponseURL.absoluteString)
        }

        guard let text = String(data: data, encoding: .utf8),
              let parsed = AppReleaseParser.parseSHA256File(text, expectedFilename: asset.name)
        else {
            throw AppUpdateError.invalidChecksumFile
        }
        return parsed
    }

    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func uniqueDestinationURL(in directory: URL, preferredName: String) -> URL {
        let candidate = directory.appendingPathComponent(preferredName)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        let nsName = preferredName as NSString
        let stem = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var index = 2
        while true {
            let fileName = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            let nextURL = directory.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: nextURL.path) {
                return nextURL
            }
            index += 1
        }
    }
}

enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case stable
    case main

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stable: return "Stable"
        case .main: return "Latest from main"
        }
    }

    var summary: String {
        switch self {
        case .stable: return "Tagged GitHub releases. Recommended."
        case .main: return "A build of every change merged to main. Newer, but less tested."
        }
    }
}

enum AppUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(AppReleaseInfo)
    case updateAvailable(AppReleaseInfo, isDevBuild: Bool)
    case downloading(AppReleaseInfo)
    case downloaded(AppReleaseInfo, fileURL: URL)
    case failed(message: String, release: AppReleaseInfo?)
}

@MainActor
final class AppUpdaterModel: ObservableObject {
    static let channelDefaultsKey = "bartune.updateChannel"

    let currentVersion: AppVersionInfo
    @Published private(set) var state: AppUpdateState = .idle
    @Published var channel: UpdateChannel {
        didSet {
            guard channel != oldValue else { return }
            defaults.set(channel.rawValue, forKey: Self.channelDefaultsKey)
            // Drop any result or in-flight check from the other channel.
            operationID += 1
            state = .idle
        }
    }

    private let service: AppUpdateService
    private let defaults: UserDefaults
    private let isAppleSilicon: Bool
    private var operationID = 0

    #if arch(arm64)
        nonisolated static let runningOnAppleSilicon = true
    #else
        // An x86_64 build under Rosetta still runs on Apple Silicon, so it can install the arm64 DMG.
        nonisolated static let runningOnAppleSilicon: Bool = {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        }()
    #endif

    init(
        currentVersion: AppVersionInfo = .fromBundle(),
        service: AppUpdateService = AppUpdateService(),
        isAppleSilicon: Bool = AppUpdaterModel.runningOnAppleSilicon,
        defaults: UserDefaults = .standard
    ) {
        self.currentVersion = currentVersion
        self.service = service
        self.isAppleSilicon = isAppleSilicon
        self.defaults = defaults
        channel = defaults.string(forKey: Self.channelDefaultsKey).flatMap(UpdateChannel.init) ?? .stable
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading:
            return true
        case .idle, .upToDate, .updateAvailable, .downloaded, .failed:
            return false
        }
    }

    var hasAvailableUpdate: Bool {
        if case let .updateAvailable(_, isDevBuild) = state {
            return !isDevBuild
        }
        return false
    }

    var latestRelease: AppReleaseInfo? {
        switch state {
        case let .upToDate(release),
             let .updateAvailable(release, _),
             let .downloading(release),
             let .downloaded(release, _):
            return release
        case let .failed(_, release):
            return release
        case .idle, .checking:
            return nil
        }
    }

    @discardableResult
    func checkForUpdates() -> Task<Void, Never>? {
        guard !isBusy else { return nil }

        guard isAppleSilicon else {
            state = .failed(message: AppUpdateError.unsupportedArchitecture.localizedDescription, release: nil)
            return nil
        }

        operationID += 1
        let id = operationID
        state = .checking
        let userAgentVersion = currentVersion.userAgentVersion
        let currentSemantic = currentVersion.semanticVersion
        let channel = channel
        let service = service

        return Task {
            do {
                let release = try await service.fetchLatestRelease(channel: channel, userAgentVersion: userAgentVersion)
                guard id == operationID else { return }

                // Builds from main follow the newest stable tag (v0.4.0 + 15 commits = 0.4.15), so both
                // channels compare plain versions and switching channels never offers an older build.
                if let currentSemantic {
                    if release.version > currentSemantic {
                        state = .updateAvailable(release, isDevBuild: false)
                    } else {
                        state = .upToDate(release)
                    }
                } else {
                    state = .updateAvailable(release, isDevBuild: true)
                }
            } catch {
                guard id == operationID else { return }
                state = .failed(message: error.localizedDescription, release: nil)
            }
        }
    }

    @discardableResult
    func downloadLatestUpdate() -> Task<Void, Never>? {
        guard !isBusy else { return nil }

        let targetRelease: AppReleaseInfo
        switch state {
        case let .updateAvailable(release, _), let .failed(_, release?):
            targetRelease = release
        case .idle, .checking, .upToDate, .downloading, .downloaded, .failed(_, nil):
            return nil
        }

        operationID += 1
        let id = operationID
        state = .downloading(targetRelease)
        let userAgentVersion = currentVersion.userAgentVersion
        let channel = channel
        let service = service

        return Task {
            do {
                let fileURL = try await service.downloadUpdate(for: targetRelease, userAgentVersion: userAgentVersion)
                guard id == operationID else { return }
                state = .downloaded(targetRelease, fileURL: fileURL)
            } catch AppUpdateError.invalidChecksumFile {
                guard id == operationID else { return }
                // Retrying would fetch the same unreadable checksum file.
                state = .failed(message: AppUpdateError.invalidChecksumFile.localizedDescription, release: nil)
            } catch AppUpdateError.httpError(404) where channel == .main {
                guard id == operationID else { return }
                // A newer push replaced this build's assets; retrying the same URL can't succeed.
                state = .failed(message: "A newer build from main replaced this one. Check for updates again.", release: nil)
            } catch {
                guard id == operationID else { return }
                state = .failed(message: error.localizedDescription, release: targetRelease)
            }
        }
    }
}
