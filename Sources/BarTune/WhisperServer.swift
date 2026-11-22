import Foundation

enum WhisperServerError: Error, Equatable {
    /// The server process is gone, so no later chunk can be transcribed.
    case exited
}

protocol WhisperTranscribing: AnyObject, Sendable {
    /// Returns no words for silence or a failed request; throws `WhisperServerError.exited` once the server is gone.
    func transcribe(_ request: AudioSyncManager.WhisperChunkRequest) async throws -> [RecognizedAudioWord]
    func shutdown()
}

/// Runs one local `whisper-server` so the model is loaded once per sync session instead of once per chunk.
final class WhisperServer: WhisperTranscribing, @unchecked Sendable {
    private let process: Process
    private let baseURL: URL

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // Audio must never leave the Mac through a system proxy.
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    var isRunning: Bool { process.isRunning }

    private init(process: Process, baseURL: URL) {
        self.process = process
        self.baseURL = baseURL
    }

    deinit {
        shutdown()
    }

    /// Starts the server and waits until the model is loaded; returns nil if it exits, times out, or is cancelled.
    static func launch(serverPath: String, modelPath: String, readyTimeout: TimeInterval = 120) async -> WhisperServer? {
        terminateOrphanedServers()
        guard let port = freeLoopbackPort() else { return nil }
        // An unguessable path prefix keeps other local processes off the server's endpoints.
        let prefix = "/" + UUID().uuidString
        guard let baseURL = URL(string: "http://127.0.0.1:\(port)\(prefix)/") else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverPath)
        process.arguments = [
            "-m", modelPath,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--request-path", prefix,
            "-l", "auto",
            "-t", "4",
        ] + (dtwPreset(forModelPath: modelPath).map { ["-dtw", $0, "-nfa"] } ?? [])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        let server = WhisperServer(process: process, baseURL: baseURL)
        let deadline = Date().addingTimeInterval(readyTimeout)
        while process.isRunning, !Task.isCancelled, Date() < deadline {
            if await server.isReady() {
                return server
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        server.shutdown()
        return nil
    }

    private static let dtwPresets: Set<String> = [
        "tiny", "tiny.en", "base", "base.en", "small", "small.en", "medium", "medium.en",
        "large.v1", "large.v2", "large.v3", "large.v3.turbo",
    ]

    /// whisper.cpp's `--dtw` preset for a GGML model file (`ggml-large-v3-turbo-q5_0.bin` → `large.v3.turbo`),
    /// or nil when the model isn't a known Whisper size.
    static func dtwPreset(forModelPath path: String) -> String? {
        var name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
        guard name.hasPrefix("ggml-") else { return nil }
        name.removeFirst(5)
        if let range = name.range(of: "-q[0-9]", options: .regularExpression) {
            name = String(name[..<range.lowerBound])
        }
        let preset = name.replacingOccurrences(of: "-", with: ".")
        return dtwPresets.contains(preset) ? preset : nil
    }

    /// PIDs of whisper-servers a previous BarTune left behind: orphaned (parent PID 1) and serving
    /// BarTune's random `--request-path /<UUID>`, so a user's own whisper-server is never matched.
    static func orphanedServerPIDs(psOutput: String) -> [Int32] {
        psOutput.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, fields[1] == "1",
                  let pid = Int32(fields[0]),
                  fields[2].contains("whisper-server"),
                  fields[2].contains("--host 127.0.0.1"),
                  fields[2].range(of: "--request-path /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}( |$)", options: .regularExpression) != nil
            else { return nil }
            return pid
        }
    }

    private static func terminateOrphanedServers() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard let output = String(bytes: data, encoding: .utf8) else { return }
        for pid in orphanedServerPIDs(psOutput: output) {
            kill(pid, SIGTERM)
        }
    }

    func transcribe(_ request: AudioSyncManager.WhisperChunkRequest) async throws -> [RecognizedAudioWord] {
        let wav = WAVEncoder.encodeMono16BitPCM(samples: request.samples, sampleRate: request.sampleRate)
        var fields = ["response_format": "verbose_json"]
        if !request.prompt.isEmpty {
            fields["prompt"] = request.prompt
        }
        if let language = request.language, !language.isEmpty {
            fields["language"] = language
        }
        let boundary = "BarTune-\(UUID().uuidString)"
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("inference"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = Self.multipartBody(boundary: boundary, wav: wav, fields: fields)

        guard let (data, response) = try? await Self.session.data(for: urlRequest),
              (response as? HTTPURLResponse)?.statusCode == 200
        else {
            // A live server that fails one request loses only that chunk.
            if !process.isRunning { throw WhisperServerError.exited }
            return []
        }
        return WhisperJSONParser.parse(
            data: data,
            chunkStartTime: request.chunkStartTime,
            playbackRate: request.playbackRate
        )
    }

    func shutdown() {
        if process.isRunning {
            process.terminate()
        }
    }

    private func isReady() async -> Bool {
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 1
        guard let (_, response) = try? await Self.session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private static func multipartBody(boundary: String, wav: Data, fields: [String: String]) -> Data {
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func freeLoopbackPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fd, socketAddress, length) == 0 && getsockname(fd, socketAddress, &length) == 0
            }
        }
        guard bound else { return nil }
        return UInt16(bigEndian: addr.sin_port)
    }
}
