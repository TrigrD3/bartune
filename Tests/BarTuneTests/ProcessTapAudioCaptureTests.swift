import AVFoundation
@testable import BarTune
import Combine
import CoreAudio
import Foundation
import XCTest

final class ProcessTapAudioCaptureTests: XCTestCase {
    private var tempDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bartune-processtap-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        suiteName = "com.bartune.tests.processtap.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        defaults = nil
        suiteName = nil
        tempDir = nil
        super.tearDown()
    }

    // MARK: - ProcessTapResolver

    func testResolverMatchesDirectHelpersAncestorsAndSafariWebKit() {
        let processes: [AudioProcessSnapshot] = [
            AudioProcessSnapshot(objectID: 10, pid: 100, bundleIdentifier: "com.spotify.client"),
            AudioProcessSnapshot(objectID: 11, pid: 101, bundleIdentifier: "com.spotify.client.helper"),
            AudioProcessSnapshot(objectID: 20, pid: 200, bundleIdentifier: "com.google.Chrome.helper.renderer"),
            AudioProcessSnapshot(objectID: 21, pid: 201, bundleIdentifier: "company.thebrowser.Browser.helper"),
            AudioProcessSnapshot(objectID: 22, pid: 202, bundleIdentifier: "com.google.Chrome.beta"),
            AudioProcessSnapshot(objectID: 23, pid: 203, bundleIdentifier: "com.google.Chrome.beta.helper"),
            AudioProcessSnapshot(objectID: 30, pid: 300, bundleIdentifier: "com.apple.WebKit.GPU"),
            AudioProcessSnapshot(
                objectID: 31,
                pid: 301,
                bundleIdentifier: "com.apple.WebKit.WebContent",
                ancestorBundleIdentifiers: ["com.apple.Safari"]
            ),
            AudioProcessSnapshot(
                objectID: 32,
                pid: 302,
                bundleIdentifier: "com.apple.WebKit.GPU",
                ancestorBundleIdentifiers: ["com.example.UnrelatedApp"]
            ),
            AudioProcessSnapshot(
                objectID: 40,
                pid: 400,
                bundleIdentifier: nil,
                ancestorBundleIdentifiers: ["com.brave.Browser"]
            ),
            AudioProcessSnapshot(objectID: 50, pid: 500, bundleIdentifier: "com.apple.Music"),
            AudioProcessSnapshot(objectID: 99, pid: 999, bundleIdentifier: "com.spotify.client"),
        ]

        // Direct + helper match, excluding self PID 999
        XCTAssertEqual(
            ProcessTapResolver.matchingProcessObjectIDs(
                in: processes,
                targetBundleIds: ["com.spotify.client"],
                excludedPID: 999
            ),
            [10, 11]
        )

        // Chrome helper renderer does not pull in Safari WebKit helpers
        XCTAssertEqual(
            ProcessTapResolver.matchingProcessObjectIDs(
                in: processes,
                targetBundleIds: ["com.google.Chrome"],
                excludedPID: 999
            ),
            [20]
        )

        // Shared WebKit helpers need Safari ancestry to enter Safari's tap.
        XCTAssertEqual(
            ProcessTapResolver.matchingProcessObjectIDs(
                in: processes,
                targetBundleIds: ["com.apple.Safari"],
                excludedPID: 999
            ),
            [31]
        )

        // Ancestor PID match when process bundle ID is nil
        XCTAssertEqual(
            ProcessTapResolver.matchingProcessObjectIDs(
                in: processes,
                targetBundleIds: ["com.brave.Browser"],
                excludedPID: 999
            ),
            [40]
        )

        // Empty targets returns empty
        XCTAssertTrue(
            ProcessTapResolver.matchingProcessObjectIDs(
                in: processes,
                targetBundleIds: [],
                excludedPID: 999
            ).isEmpty
        )
    }

    func testLaunchdHostedWebKitAttributionMatchesSafariAndExcludesMailApp() {
        let safari = ProcessTapResolver.responsibleBundleIdentifier(halBundleID: "com.apple.WebKit.GPU", parentPID: 1) {
            (["WebKit", "-client-identifier", "com.apple.Safari"], [])
        }
        let mail = ProcessTapResolver.responsibleBundleIdentifier(halBundleID: "COM.APPLE.WEBKIT.WEBCONTENT", parentPID: 0) {
            (["WebKit"], ["APP_SANDBOX_CONTAINER_ID=com.example.MailApp"])
        }
        XCTAssertEqual(safari, "com.apple.Safari")
        XCTAssertEqual(mail, "com.example.MailApp")

        let processes = [
            AudioProcessSnapshot(
                objectID: 30,
                pid: 300,
                bundleIdentifier: "com.apple.WebKit.GPU",
                ancestorBundleIdentifiers: safari.map { [$0] } ?? []
            ),
            AudioProcessSnapshot(
                objectID: 31,
                pid: 301,
                bundleIdentifier: "com.apple.WebKit.WebContent",
                ancestorBundleIdentifiers: mail.map { [$0] } ?? []
            ),
        ]
        XCTAssertEqual(
            ProcessTapResolver.matchingProcessObjectIDs(in: processes, targetBundleIds: ["com.apple.Safari"], excludedPID: 999),
            [30]
        )
    }

    func testResponsibleHostIgnoresNonWebKitAndNonLaunchdProcesses() {
        for (bundleID, parentPID): (String?, pid_t) in [
            ("com.example.EvilApp", 1), (nil, 1), ("com.apple.WebKit.GPU", 2),
        ] {
            let host = ProcessTapResolver.responsibleBundleIdentifier(halBundleID: bundleID, parentPID: parentPID) {
                XCTFail("Ineligible processes must be rejected before reading metadata")
                return (["app", "-client-identifier", "com.apple.Safari"], ["APP_SANDBOX_CONTAINER_ID=com.apple.Safari"])
            }
            XCTAssertNil(host)
        }
    }

    // MARK: - StereoAudioResampler

    func testResamplerDownsamples48kHzStereoTo16kHzMidSide() throws {
        let asbd = makeFloat32ASBD(sampleRate: 48000, channels: 2, interleaved: false)
        let resampler = try XCTUnwrap(StereoAudioResampler(asbd: asbd))

        // 0.1s of 440 Hz on left, inverted on right -> pure side, near-zero mid; plus 0.5 center 220 Hz on both.
        let frameCount = 4800
        let left: [Float] = (0..<frameCount).map { i in
            let t = Double(i) / 48000.0
            return Float(0.5 * sin(2 * .pi * 220 * t) + 0.3 * sin(2 * .pi * 440 * t))
        }
        let right: [Float] = (0..<frameCount).map { i in
            let t = Double(i) / 48000.0
            return Float(0.5 * sin(2 * .pi * 220 * t) - 0.3 * sin(2 * .pi * 440 * t))
        }

        let (mid, side) = resampler.process(channels: [left, right])
        XCTAssertEqual(mid.count, side.count)
        // 4800 frames at 48 kHz -> ~1600 frames at 16 kHz (allowing small converter priming margin)
        XCTAssertGreaterThan(mid.count, 1500)
        XCTAssertLessThanOrEqual(mid.count, 1650)

        let midRMS = rms(mid)
        let sideRMS = rms(side)
        XCTAssertEqual(midRMS, Float(0.5 / sqrt(2.0)), accuracy: 0.06)
        XCTAssertEqual(sideRMS, Float(0.3 / sqrt(2.0)), accuracy: 0.06)
    }

    func testResamplerHandles44_1kHzAcrossConsecutiveCallbacks() throws {
        let asbd = makeFloat32ASBD(sampleRate: 44100, channels: 2, interleaved: true)
        let resampler = try XCTUnwrap(StereoAudioResampler(asbd: asbd))

        // Feed 1 second of 44.1 kHz audio in 512-frame chunks
        var totalFrames = 0
        var phase = 0
        let chunkFrames = 512
        let chunks = 86 // ~0.998 s
        for _ in 0..<chunks {
            let left: [Float] = (0..<chunkFrames).map { i in
                Float(0.6 * sin(2 * .pi * 300 * Double(phase + i) / 44100.0))
            }
            phase += chunkFrames
            let (mid, side) = resampler.process(channels: [left, left])
            XCTAssertEqual(mid.count, side.count)
            totalFrames += mid.count
        }
        let expected = Double(chunks * chunkFrames) * 16000.0 / 44100.0
        XCTAssertEqual(Double(totalFrames), expected, accuracy: 200.0)
    }

    func testResamplerPassesThrough16kHzAndHandlesMono() throws {
        let stereoASBD = makeFloat32ASBD(sampleRate: 16000, channels: 2, interleaved: false)
        let stereoResampler = try XCTUnwrap(StereoAudioResampler(asbd: stereoASBD))
        let (mid, side) = stereoResampler.process(channels: [[1.0, 0.0], [0.0, 1.0]])
        XCTAssertEqual(mid, [0.5, 0.5])
        XCTAssertEqual(side, [0.5, -0.5])

        let monoASBD = makeFloat32ASBD(sampleRate: 48000, channels: 1, interleaved: false)
        let monoResampler = try XCTUnwrap(StereoAudioResampler(asbd: monoASBD))
        let monoIn: [Float] = (0..<2400).map { Float(0.5 * sin(2 * .pi * 250 * Double($0) / 48000.0)) }
        let (monoMid, monoSide) = monoResampler.process(channels: [monoIn])
        XCTAssertFalse(monoMid.isEmpty)
        XCTAssertTrue(monoSide.isEmpty)

        // Invalid ASBD returns nil
        XCTAssertNil(StereoAudioResampler(asbd: makeFloat32ASBD(sampleRate: 0, channels: 2, interleaved: false)))
    }

    func testExtractChannelsFromAudioBufferListFloat32AndInt16() throws {
        // Interleaved Float32 stereo
        var interleavedFloats: [Float] = [0.25, -0.25, 0.75, -0.75]
        let floatASBD = makeFloat32ASBD(sampleRate: 48000, channels: 2, interleaved: true)
        let floatChannels: [[Float]] = interleavedFloats.withUnsafeMutableBytes { raw in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(raw.count),
                    mData: raw.baseAddress
                )
            )
            return withUnsafePointer(to: &abl) { ptr in
                StereoAudioResampler.extractChannels(from: ptr, asbd: floatASBD)
            }
        }
        XCTAssertEqual(floatChannels, [[0.25, 0.75], [-0.25, -0.75]])

        // Interleaved Int16 stereo
        var interleavedInts: [Int16] = [16384, -16384]
        let intASBD = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let intChannels: [[Float]] = interleavedInts.withUnsafeMutableBytes { raw in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(raw.count),
                    mData: raw.baseAddress
                )
            )
            return withUnsafePointer(to: &abl) { ptr in
                StereoAudioResampler.extractChannels(from: ptr, asbd: intASBD)
            }
        }
        XCTAssertEqual(intChannels.map(\.count), [1, 1])
        let left = try XCTUnwrap(intChannels.first?.first)
        let right = try XCTUnwrap(intChannels.dropFirst().first?.first)
        XCTAssertEqual(left, 0.5, accuracy: 0.0001)
        XCTAssertEqual(right, -0.5, accuracy: 0.0001)
    }

    // MARK: - ProcessTapAudioCapture lifecycle & HAL events

    @MainActor
    func testStartDeliversBatched16kHzAudioAndStopDestroysAllResources() async throws {
        guard #available(macOS 14.2, *) else { return }
        let backend = MockProcessTapBackend(
            processes: [AudioProcessSnapshot(objectID: 42, pid: 1000, bundleIdentifier: "com.spotify.client")],
            runningBundles: ["com.spotify.client"],
            tapASBD: makeFloat32ASBD(sampleRate: 48000, channels: 2, interleaved: false)
        )
        let capture = ProcessTapAudioCapture(backend: backend, rebuildDebounceSeconds: 0, excludedPID: 99999)

        let delivered = expectation(description: "Delivered batched 16 kHz audio")
        let received = LockedBox<[CapturedAudio]>([])
        capture.onAudioSamples = { batch in
            let count = received.withValue { batches -> Int in
                batches.append(batch)
                return batches.count
            }
            if count == 1 {
                delivered.fulfill()
            }
        }

        try await capture.start(targetBundleIds: ["com.spotify.client"])
        XCTAssertEqual(backend.snapshot.createdTapProcessIDs, [[42]])
        XCTAssertEqual(backend.snapshot.createdAggregateCount, 1)
        XCTAssertEqual(backend.snapshot.startedIOProcCount, 1)

        // Deliver ~250 ms of 48 kHz audio (two contiguous 125 ms buffers) so AudioCaptureBatcher flushes a >=200 ms batch
        let signal = [Float](repeating: 0.4, count: 6000)
        let nowNanos = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        let firstNanos = nowNanos > 250_000_000 ? nowNanos - 250_000_000 : nowNanos
        let secondNanos = firstNanos + 125_000_000
        backend.emitBuffer(ProcessTapAudioBuffer(channels: [signal, signal], hostTimeNanos: firstNanos))
        backend.emitBuffer(ProcessTapAudioBuffer(channels: [signal, signal], hostTimeNanos: secondNanos))

        await fulfillment(of: [delivered], timeout: 2.0)

        let firstBatch = received.withValue(\.first)
        XCTAssertEqual(firstBatch?.sampleRate, 16000.0)
        XCTAssertGreaterThan(firstBatch?.samples.count ?? 0, 3000)
        XCTAssertEqual(firstBatch?.side.count, firstBatch?.samples.count)

        let teardown = expectation(description: "Tap destroyed")
        backend.fulfill(teardown, on: .tapDestroyed)
        capture.stop()
        await fulfillment(of: [teardown], timeout: 2)
        XCTAssertEqual(backend.snapshot.activeTapIDs, [])
        XCTAssertEqual(backend.snapshot.activeAggregateIDs, [])
        XCTAssertEqual(backend.snapshot.activeIOProcCount, 0)
    }

    @MainActor
    func testStartThrowsUnresolvedPlayerWhenNoTargetAppIsRunning() async {
        guard #available(macOS 14.2, *) else { return }
        let backend = MockProcessTapBackend(processes: [], runningBundles: [])
        let capture = ProcessTapAudioCapture(backend: backend, rebuildDebounceSeconds: 0, excludedPID: 99999)

        do {
            try await capture.start(targetBundleIds: ["com.spotify.client"])
            XCTFail("Expected unresolvedPlayer error")
        } catch let error as SystemAudioCaptureError {
            XCTAssertEqual(error, .unresolvedPlayer)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(backend.snapshot.createdTapProcessIDs.count, 0)
    }

    @MainActor
    func testStartArmsListenerWhenRunningAppSpawnsAudioProcessLater() async throws {
        guard #available(macOS 14.2, *) else { return }
        let backend = MockProcessTapBackend(
            processes: [],
            runningBundles: ["com.google.chrome"]
        )
        let capture = ProcessTapAudioCapture(backend: backend, rebuildDebounceSeconds: 0, excludedPID: 99999)

        try await capture.start(targetBundleIds: ["com.google.Chrome"])
        XCTAssertEqual(backend.snapshot.createdTapProcessIDs.count, 0)

        // Browser spawns an audio renderer process
        backend.setProcesses([
            AudioProcessSnapshot(objectID: 77, pid: 2000, bundleIdentifier: "com.google.Chrome.helper.renderer"),
        ])
        let started = expectation(description: "IOProc started after the renderer appeared")
        backend.fulfill(started, on: .ioProcStarted)
        backend.fireProcessListChanged()
        await fulfillment(of: [started], timeout: 2)

        XCTAssertEqual(backend.snapshot.createdTapProcessIDs, [[77]])
        XCTAssertEqual(backend.snapshot.activeTapIDs.count, 1)
        XCTAssertEqual(backend.snapshot.activeAggregateIDs.count, 1)

        // Second helper process spawns -> updates existing tap in place
        backend.setProcesses([
            AudioProcessSnapshot(objectID: 77, pid: 2000, bundleIdentifier: "com.google.Chrome.helper.renderer"),
            AudioProcessSnapshot(objectID: 88, pid: 2001, bundleIdentifier: "com.google.Chrome.helper"),
        ])
        let updated = expectation(description: "Tap updated after the helper appeared")
        backend.fulfill(updated, on: .tapUpdated)
        backend.fireProcessListChanged()
        await fulfillment(of: [updated], timeout: 2)

        XCTAssertEqual(backend.snapshot.updatedTapProcessIDs, [[77, 88]])
        XCTAssertEqual(backend.snapshot.createdTapProcessIDs.count, 1)

        let teardown = expectation(description: "Tap destroyed")
        backend.fulfill(teardown, on: .tapDestroyed)
        capture.stop()
        await fulfillment(of: [teardown], timeout: 2)
        XCTAssertEqual(backend.snapshot.activeTapIDs, [])
        XCTAssertEqual(backend.snapshot.activeAggregateIDs, [])
    }

    @MainActor
    func testDefaultOutputAndFormatChangesRebuildPipelineCleanly() async throws {
        guard #available(macOS 14.2, *) else { return }
        let backend = MockProcessTapBackend(
            processes: [AudioProcessSnapshot(objectID: 42, pid: 1000, bundleIdentifier: "com.spotify.client")],
            runningBundles: ["com.spotify.client"]
        )
        let capture = ProcessTapAudioCapture(backend: backend, rebuildDebounceSeconds: 0, excludedPID: 99999)

        try await capture.start(targetBundleIds: ["com.spotify.client"])
        XCTAssertEqual(backend.snapshot.createdAggregateCount, 1)
        XCTAssertEqual(backend.snapshot.activeTapIDs.count, 1)

        // Output route switches (e.g. AirPods connected)
        let routeRebuilt = expectation(description: "IOProc restarted after the output changed")
        backend.fulfill(routeRebuilt, on: .ioProcStarted)
        backend.fireDefaultOutputChanged()
        await fulfillment(of: [routeRebuilt], timeout: 2)
        XCTAssertEqual(backend.snapshot.createdAggregateCount, 2)
        XCTAssertEqual(backend.snapshot.activeTapIDs.count, 1)
        XCTAssertEqual(backend.snapshot.activeAggregateIDs.count, 1)
        XCTAssertEqual(backend.snapshot.activeIOProcCount, 1)

        // Tap format changes (e.g. sample rate switch 48k -> 44.1k)
        let formatRebuilt = expectation(description: "IOProc restarted after the format changed")
        backend.fulfill(formatRebuilt, on: .ioProcStarted)
        backend.fireTapFormatChanged()
        await fulfillment(of: [formatRebuilt], timeout: 2)
        XCTAssertEqual(backend.snapshot.createdAggregateCount, 3)
        XCTAssertEqual(backend.snapshot.activeTapIDs.count, 1)
        XCTAssertEqual(backend.snapshot.activeAggregateIDs.count, 1)

        let teardown = expectation(description: "Tap destroyed")
        backend.fulfill(teardown, on: .tapDestroyed)
        capture.stop()
        await fulfillment(of: [teardown], timeout: 2)
        XCTAssertEqual(backend.snapshot.activeTapIDs, [])
        XCTAssertEqual(backend.snapshot.activeAggregateIDs, [])
        XCTAssertEqual(backend.snapshot.activeIOProcCount, 0)
    }

    @MainActor
    func testRetiredTapFormatCallbackDoesNotRebuildReplacementPipeline() async throws {
        guard #available(macOS 14.2, *) else { return }
        let backend = MockProcessTapBackend(
            processes: [AudioProcessSnapshot(objectID: 42, pid: 1000, bundleIdentifier: "com.spotify.client")],
            runningBundles: ["com.spotify.client"]
        )
        let capture = ProcessTapAudioCapture(backend: backend, rebuildDebounceSeconds: 0, excludedPID: 99999)
        try await capture.start(targetBundleIds: ["com.spotify.client"])
        let retired = try XCTUnwrap(backend.tapFormatNotification)

        let rebuilt = expectation(description: "Route change rebuilds the tap")
        backend.fulfill(rebuilt, on: .ioProcStarted)
        backend.fireDefaultOutputChanged()
        await fulfillment(of: [rebuilt], timeout: 2)

        let handled = expectation(description: "Retired tap notification and any immediate work have run")
        retired.queue.async {
            retired.handler()
            retired.queue.async { handled.fulfill() }
        }
        await fulfillment(of: [handled], timeout: 2)
        XCTAssertEqual(backend.snapshot.startedIOProcCount, 2)
    }

    @MainActor
    func testFailedProcessSnapshotRetriesWithoutDestroyingWorkingTap() async throws {
        guard #available(macOS 14.2, *) else { return }
        let process = AudioProcessSnapshot(objectID: 42, pid: 1000, bundleIdentifier: "com.spotify.client")
        let helper = AudioProcessSnapshot(objectID: 43, pid: 1001, bundleIdentifier: "com.spotify.client.helper")
        let backend = MockProcessTapBackend(processes: [process], runningBundles: ["com.spotify.client"])
        let capture = ProcessTapAudioCapture(backend: backend, rebuildDebounceSeconds: 0, excludedPID: 99999)
        try await capture.start(targetBundleIds: ["com.spotify.client"])

        let updated = expectation(description: "Retry updates the existing tap after one failed snapshot")
        backend.fulfill(updated, on: .tapUpdated)
        backend.configure { $0.failNextProcessSnapshot = true }
        backend.setProcesses([process, helper])
        backend.fireProcessListChanged()
        await fulfillment(of: [updated], timeout: 2)
        XCTAssertEqual(backend.snapshot.updatedTapProcessIDs, [[42, 43]])
        XCTAssertEqual(backend.snapshot.createdTapProcessIDs, [[42]])

        let removed = expectation(description: "A successful empty snapshot tears down the tap")
        backend.fulfill(removed, on: .tapDestroyed)
        backend.setProcesses([])
        backend.fireProcessListChanged()
        await fulfillment(of: [removed], timeout: 2)
        XCTAssertTrue(backend.snapshot.activeTapIDs.isEmpty)
    }

    @MainActor
    func testRouteRebuildRetriesFailedSnapshotBeforeReplacingTap() async throws {
        guard #available(macOS 14.2, *) else { return }
        let process = AudioProcessSnapshot(objectID: 42, pid: 1000, bundleIdentifier: "com.spotify.client")
        let backend = MockProcessTapBackend(processes: [process], runningBundles: ["com.spotify.client"])
        let capture = ProcessTapAudioCapture(backend: backend, rebuildDebounceSeconds: 0, excludedPID: 99999)
        try await capture.start(targetBundleIds: ["com.spotify.client"])
        let original = backend.snapshot.activeTapIDs

        let retried = expectation(description: "The original tap is still active when the route rebuild retries")
        backend.configure {
            $0.failNextProcessSnapshot = true
            $0.onNextProcessSnapshot = {
                backend.configure {
                    $0.onNextProcessSnapshot = {
                        XCTAssertEqual(backend.snapshot.activeTapIDs, original)
                        retried.fulfill()
                    }
                }
            }
        }
        let rebuilt = expectation(description: "Successful retry rebuilds the tap for the new route")
        backend.fulfill(rebuilt, on: .ioProcStarted)
        backend.fireDefaultOutputChanged()
        await fulfillment(of: [retried, rebuilt], timeout: 2, enforceOrder: true)
        XCTAssertEqual(backend.snapshot.startedIOProcCount, 2)
        XCTAssertNotEqual(backend.snapshot.activeTapIDs, original)
    }

    @MainActor
    func testErrorPathsCleanUpPartiallyCreatedResources() async {
        guard #available(macOS 14.2, *) else { return }
        let backend = MockProcessTapBackend(
            processes: [AudioProcessSnapshot(objectID: 42, pid: 1000, bundleIdentifier: "com.spotify.client")],
            runningBundles: ["com.spotify.client"]
        )
        backend.configure { $0.failIOProcWith = ProcessTapCaptureError.deviceStartFailed(-1) }
        let capture = ProcessTapAudioCapture(backend: backend, rebuildDebounceSeconds: 0, excludedPID: 99999)

        do {
            try await capture.start(targetBundleIds: ["com.spotify.client"])
            XCTFail("Expected deviceStartFailed")
        } catch let error as ProcessTapCaptureError {
            XCTAssertEqual(error, .deviceStartFailed(-1))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Tap and aggregate device created before IOProc failed must both be destroyed
        XCTAssertEqual(backend.snapshot.activeTapIDs, [])
        XCTAssertEqual(backend.snapshot.activeAggregateIDs, [])
        XCTAssertEqual(backend.snapshot.activeIOProcCount, 0)
    }

    @MainActor
    func testStartSubscribesBeforeTakingProcessSnapshot() async throws {
        guard #available(macOS 14.2, *) else { return }
        let backend = MockProcessTapBackend(processes: [], runningBundles: ["com.google.chrome"])
        backend.configure {
            $0.processesAppearingDuringSubscription = [
                AudioProcessSnapshot(objectID: 77, pid: 2000, bundleIdentifier: "com.google.Chrome.helper.renderer"),
            ]
        }
        let capture = ProcessTapAudioCapture(backend: backend, excludedPID: 99999)

        try await capture.start(targetBundleIds: ["com.google.Chrome"])
        XCTAssertEqual(backend.snapshot.createdTapProcessIDs, [[77]])
    }

    @MainActor
    func testStartUsesFormatObservedAfterRegisteringListener() async throws {
        guard #available(macOS 14.2, *) else { return }
        let backend = MockProcessTapBackend(
            processes: [AudioProcessSnapshot(objectID: 42, pid: 1000, bundleIdentifier: "com.spotify.client")],
            runningBundles: ["com.spotify.client"]
        )
        let updatedFormat = makeFloat32ASBD(sampleRate: 44100, channels: 2, interleaved: false)
        backend.configure { $0.formatDuringSubscription = updatedFormat }
        let capture = ProcessTapAudioCapture(backend: backend, excludedPID: 99999)

        try await capture.start(targetBundleIds: ["com.spotify.client"])
        XCTAssertEqual(backend.snapshot.ioProcSampleRate, updatedFormat.mSampleRate)
    }

    @MainActor
    func testDeferredStartFailsWhenProcessListenerCannotBeRegistered() async {
        guard #available(macOS 14.2, *) else { return }
        let backend = MockProcessTapBackend(processes: [], runningBundles: ["com.google.chrome"])
        backend.configure { $0.rejectProcessListListener = true }
        let capture = ProcessTapAudioCapture(backend: backend, excludedPID: 99999)

        do {
            try await capture.start(targetBundleIds: ["com.google.Chrome"])
            XCTFail("Deferred capture requires a process list listener")
        } catch {
            XCTAssertEqual(error as? ProcessTapCaptureError, .processListListenerUnavailable)
        }
    }

    @MainActor
    func testIOProcUsesSeparateQueueAndKeepsItsSessionHandler() async throws {
        guard #available(macOS 14.2, *) else { return }
        let process = AudioProcessSnapshot(objectID: 42, pid: 1000, bundleIdentifier: "com.spotify.client")
        let backend = MockProcessTapBackend(processes: [process], runningBundles: ["com.spotify.client"])
        let capture = ProcessTapAudioCapture(backend: backend, excludedPID: 99999)
        let callback = expectation(description: "Original session callback delivered audio")
        capture.onAudioSamples = { _ in callback.fulfill() }

        try await capture.start(targetBundleIds: ["com.spotify.client"])
        XCTAssertTrue(backend.usesSeparateIOQueue)
        capture.onAudioSamples = { _ in XCTFail("Existing IOProc delivered audio to the replacement handler") }
        let signal = [Float](repeating: 0.4, count: 12000)
        backend.emitBuffer(ProcessTapAudioBuffer(channels: [signal, signal], hostTimeNanos: nil))
        await fulfillment(of: [callback], timeout: 2)
    }

    @MainActor
    func testCaptureCanDeinitializeDuringAControlQueueEvent() async throws {
        guard #available(macOS 14.2, *) else { return }
        let process = AudioProcessSnapshot(objectID: 42, pid: 1000, bundleIdentifier: "com.spotify.client")
        let backend = MockProcessTapBackend(processes: [process], runningBundles: ["com.spotify.client"])
        let owner = LockedBox<ProcessTapAudioCapture?>(
            ProcessTapAudioCapture(backend: backend, excludedPID: 99999)
        )
        try await owner.withValue { $0 }?.start(targetBundleIds: ["com.spotify.client"])
        let controlEventCompleted = expectation(description: "Control queue event completed after final owner released")
        let teardown = expectation(description: "The released capture's tap was destroyed")
        backend.fulfill(teardown, on: .tapDestroyed)

        // The process-list handler temporarily owns the capture when the last external reference is released.
        backend.configure { $0.onNextProcessSnapshot = { owner.withValue { $0 = nil } } }
        backend.fireProcessListChanged { controlEventCompleted.fulfill() }

        await fulfillment(of: [controlEventCompleted, teardown], timeout: 2)
        XCTAssertTrue(backend.snapshot.activeTapIDs.isEmpty)
        XCTAssertTrue(backend.snapshot.activeAggregateIDs.isEmpty)
        XCTAssertEqual(backend.snapshot.activeIOProcCount, 0)
    }

    @MainActor
    func testReleasingCaptureDoesNotWaitForHALTeardown() async throws {
        guard #available(macOS 14.2, *) else { return }
        let process = AudioProcessSnapshot(objectID: 42, pid: 1000, bundleIdentifier: "com.spotify.client")
        let backend = MockProcessTapBackend(processes: [process], runningBundles: ["com.spotify.client"])
        var capture: ProcessTapAudioCapture? = ProcessTapAudioCapture(backend: backend, excludedPID: 99999)
        try await capture?.start(targetBundleIds: ["com.spotify.client"])

        let releaseReturned = DispatchSemaphore(value: 0)
        backend.configure {
            $0.onIOProcStop = {
                XCTAssertEqual(releaseReturned.wait(timeout: .now() + 2), .success)
            }
        }
        let teardown = expectation(description: "HAL teardown completes after capture release returns")
        backend.fulfill(teardown, on: .tapDestroyed)
        capture = nil
        releaseReturned.signal()
        await fulfillment(of: [teardown], timeout: 3)
        XCTAssertTrue(backend.snapshot.activeTapIDs.isEmpty)
    }

    @MainActor
    func testDeferredAndRouteRebuildFailuresReportErrorAndCleanUp() async throws {
        guard #available(macOS 14.2, *) else { return }
        let process = AudioProcessSnapshot(objectID: 42, pid: 1000, bundleIdentifier: "com.spotify.client")
        for deferred in [true, false] {
            let backend = MockProcessTapBackend(
                processes: deferred ? [] : [process],
                runningBundles: ["com.spotify.client"]
            )
            let capture = ProcessTapAudioCapture(backend: backend, rebuildDebounceSeconds: 0, excludedPID: 99999)
            let failed = expectation(description: "Deferred: \(deferred), capture failure reported")
            let failure = ProcessTapCaptureError.aggregateDeviceCreationFailed(-1)
            capture.onCaptureFailure = { error in
                XCTAssertEqual(error as? ProcessTapCaptureError, failure)
                failed.fulfill()
            }

            try await capture.start(targetBundleIds: ["com.spotify.client"])
            backend.configure { $0.failAggregateWith = failure }
            if deferred {
                backend.setProcesses([process])
                backend.fireProcessListChanged()
            } else {
                backend.fireDefaultOutputChanged()
            }

            await fulfillment(of: [failed], timeout: 2)
            XCTAssertTrue(backend.snapshot.activeTapIDs.isEmpty)
            XCTAssertTrue(backend.snapshot.activeAggregateIDs.isEmpty)
            XCTAssertEqual(backend.snapshot.activeIOProcCount, 0)
        }
    }

    // MARK: - AudioSyncManager silence watchdog & permission recovery

    @MainActor
    func testLiveDependenciesUseProcessTapOnMacOS14_2Plus() {
        guard #available(macOS 14.2, *) else { return }
        let live = AudioSyncManager.Dependencies.live()
        XCTAssertTrue(live.usesProcessTap)
        XCTAssertTrue(live.capture is ProcessTapAudioCapture)
        XCTAssertTrue(live.hasScreenCaptureAccess())
    }

    @MainActor
    func testProcessTapSustainedSilenceFlagsPermissionAndAudibleAudioRecovers() async throws {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.isPlaying = true
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let mockCapture = StubAudioCapture()
        let transcribeCalls = LockedBox<Int>(0)
        let stubEngine = CountingChunkTranscriber(onTranscribe: {
            transcribeCalls.withValue { $0 += 1 }
        })

        let deps = AudioSyncManager.Dependencies(
            capture: mockCapture,
            hasScreenCaptureAccess: { true },
            requestScreenCaptureAccess: { XCTFail("Should not request Screen Recording on Process Tap") },
            chunkDurationSeconds: 12.0,
            usesProcessTap: true,
            sustainedSilenceThreshold: 0.4,
            launchLyricsAligner: { _, _ in stubEngine }
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        let track = TrackInfo(
            id: "spotify:track:silence-test",
            title: "Test",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkURL: nil,
            sourceBundleId: "com.spotify.client"
        )
        let lines = [
            LyricLine(id: 0, timestamp: 1.0, text: "Hello world"),
            LyricLine(id: 1, timestamp: 5.0, text: "Second line"),
        ]

        manager.handleTrackLoaded(track: track, rawLines: lines)
        try await Task.sleep(nanoseconds: 80_000_000)

        let silence = [Float](repeating: 0, count: 12 * 16000)
        mockCapture.emit(CapturedAudio(samples: silence, side: silence, sampleRate: 16000))
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(transcribeCalls.withValue { $0 }, 0)
        XCTAssertEqual(manager.bufferedSampleCount, 0)
        if case let .permissionRequired(detail) = state.audioSyncStatus {
            XCTAssertEqual(detail, "No audio detected — check player volume or System Audio Recording permission in Privacy & Security")
        } else {
            XCTFail("Expected .permissionRequired after sustained silence, got \(state.audioSyncStatus)")
        }
        XCTAssertEqual(state.systemAudioCapturePermission, .unknown)

        // Audible audio arrives -> marks permission verified and restores syncing status
        let audible = [Float](repeating: 0.25, count: 3200)
        mockCapture.emit(CapturedAudio(samples: Array(silence.prefix(3200)), side: audible, sampleRate: 16000))
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(state.systemAudioCapturePermission, .granted)
        if case .syncing = state.audioSyncStatus {
            // Expected recovery
        } else {
            XCTFail("Expected .syncing after audible audio arrived, got \(state.audioSyncStatus)")
        }

        // Subsequent silence after audible audio must NOT re-trigger permissionRequired
        mockCapture.emit(CapturedAudio(samples: silence, side: silence, sampleRate: 16000))
        try await Task.sleep(nanoseconds: 80_000_000)
        if case .permissionRequired = state.audioSyncStatus {
            XCTFail("Silence after audible audio should not trigger permissionRequired")
        }

        manager.stop()
    }

    @MainActor
    func testProcessTapSilenceWhilePausedDoesNotFlagPermission() async throws {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let mockCapture = StubAudioCapture()
        let stubEngine = StubChunkTranscriber()

        let deps = AudioSyncManager.Dependencies(
            capture: mockCapture,
            hasScreenCaptureAccess: { true },
            requestScreenCaptureAccess: {},
            chunkDurationSeconds: 12.0,
            usesProcessTap: true,
            sustainedSilenceThreshold: 0.2,
            launchLyricsAligner: { _, _ in stubEngine }
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        let track = TrackInfo(
            id: "spotify:track:paused-silence",
            title: "Test",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkURL: nil,
            sourceBundleId: "com.spotify.client"
        )
        manager.handleTrackLoaded(track: track, rawLines: [LyricLine(id: 0, timestamp: 1.0, text: "Hello world")])
        try await Task.sleep(nanoseconds: 80_000_000)

        let silence = [Float](repeating: 0, count: 8000)
        mockCapture.emit(CapturedAudio(samples: silence, side: silence, sampleRate: 16000))
        try await Task.sleep(nanoseconds: 80_000_000)

        if case .permissionRequired = state.audioSyncStatus {
            XCTFail("Silence while paused should not trigger permissionRequired")
        }
        manager.stop()
    }

    @MainActor
    func testProcessTapStartupAndAsyncFailuresKeepLocalizedStatus() async {
        let cases: [(error: ProcessTapCaptureError, isPermission: Bool)] = [
            (.tapCreationFailed(kAudioDevicePermissionsError), true),
            (.aggregateDeviceCreationFailed(kAudioDevicePermissionsError), true),
            (.ioProcCreationFailed(kAudioDevicePermissionsError), true),
            (.deviceStartFailed(kAudioDevicePermissionsError), true),
            (.tapCreationFailed(OSStatus(kAudioHardwareIllegalOperationError)), false),
            (.tapCreationFailed(OSStatus(kAudioHardwareBadObjectError)), false),
            (.invalidStreamFormat, false),
            (.aggregateDeviceCreationFailed(-2), false),
            (.ioProcCreationFailed(-3), false),
            (.deviceStartFailed(-4), false),
            (.routeListenerUnavailable, false),
            (.formatListenerUnavailable, false),
        ]
        let track = TrackInfo(
            id: "spotify:track:capture-failure",
            title: "Test",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkURL: nil,
            sourceBundleId: "com.spotify.client"
        )
        for (index, item) in cases.enumerated() {
            let error = item.error
            let state = LyricsState(userDefaults: defaults)
            state.audioSyncEngine = .lyricsAlignment
            let capture = StubAudioCapture()
            let failAfterStartup = index == cases.count - 1
            if !failAfterStartup {
                capture.startError = error
            }
            let started = expectation(description: "Capture startup attempted for \(error)")
            capture.onStart = { started.fulfill() }
            let manager = AudioSyncManager(
                state: state,
                cache: AudioSyncedLyricsCache(directory: tempDir),
                dependencies: AudioSyncManager.Dependencies(
                    capture: capture,
                    hasScreenCaptureAccess: { true },
                    requestScreenCaptureAccess: {},
                    chunkDurationSeconds: 12,
                    usesProcessTap: true,
                    launchLyricsAligner: { _, _ in StubChunkTranscriber() }
                )
            )
            let expected: AudioSyncStatus = item.isPermission
                ? .permissionRequired(error.localizedDescription)
                : .unavailable(error.localizedDescription)
            let failed = expectation(description: "Capture failure surfaced for \(error)")
            let status = state.$audioSyncStatus.first { $0 == expected }
                .sink { _ in failed.fulfill() }

            manager.handleTrackLoaded(track: track, rawLines: [LyricLine(id: 0, timestamp: 1, text: "Hello world")])
            await fulfillment(of: [started], timeout: 2)
            if failAfterStartup {
                capture.onCaptureFailure?(error)
            }
            await fulfillment(of: [failed], timeout: 2)
            XCTAssertEqual(state.audioSyncStatus, expected)
            XCTAssertFalse(manager.isLiveSyncActive)
            status.cancel()
        }
    }

    @MainActor
    func testRouteAndFormatListenerFailuresCleanUpResources() async {
        guard #available(macOS 14.2, *) else { return }

        let routeBackend = MockProcessTapBackend(
            processes: [AudioProcessSnapshot(objectID: 42, pid: 1000, bundleIdentifier: "com.spotify.client")],
            runningBundles: ["com.spotify.client"]
        )
        routeBackend.configure { $0.rejectDefaultOutputListener = true }
        let routeCapture = ProcessTapAudioCapture(backend: routeBackend, rebuildDebounceSeconds: 0, excludedPID: 99999)
        do {
            try await routeCapture.start(targetBundleIds: ["com.spotify.client"])
            XCTFail("Expected routeListenerUnavailable")
        } catch let error as ProcessTapCaptureError {
            XCTAssertEqual(error, .routeListenerUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(routeBackend.snapshot.activeTapIDs, [])
        XCTAssertEqual(routeBackend.snapshot.activeAggregateIDs, [])
        XCTAssertFalse(routeBackend.hasProcessListListener)

        let formatBackend = MockProcessTapBackend(
            processes: [AudioProcessSnapshot(objectID: 42, pid: 1000, bundleIdentifier: "com.spotify.client")],
            runningBundles: ["com.spotify.client"]
        )
        formatBackend.configure { $0.rejectTapFormatListener = true }
        let formatCapture = ProcessTapAudioCapture(backend: formatBackend, rebuildDebounceSeconds: 0, excludedPID: 99999)
        do {
            try await formatCapture.start(targetBundleIds: ["com.spotify.client"])
            XCTFail("Expected formatListenerUnavailable")
        } catch let error as ProcessTapCaptureError {
            XCTAssertEqual(error, .formatListenerUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(formatBackend.snapshot.activeTapIDs, [])
        XCTAssertEqual(formatBackend.snapshot.activeAggregateIDs, [])
        XCTAssertEqual(formatBackend.snapshot.activeIOProcCount, 0)
    }

    @MainActor
    func testProcessTapShortSilentFinalChunkDoesNotInvokeTranscribe() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.isPlaying = true
        state.playbackAnchorPosition = 178.75
        state.playbackAnchorDate = Date()
        let capture = StubAudioCapture()
        let started = expectation(description: "Process tap capture started")
        capture.onStart = { started.fulfill() }
        let transcribed = expectation(description: "Silent final chunk was transcribed")
        transcribed.isInverted = true
        let engine = CountingChunkTranscriber(onTranscribe: { transcribed.fulfill() })
        let deps = AudioSyncManager.Dependencies(
            capture: capture,
            hasScreenCaptureAccess: { true },
            requestScreenCaptureAccess: {},
            chunkDurationSeconds: 12,
            usesProcessTap: true,
            launchLyricsAligner: { _, _ in engine }
        )
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        defer { manager.stop() }
        let track = TrackInfo(
            id: "spotify:track:silent-final-chunk",
            title: "Test",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkURL: nil,
            sourceBundleId: "com.spotify.client"
        )
        manager.handleTrackLoaded(track: track, rawLines: [LyricLine(id: 0, timestamp: 1.0, text: "Hello world")])
        await fulfillment(of: [started], timeout: 2)

        // Half a second of silence crosses the final-chunk margin without reaching the watchdog threshold.
        let silence = [Float](repeating: 0, count: 8000)
        capture.emit(CapturedAudio(samples: silence, side: silence, sampleRate: 16000))

        await fulfillment(of: [transcribed], timeout: 0.25)
        XCTAssertEqual(manager.bufferedSampleCount, 0)
        XCTAssertEqual(state.systemAudioCapturePermission, .unknown)
    }

    @MainActor
    func testPauseResetsConsecutiveSilentSeconds() async {
        let capture = StubAudioCapture()
        let (state, manager, diagnostics) = makeWatchdogManager(capture: capture)
        defer { manager.stop() }
        let started = expectation(description: "Capture started")
        capture.onStart = { started.fulfill() }
        let track = watchdogTrack()
        manager.handleTrackLoaded(track: track, rawLines: watchdogLines)
        await fulfillment(of: [started], timeout: 2)

        await emitCapture(seconds: 5, cumulativeSeconds: 5, capture: capture, diagnostics: diagnostics)
        state.isPlaying = false
        manager.handlePlaybackStateChanged(isPlaying: false, position: 0)
        state.isPlaying = true
        manager.handlePlaybackStateChanged(isPlaying: true, position: 0)

        await emitCapture(seconds: 1, cumulativeSeconds: 6, capture: capture, diagnostics: diagnostics)
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .lyricsAlignment, alignedLines: 0, totalLines: 1))
        await emitCapture(seconds: 5, cumulativeSeconds: 11, capture: capture, diagnostics: diagnostics)
        XCTAssertEqual(state.audioSyncStatus, .processTapNoAudioWarning)
    }

    @MainActor
    func testSourceHandoffClearsWarningAndAllowsNewTargetToWarn() async {
        let capture = StubAudioCapture()
        let (state, manager, diagnostics) = makeWatchdogManager(capture: capture)
        defer { manager.stop() }
        let firstStart = expectation(description: "First browser capture started")
        capture.onStart = { firstStart.fulfill() }
        manager.handleTrackLoaded(track: watchdogTrack(), rawLines: watchdogLines)
        await fulfillment(of: [firstStart], timeout: 2)

        await emitCapture(seconds: 6, cumulativeSeconds: 6, capture: capture, diagnostics: diagnostics)
        XCTAssertEqual(state.audioSyncStatus, .processTapNoAudioWarning)

        let nextStart = expectation(description: "Second browser capture started")
        capture.onStart = { nextStart.fulfill() }
        manager.updateSourceBundle(for: watchdogTrack(sourceBundleId: "com.apple.Safari"))
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .lyricsAlignment, alignedLines: 0, totalLines: 1))
        await fulfillment(of: [nextStart], timeout: 2)

        await emitCapture(seconds: 6, cumulativeSeconds: 12, capture: capture, diagnostics: diagnostics)
        XCTAssertEqual(state.audioSyncStatus, .processTapNoAudioWarning)
    }

    @MainActor
    func testExplicitAudioDenialSurvivesCachedTrackAndAudibleCaptureRestoresGrant() async {
        let capture = StubAudioCapture()
        let (state, manager, diagnostics) = makeWatchdogManager(capture: capture)
        defer { manager.stop() }
        let track = watchdogTrack()

        func permission() -> PermissionAuthorizationState {
            AudioCapturePermissionInfo.resolve(
                usesProcessTap: true,
                screenCaptureGranted: false,
                processTapPermission: state.systemAudioCapturePermission,
                audioSyncStatus: state.audioSyncStatus
            ).state
        }

        let firstStart = expectation(description: "Capture started")
        capture.onStart = { firstStart.fulfill() }
        manager.handleTrackLoaded(track: track, rawLines: watchdogLines)
        await fulfillment(of: [firstStart], timeout: 2)
        await emitCapture(seconds: 1, amplitude: 0.2, cumulativeSeconds: 1, capture: capture, diagnostics: diagnostics)
        XCTAssertEqual(permission(), .granted)

        let error = ProcessTapCaptureError.deviceStartFailed(kAudioDevicePermissionsError)
        let denied = expectation(description: "Explicit denial surfaced")
        let denial = state.$audioSyncStatus.first { $0 == .permissionRequired(error.localizedDescription) }
            .sink { _ in denied.fulfill() }
        defer { denial.cancel() }
        capture.onCaptureFailure?(error)
        await fulfillment(of: [denied], timeout: 2)
        XCTAssertEqual(permission(), .denied)

        let words = [
            WordTimestamp(timestamp: 1, duration: 0.4, text: "Hello "),
            WordTimestamp(timestamp: 1.4, duration: 0.4, text: "world"),
        ]
        let cached = watchdogTrack(id: "browser:already-synced")
        manager.handleTrackLoaded(track: cached, rawLines: [LyricLine(id: 0, timestamp: 1, text: "Hello world", words: words)])
        await manager.flushCacheOperations()
        XCTAssertEqual(state.audioSyncStatus, .cached(.lyricsAlignment))
        XCTAssertEqual(permission(), .denied)

        let recoveryStart = expectation(description: "Recovery capture started")
        capture.onStart = { recoveryStart.fulfill() }
        manager.handleTrackLoaded(track: track, rawLines: watchdogLines)
        await fulfillment(of: [recoveryStart], timeout: 2)
        await emitCapture(seconds: 1, amplitude: 0.2, cumulativeSeconds: 1, capture: capture, diagnostics: diagnostics)
        XCTAssertEqual(permission(), .granted)
    }

    @MainActor
    func testNoAudioWatchdogWaitsForPendingCaptureStartEvenAfterPlaybackResumes() async {
        let capture = StubAudioCapture()
        let (startGate, acceptStart) = AsyncStream<Void>.makeStream()
        let startPending = expectation(description: "Capture start is pending")
        capture.awaitStart = {
            startPending.fulfill()
            var iterator = startGate.makeAsyncIterator()
            _ = await iterator.next()
        }
        let startReleased = LockedBox(false)
        let armed = expectation(description: "Watchdog starts a full observation interval")
        let (watchdogGate, fireWatchdog) = AsyncStream<Void>.makeStream()
        let (state, manager, diagnostics) = makeWatchdogManager(capture: capture) { duration in
            XCTAssertTrue(startReleased.withValue { $0 })
            XCTAssertEqual(duration, .seconds(6))
            armed.fulfill()
            var iterator = watchdogGate.makeAsyncIterator()
            _ = await iterator.next()
        }
        defer {
            manager.stop()
            acceptStart.finish()
            fireWatchdog.finish()
        }
        let warned = expectation(description: "No-audio warning")
        let status = state.$audioSyncStatus.first { $0 == .processTapNoAudioWarning }
            .sink { _ in warned.fulfill() }
        defer { status.cancel() }

        manager.handleTrackLoaded(track: watchdogTrack(), rawLines: watchdogLines)
        await fulfillment(of: [startPending], timeout: 2)
        state.isPlaying = false
        manager.handlePlaybackStateChanged(isPlaying: false, position: 0)
        state.isPlaying = true
        manager.handlePlaybackStateChanged(isPlaying: true, position: 0)
        await emitCapture(seconds: 6, cumulativeSeconds: 6, capture: capture, diagnostics: diagnostics)
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .lyricsAlignment, alignedLines: 0, totalLines: 1))

        let pendingBatchStart = ProcessInfo.processInfo.systemUptime - 6
        startReleased.withValue { $0 = true }
        acceptStart.yield(())
        await fulfillment(of: [armed], timeout: 2)
        await emitCapture(seconds: 6, cumulativeSeconds: 12, capturedAt: pendingBatchStart, capture: capture, diagnostics: diagnostics)
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .lyricsAlignment, alignedLines: 0, totalLines: 1))
        fireWatchdog.yield(())
        await fulfillment(of: [warned], timeout: 2)
    }

    @MainActor
    func testZeroBufferNoAudioWatchdogFlagsWarningAndRecoversOnAudibleBuffer() async throws {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.isPlaying = true
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let mockCapture = StubAudioCapture()
        let transcribeCalls = LockedBox<Int>(0)
        let stubEngine = CountingChunkTranscriber(onTranscribe: {
            transcribeCalls.withValue { $0 += 1 }
        })

        let deps = AudioSyncManager.Dependencies(
            capture: mockCapture,
            hasScreenCaptureAccess: { true },
            requestScreenCaptureAccess: {},
            chunkDurationSeconds: 0.4,
            usesProcessTap: true,
            sustainedSilenceThreshold: 0.05,
            launchLyricsAligner: { _, _ in stubEngine },
            noAudioWatchdogSleep: { try await Task.sleep(for: $0) }
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        let track = TrackInfo(
            id: "spotify:track:zero-buffer-watchdog",
            title: "Test",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkURL: nil,
            sourceBundleId: "com.spotify.client"
        )
        let warned = expectation(description: "No-audio warning surfaced with zero buffers")
        let sub = state.$audioSyncStatus.first { $0 == .processTapNoAudioWarning }
            .sink { _ in warned.fulfill() }

        manager.handleTrackLoaded(track: track, rawLines: [LyricLine(id: 0, timestamp: 1.0, text: "Hello world")])
        await fulfillment(of: [warned], timeout: 2.0)
        sub.cancel()

        // Feeding a full silent chunk after the warning must NOT invoke the stateful aligner
        let silence = [Float](repeating: 0, count: 8000)
        mockCapture.emit(CapturedAudio(samples: silence, side: silence, sampleRate: 16000))
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(transcribeCalls.withValue { $0 }, 0)
        XCTAssertEqual(state.audioSyncStatus, .processTapNoAudioWarning)

        // First audible buffer clears the warning and resumes syncing
        let audible = [Float](repeating: 0.2, count: 1600)
        mockCapture.emit(CapturedAudio(samples: audible, side: [Float](repeating: 0, count: 1600), sampleRate: 16000))
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(state.systemAudioCapturePermission, .granted)
        if case .syncing = state.audioSyncStatus {
            // Expected recovery
        } else {
            XCTFail("Expected .syncing after audible buffer, got \(state.audioSyncStatus)")
        }
        manager.stop()
    }

    // MARK: - Helpers

    private var watchdogLines: [LyricLine] {
        [LyricLine(id: 0, timestamp: 1, text: "Hello world")]
    }

    private func watchdogTrack(id: String = "browser:watchdog", sourceBundleId: String = "com.google.Chrome") -> TrackInfo {
        TrackInfo(
            id: id,
            title: "Test",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkURL: nil,
            sourceBundleId: sourceBundleId
        )
    }

    @MainActor
    private func makeWatchdogManager(
        capture: StubAudioCapture,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(60)) }
    ) -> (LyricsState, AudioSyncManager, AudioSyncDiagnosticsModel) {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.isPlaying = true
        let diagnostics = AudioSyncDiagnosticsModel()
        let manager = AudioSyncManager(
            state: state,
            cache: AudioSyncedLyricsCache(directory: tempDir),
            dependencies: AudioSyncManager.Dependencies(
                capture: capture,
                hasScreenCaptureAccess: { true },
                requestScreenCaptureAccess: {},
                chunkDurationSeconds: 12,
                usesProcessTap: true,
                launchLyricsAligner: { _, _ in StubChunkTranscriber() },
                noAudioWatchdogSleep: sleep
            ),
            diagnostics: diagnostics
        )
        return (state, manager, diagnostics)
    }

    @MainActor
    private func emitCapture(
        seconds: Int,
        amplitude: Float = 0,
        cumulativeSeconds: Int,
        capturedAt: TimeInterval? = nil,
        capture: StubAudioCapture,
        diagnostics: AudioSyncDiagnosticsModel
    ) async {
        let processed = expectation(description: "Processed \(cumulativeSeconds) seconds of capture")
        let observation = diagnostics.$snapshot.first { $0?.audioSeconds == cumulativeSeconds }
            .sink { _ in processed.fulfill() }
        defer { observation.cancel() }
        capture.emit(CapturedAudio(samples: [Float](repeating: amplitude, count: seconds * 16000), sampleRate: 16000, capturedAt: capturedAt))
        await fulfillment(of: [processed], timeout: 2)
    }

    private func makeFloat32ASBD(sampleRate: Double, channels: UInt32, interleaved: Bool) -> AudioStreamBasicDescription {
        let flags: AudioFormatFlags = interleaved
            ? (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
            : (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved)
        let bytesPerFrame: UInt32 = interleaved ? (4 * channels) : 4
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSq = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSq / Float(samples.count))
    }
}

// MARK: - Test Doubles

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private final class StubListenerToken: HALListenerToken {
    private let onRelease: () -> Void

    init(onRelease: @escaping () -> Void) {
        self.onRelease = onRelease
    }

    deinit { onRelease() }
}

final class MockProcessTapBackend: ProcessTapBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [AudioProcessSnapshot]
    private var runningBundles: Set<String>
    private var tapASBD: AudioStreamBasicDescription
    private var nextID: AudioObjectID = 100

    struct Snapshot {
        var createdTapProcessIDs: [[AudioObjectID]] = []
        var updatedTapProcessIDs: [[AudioObjectID]] = []
        var createdAggregateCount = 0
        var startedIOProcCount = 0
        var activeTapIDs: Set<AudioObjectID> = []
        var activeAggregateIDs: Set<AudioObjectID> = []
        var activeIOProcCount = 0
        var ioProcSampleRate: Double?
    }

    struct Configuration {
        var processesAppearingDuringSubscription: [AudioProcessSnapshot] = []
        var rejectProcessListListener = false
        var rejectDefaultOutputListener = false
        var rejectTapFormatListener = false
        var failNextProcessSnapshot = false
        var onNextProcessSnapshot: (@Sendable () -> Void)?
        var onIOProcStop: (@Sendable () -> Void)?
        var failAggregateWith: Error?
        var failIOProcWith: Error?
        var formatDuringSubscription: AudioStreamBasicDescription?
    }

    enum Event {
        case ioProcStarted
        case tapUpdated
        case tapDestroyed
    }

    private var state = Snapshot()
    private var configuration = Configuration()
    private var pendingExpectations: [Event: XCTestExpectation] = [:]

    var snapshot: Snapshot { lock.withLock { state } }

    func configure(_ update: (inout Configuration) -> Void) {
        lock.withLock { update(&configuration) }
    }

    func fulfill(_ expectation: XCTestExpectation, on event: Event) {
        lock.withLock { pendingExpectations[event] = expectation }
    }

    private var onBuffer: (@Sendable (ProcessTapAudioBuffer) -> Void)?
    private var ioQueue: DispatchQueue?
    enum ListenerKind {
        case processList
        case defaultOutput
        case tapFormat
    }

    struct ListenerRegistration: Sendable {
        let id = UUID()
        let queue: DispatchQueue
        let handler: @Sendable () -> Void
    }

    private var listeners: [ListenerKind: ListenerRegistration] = [:]

    var hasProcessListListener: Bool { lock.withLock { listeners[.processList] != nil } }
    var tapFormatNotification: ListenerRegistration? { lock.withLock { listeners[.tapFormat] } }

    init(
        processes: [AudioProcessSnapshot],
        runningBundles: Set<String>,
        tapASBD: AudioStreamBasicDescription = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    ) {
        self.processes = processes
        self.runningBundles = runningBundles
        self.tapASBD = tapASBD
    }

    var usesSeparateIOQueue: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let ioQueue, let processListHandler = listeners[.processList] else { return false }
        return ioQueue !== processListHandler.queue
    }

    func setProcesses(_ updated: [AudioProcessSnapshot]) {
        lock.lock()
        processes = updated
        lock.unlock()
    }

    func emitBuffer(_ buffer: ProcessTapAudioBuffer) {
        lock.lock()
        let cb = onBuffer
        let queue = ioQueue
        lock.unlock()
        queue?.async { cb?(buffer) }
    }

    func fireProcessListChanged(completion: @escaping @Sendable () -> Void = {}) {
        lock.lock()
        let entry = listeners[.processList]
        lock.unlock()
        entry?.queue.async {
            entry?.handler()
            completion()
        }
    }

    func fireDefaultOutputChanged() {
        lock.lock()
        let entry = listeners[.defaultOutput]
        lock.unlock()
        entry?.queue.async { entry?.handler() }
    }

    func fireTapFormatChanged() {
        lock.lock()
        let entry = listeners[.tapFormat]
        lock.unlock()
        entry?.queue.async { entry?.handler() }
    }

    func listAudioProcesses() -> [AudioProcessSnapshot]? {
        lock.lock()
        let snapshot = processes
        let failed = configuration.failNextProcessSnapshot
        configuration.failNextProcessSnapshot = false
        let onSnapshot = configuration.onNextProcessSnapshot
        configuration.onNextProcessSnapshot = nil
        lock.unlock()
        onSnapshot?()
        return failed ? nil : snapshot
    }

    func runningApplicationBundleIDs() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return runningBundles
    }

    func createTap(processObjectIDs: [AudioObjectID]) -> (tapID: AudioObjectID, tapUID: String, format: AudioStreamBasicDescription) {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        let id = nextID
        state.createdTapProcessIDs.append(processObjectIDs)
        state.activeTapIDs.insert(id)
        return (id, UUID().uuidString, tapASBD)
    }

    func updateTap(tapID: AudioObjectID, processObjectIDs: [AudioObjectID]) {
        lock.lock()
        state.updatedTapProcessIDs.append(processObjectIDs)
        let updated = pendingExpectations.removeValue(forKey: .tapUpdated)
        lock.unlock()
        updated?.fulfill()
    }

    func destroyTap(tapID: AudioObjectID) {
        lock.lock()
        state.activeTapIDs.remove(tapID)
        let destroyed = pendingExpectations.removeValue(forKey: .tapDestroyed)
        lock.unlock()
        destroyed?.fulfill()
    }

    func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        lock.lock()
        defer { lock.unlock() }
        if let failAggregateWith = configuration.failAggregateWith { throw failAggregateWith }
        nextID += 1
        let id = nextID
        state.createdAggregateCount += 1
        state.activeAggregateIDs.insert(id)
        return id
    }

    func destroyAggregateDevice(deviceID: AudioObjectID) {
        lock.lock()
        state.activeAggregateIDs.remove(deviceID)
        lock.unlock()
    }

    func tapFormat(tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        lock.lock()
        defer { lock.unlock() }
        return tapASBD
    }

    func startIOProc(
        deviceID: AudioObjectID,
        format: AudioStreamBasicDescription,
        queue: DispatchQueue,
        onBuffer: @escaping @Sendable (ProcessTapAudioBuffer) -> Void
    ) throws -> AudioDeviceIOProcID {
        let started = try lock.withLock {
            if let failIOProcWith = configuration.failIOProcWith { throw failIOProcWith }
            state.startedIOProcCount += 1
            state.activeIOProcCount += 1
            self.onBuffer = onBuffer
            self.ioQueue = queue
            state.ioProcSampleRate = format.mSampleRate
            return pendingExpectations.removeValue(forKey: .ioProcStarted)
        }
        started?.fulfill()
        // Safe non-null C function pointer token for test double
        return { _, _, _, _, _, _, _ in noErr }
    }

    func stopAndDestroyIOProc(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) {
        let onStop = lock.withLock { configuration.onIOProcStop }
        onStop?()
        lock.lock()
        state.activeIOProcCount = max(0, state.activeIOProcCount - 1)
        onBuffer = nil
        ioQueue = nil
        lock.unlock()
    }

    func addProcessListListener(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> HALListenerToken? {
        lock.lock()
        defer { lock.unlock() }
        guard !configuration.rejectProcessListListener else { return nil }
        if !configuration.processesAppearingDuringSubscription.isEmpty {
            processes = configuration.processesAppearingDuringSubscription
        }
        return registerListener(.processList, queue: queue, handler: handler)
    }

    func addDefaultOutputDeviceListener(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> HALListenerToken? {
        lock.lock()
        defer { lock.unlock() }
        guard !configuration.rejectDefaultOutputListener else { return nil }
        return registerListener(.defaultOutput, queue: queue, handler: handler)
    }

    func addTapFormatListener(tapID: AudioObjectID, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> HALListenerToken? {
        lock.lock()
        defer { lock.unlock() }
        guard !configuration.rejectTapFormatListener else { return nil }
        if let format = configuration.formatDuringSubscription {
            tapASBD = format
        }
        return registerListener(.tapFormat, queue: queue, handler: handler)
    }

    private func registerListener(_ kind: ListenerKind, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> HALListenerToken {
        let registration = ListenerRegistration(queue: queue, handler: handler)
        listeners[kind] = registration
        return StubListenerToken { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard self.listeners[kind]?.id == registration.id else { return }
                self.listeners[kind] = nil
            }
        }
    }
}

private final class CountingChunkTranscriber: AudioChunkTranscribing, @unchecked Sendable {
    private let onTranscribe: @Sendable () -> Void

    init(onTranscribe: @escaping @Sendable () -> Void) {
        self.onTranscribe = onTranscribe
    }

    func transcribe(_ request: AudioSyncManager.AudioChunkRequest) -> [RecognizedAudioWord] {
        onTranscribe()
        return []
    }

    func shutdown() {}
}

private final class StubAudioCapture: AudioCaptureProviding, @unchecked Sendable {
    var onAudioSamples: (@Sendable (CapturedAudio) -> Void)?

    var onCaptureFailure: (@Sendable (Error) -> Void)?
    var startError: Error?
    var onStart: (() -> Void)?
    var awaitStart: (() async -> Void)?

    @MainActor
    func start(targetBundleIds: Set<String>, sampleRate: Int = 16000) async throws {
        onStart?()
        await awaitStart?()
        if let startError { throw startError }
    }

    @MainActor
    func stop() {}

    func emit(_ audio: CapturedAudio) {
        onAudioSamples?(audio)
    }
}

private final class StubChunkTranscriber: AudioChunkTranscribing, @unchecked Sendable {
    func transcribe(_ request: AudioSyncManager.AudioChunkRequest) -> [RecognizedAudioWord] {
        []
    }

    func shutdown() {}
}
