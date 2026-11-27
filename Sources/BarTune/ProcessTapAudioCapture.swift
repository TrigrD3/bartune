import AppKit
import AVFoundation
import CoreAudio
import Darwin
import Foundation
import os

enum ProcessTapCaptureError: LocalizedError, Equatable {
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case invalidStreamFormat
    case processListListenerUnavailable
    case routeListenerUnavailable
    case formatListenerUnavailable

    /// Whether this error indicates a System Audio Recording authorization failure rather than a transient HAL error.
    var isPermissionError: Bool {
        switch self {
        case let .tapCreationFailed(status), let .aggregateDeviceCreationFailed(status),
             let .ioProcCreationFailed(status), let .deviceStartFailed(status):
            return status == kAudioDevicePermissionsError
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case let .tapCreationFailed(status):
            if isPermissionError {
                return "System Audio Recording permission denied (OSStatus \(status))."
            }
            return "Could not create audio process tap (OSStatus \(status))."
        case let .aggregateDeviceCreationFailed(status):
            return "Could not create private audio aggregate device (OSStatus \(status))."
        case let .ioProcCreationFailed(status):
            return "Could not attach audio capture callback (OSStatus \(status))."
        case let .deviceStartFailed(status):
            return "Could not start audio tap device (OSStatus \(status))."
        case .invalidStreamFormat:
            return "Audio tap reported an unsupported stream format."
        case .processListListenerUnavailable:
            return "Could not monitor Core Audio processes for the selected player."
        case .routeListenerUnavailable:
            return "Could not monitor audio output route changes for process tap capture."
        case .formatListenerUnavailable:
            return "Could not monitor audio tap stream format changes."
        }
    }
}

/// Snapshot of a Core Audio process object (`kAudioHardwarePropertyProcessObjectList`).
struct AudioProcessSnapshot: Equatable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleIdentifier: String?
    /// Bundle IDs of OS-reported parent processes or a WebKit helper’s responsible host.
    var ancestorBundleIdentifiers: [String] = []
}

/// Pure resolver that maps Core Audio process objects to target media player bundle IDs.
enum ProcessTapResolver {
    /// Returns the sorted Core Audio `AudioObjectID`s belonging to the selected players.
    static func matchingProcessObjectIDs(
        in processes: [AudioProcessSnapshot],
        targetBundleIds: Set<String>,
        excludedPID: pid_t = getpid()
    ) -> [AudioObjectID] {
        guard !targetBundleIds.isEmpty else { return [] }
        let targets = Set(targetBundleIds.map { $0.lowercased() })
        return processes.filter { process in
            guard process.pid != excludedPID else { return false }
            if let bundleID = process.bundleIdentifier?.lowercased(),
               targets.contains(where: { target in
                   bundleID == target || bundleID == target + ".helper" || bundleID.hasPrefix(target + ".helper.")
               }) {
                return true
            }
            // Shared helpers such as WebKit require ancestry or a responsible host tied to the selected player.
            return process.ancestorBundleIdentifiers.contains { targets.contains($0.lowercased()) }
        }.map(\.objectID).sorted()
    }

    /// Reads responsible-host metadata only for launchd-hosted WebKit audio processes.
    static func responsibleBundleIdentifier(
        halBundleID: String?,
        parentPID: pid_t,
        readProcessArguments: () -> (arguments: [String], environment: [String])?
    ) -> String? {
        guard parentPID <= 1,
              let bundleID = halBundleID?.lowercased(),
              bundleID == "com.apple.webkit.gpu" || bundleID == "com.apple.webkit.webcontent",
              let (arguments, environment) = readProcessArguments()
        else { return nil }

        for index in arguments.indices {
            let arg = arguments[index]
            if arg == "-client-identifier" || arg == "-clientIdentifier" || arg == "--client-identifier",
               index + 1 < arguments.count {
                let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
            for prefix in ["-client-identifier=", "-clientIdentifier=", "--client-identifier="] where arg.hasPrefix(prefix) {
                let value = String(arg.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        let envKeys = ["APP_SANDBOX_CONTAINER_ID=", "WK_HOST_BUNDLE_ID=", "XPC_CLIENT_BUNDLE_ID="]
        for entry in environment {
            for key in envKeys where entry.hasPrefix(key) {
                let value = String(entry.dropFirst(key.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }
}

/// Extracts Float32 channel arrays from a Core Audio `AudioBufferList` and resamples them to target-rate mid/side.
final class StereoAudioResampler {
    static let targetSampleRate: Double = 16000.0

    let inputSampleRate: Double
    let outputSampleRate: Double
    let inputChannelCount: Int
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    init?(asbd: AudioStreamBasicDescription, targetSampleRate: Double = StereoAudioResampler.targetSampleRate) {
        guard asbd.mSampleRate.isFinite, asbd.mSampleRate > 0,
              targetSampleRate.isFinite, targetSampleRate > 0,
              asbd.mChannelsPerFrame > 0
        else {
            return nil
        }
        let channels = Int(asbd.mChannelsPerFrame)
        let outputChannels: AVAudioChannelCount = channels >= 2 ? 2 : 1

        guard let inFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(min(channels, 2)),
            interleaved: false
        ),
            let outFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: outputChannels,
                interleaved: false
            )
        else { return nil }

        self.inputSampleRate = asbd.mSampleRate
        self.outputSampleRate = targetSampleRate
        self.inputChannelCount = channels
        self.inputFormat = inFmt
        self.outputFormat = outFmt

        if abs(asbd.mSampleRate - targetSampleRate) <= 0.5 {
            self.converter = nil
        } else {
            guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else { return nil }
            conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            self.converter = conv
        }
    }

    /// Extracts Float32 channels from an `AudioBufferList` described by `asbd`.
    static func extractChannels(
        from bufferList: UnsafePointer<AudioBufferList>,
        asbd: AudioStreamBasicDescription
    ) -> [[Float]] {
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard (isFloat && asbd.mBitsPerChannel == 32) || (!isFloat && asbd.mBitsPerChannel == 16) else {
            return []
        }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        var channels: [[Float]] = []
        for buffer in buffers {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let samples: [Float]
            if isFloat {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                samples = Array(UnsafeBufferPointer(start: data.bindMemory(to: Float.self, capacity: count), count: count))
            } else {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                samples = UnsafeBufferPointer(start: data.bindMemory(to: Int16.self, capacity: count), count: count)
                    .map { Float($0) / 32768.0 }
            }
            channels.append(contentsOf: AudioSampleExtractor.deinterleave(samples, channelCount: max(1, Int(buffer.mNumberChannels))))
        }
        return channels
    }

    /// Downsamples `channels` (already Float32 per channel at `inputSampleRate`) to 16 kHz mid & side.
    func process(channels: [[Float]]) -> (mid: [Float], side: [Float]) {
        guard let first = channels.first, !first.isEmpty else { return ([], []) }
        let frameCount = channels.map(\.count).min() ?? 0
        guard frameCount > 0 else { return ([], []) }

        // Mix down >2 channels to stereo before resampling so AVAudioConverter stays 2-channel.
        let stereoOrMono: [[Float]]
        if channels.count == 1 {
            stereoOrMono = [Array(first.prefix(frameCount))]
        } else if channels.count == 2 {
            stereoOrMono = [Array(channels[0].prefix(frameCount)), Array(channels[1].prefix(frameCount))]
        } else {
            let (mid, side) = AudioSampleExtractor.midSide(channels: channels)
            let left = zip(mid, side).map { $0 + $1 }
            let right = zip(mid, side).map { $0 - $1 }
            stereoOrMono = [left, right]
        }

        guard let converter else {
            return AudioSampleExtractor.midSide(channels: stereoOrMono)
        }

        let ratio = outputSampleRate / inputSampleRate
        let outCapacity = max(16, Int(ceil(Double(frameCount) * ratio)) + 64)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(outCapacity)) else {
            return ([], [])
        }

        let channelCount = min(stereoOrMono.count, Int(inputFormat.channelCount))
        var offset = 0
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { inNumberOfPackets, outStatus in
            let remaining = frameCount - offset
            guard remaining > 0 else {
                outStatus.pointee = .noDataNow
                return nil
            }
            let chunkFrames = min(remaining, max(1, Int(inNumberOfPackets)))
            guard let chunkBuffer = AVAudioPCMBuffer(pcmFormat: self.inputFormat, frameCapacity: AVAudioFrameCount(chunkFrames)),
                  let chunkChannelData = chunkBuffer.floatChannelData
            else {
                outStatus.pointee = .noDataNow
                return nil
            }
            chunkBuffer.frameLength = AVAudioFrameCount(chunkFrames)
            for ch in 0..<channelCount {
                stereoOrMono[ch].withUnsafeBufferPointer { src in
                    guard let base = src.baseAddress else { return }
                    chunkChannelData[ch].update(from: base.advanced(by: offset), count: chunkFrames)
                }
            }
            offset += chunkFrames
            outStatus.pointee = .haveData
            return chunkBuffer
        }

        guard error == nil,
              status == .haveData || status == .inputRanDry,
              outBuffer.frameLength > 0,
              let outChannelData = outBuffer.floatChannelData
        else { return ([], []) }

        let outFrames = Int(outBuffer.frameLength)
        let outChCount = Int(outputFormat.channelCount)
        let outChannels: [[Float]] = (0..<outChCount).map { ch in
            Array(UnsafeBufferPointer(start: outChannelData[ch], count: outFrames))
        }
        return AudioSampleExtractor.midSide(channels: outChannels)
    }

    func reset() {
        converter?.reset()
    }
}

/// Callback delivered by the Core Audio IOProc (or a test double).
struct ProcessTapAudioBuffer: Sendable {
    let channels: [[Float]]
    let hostTimeNanos: UInt64?
    var startsNewSpan = false
}

/// Token representing an active Core Audio HAL property listener; releasing it removes the listener.
protocol HALListenerToken: AnyObject {}

/// Abstraction over Core Audio Process Tap & Aggregate Device HAL calls for unit testing.
protocol ProcessTapBackend: AnyObject, Sendable {
    /// Returns nil when HAL could not provide a snapshot.
    func listAudioProcesses() -> [AudioProcessSnapshot]?
    func runningApplicationBundleIDs() -> Set<String>
    func createTap(processObjectIDs: [AudioObjectID]) throws -> (tapID: AudioObjectID, tapUID: String, format: AudioStreamBasicDescription)
    func updateTap(tapID: AudioObjectID, processObjectIDs: [AudioObjectID]) throws
    func destroyTap(tapID: AudioObjectID)
    func createAggregateDevice(tapUID: String) throws -> AudioObjectID
    func destroyAggregateDevice(deviceID: AudioObjectID)
    func tapFormat(tapID: AudioObjectID) -> AudioStreamBasicDescription?
    func startIOProc(
        deviceID: AudioObjectID,
        format: AudioStreamBasicDescription,
        queue: DispatchQueue,
        onBuffer: @escaping @Sendable (ProcessTapAudioBuffer) -> Void
    ) throws -> AudioDeviceIOProcID
    func stopAndDestroyIOProc(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID)
    func addProcessListListener(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> HALListenerToken?
    func addDefaultOutputDeviceListener(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> HALListenerToken?
    func addTapFormatListener(tapID: AudioObjectID, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> HALListenerToken?
}

/// Live macOS 14.2+ Core Audio Process Tap backend.
@available(macOS 14.2, *)
final class LiveProcessTapBackend: ProcessTapBackend, @unchecked Sendable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.arya.BarTune", category: "process-tap")

    private final class CoreAudioListenerToken: HALListenerToken {
        private final class Context: @unchecked Sendable {
            private let lock = NSLock()
            private var isInvalidated = false
            let queue: DispatchQueue
            let handler: @Sendable () -> Void

            init(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
                self.queue = queue
                self.handler = handler
            }

            func invalidate() {
                lock.withLock { isInvalidated = true }
            }

            func dispatchIfActive() {
                let active = lock.withLock { !isInvalidated }
                guard active else { return }
                queue.async(execute: handler)
            }
        }

        // Use the same C function and retained context for registration and removal.
        // Passing a Swift closure to the block APIs can bridge it to a fresh block on each call.
        private static let listener: AudioObjectPropertyListenerProc = { _, _, _, clientData in
            guard let clientData else { return noErr }
            let context = Unmanaged<Context>.fromOpaque(clientData).takeUnretainedValue()
            context.dispatchIfActive()
            return noErr
        }

        private let objectID: AudioObjectID
        private let address: AudioObjectPropertyAddress
        private let retainedContext: Unmanaged<Context>

        init?(
            objectID: AudioObjectID,
            address: AudioObjectPropertyAddress,
            queue: DispatchQueue,
            handler: @escaping @Sendable () -> Void
        ) {
            let retained = Unmanaged.passRetained(Context(queue: queue, handler: handler))
            var addr = address
            let status = AudioObjectAddPropertyListener(objectID, &addr, Self.listener, retained.toOpaque())
            guard status == noErr else {
                retained.release()
                return nil
            }
            self.objectID = objectID
            self.address = addr
            self.retainedContext = retained
        }

        deinit {
            let context = retainedContext.takeUnretainedValue()
            context.invalidate()
            var addr = address
            let status = AudioObjectRemovePropertyListener(objectID, &addr, Self.listener, retainedContext.toOpaque())
            // Release the context only when HAL confirms removal or the object no longer exists.
            if status == noErr || status == OSStatus(kAudioHardwareBadObjectError) {
                retainedContext.release()
            } else {
                LiveProcessTapBackend.logger.error("Removing HAL property listener failed (OSStatus \(status)); keeping invalidated context alive")
            }
        }
    }

    func listAudioProcesses() -> [AudioProcessSnapshot]? {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let stride = MemoryLayout<AudioObjectID>.stride
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
              Int(size).isMultiple(of: stride)
        else { return nil }
        guard size > 0 else { return [] }

        var objectIDs = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        let status = objectIDs.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, base)
        }
        let count = Int(size) / stride
        guard status == noErr, Int(size).isMultiple(of: stride), count <= objectIDs.count else { return nil }
        return objectIDs.prefix(count).compactMap { objectID -> AudioProcessSnapshot? in
            let pid: pid_t = Self.readScalar(objectID, Self.address(kAudioProcessPropertyPID), fallback: 0)
            guard pid > 0 else { return nil }
            let halBundleID = Self.readCFString(objectID, Self.address(kAudioProcessPropertyBundleID))
            let resolvedBundleID = (halBundleID?.isEmpty == false)
                ? halBundleID
                : NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            let ancestors = Self.ancestorBundleIdentifiers(for: pid, halBundleID: halBundleID)
            return AudioProcessSnapshot(
                objectID: objectID,
                pid: pid,
                bundleIdentifier: resolvedBundleID,
                ancestorBundleIdentifiers: ancestors
            )
        }
    }

    func runningApplicationBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
    }

    func createTap(processObjectIDs: [AudioObjectID]) throws -> (tapID: AudioObjectID, tapUID: String, format: AudioStreamBasicDescription) {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.name = "BarTune Audio Sync Tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.isExclusive = false

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw ProcessTapCaptureError.tapCreationFailed(status)
        }

        let tapUID = Self.readCFString(tapID, Self.address(kAudioTapPropertyUID)) ?? description.uuid.uuidString
        guard let format = tapFormat(tapID: tapID) else {
            destroyTap(tapID: tapID)
            throw ProcessTapCaptureError.invalidStreamFormat
        }
        return (tapID, tapUID, format)
    }

    func updateTap(tapID: AudioObjectID, processObjectIDs: [AudioObjectID]) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.name = "BarTune Audio Sync Tap"
        if let existingUID = Self.readCFString(tapID, Self.address(kAudioTapPropertyUID)),
           let existingUUID = UUID(uuidString: existingUID) {
            description.uuid = existingUUID
        }
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.isExclusive = false

        var address = Self.address(kAudioTapPropertyDescription)
        var unmanaged: Unmanaged<CATapDescription>? = Unmanaged.passRetained(description)
        defer { unmanaged?.release() }
        let size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) { ptr in
            AudioObjectSetPropertyData(tapID, &address, 0, nil, size, ptr)
        }
        guard status == noErr else {
            throw ProcessTapCaptureError.tapCreationFailed(status)
        }
    }

    func destroyTap(tapID: AudioObjectID) {
        guard tapID != kAudioObjectUnknown else { return }
        let status = AudioHardwareDestroyProcessTap(tapID)
        if status != noErr {
            Self.logger.debug("AudioHardwareDestroyProcessTap(\(tapID)) returned \(status)")
        }
    }

    func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        let aggregateUID = "com.arya.bartune.processtap.\(UUID().uuidString)"
        let subTap: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true,
        ]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BarTune Process Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // Keep AudioDeviceStart from waiting for the tapped process to produce audio.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [subTap],
        ]

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw ProcessTapCaptureError.aggregateDeviceCreationFailed(status)
        }
        return deviceID
    }

    func destroyAggregateDevice(deviceID: AudioObjectID) {
        guard deviceID != kAudioObjectUnknown else { return }
        let status = AudioHardwareDestroyAggregateDevice(deviceID)
        if status != noErr {
            Self.logger.debug("AudioHardwareDestroyAggregateDevice(\(deviceID)) returned \(status)")
        }
    }

    func tapFormat(tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        var address = Self.address(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { return nil }
        return asbd
    }

    /// Transfers raw buffers from HAL to a serial worker through a bounded, preallocated FIFO.
    final class RawIOBufferHandoff: @unchecked Sendable {
        private final class Slot {
            let buffers: UnsafeMutableAudioBufferListPointer
            let storage: UnsafeMutableRawPointer
            var hostTimeNanos: UInt64?
            var startsNewSpan = false

            init(bufferCount: Int, bytesPerBuffer: Int) {
                buffers = AudioBufferList.allocate(maximumBuffers: bufferCount)
                storage = .allocate(byteCount: bufferCount * bytesPerBuffer, alignment: MemoryLayout<Float>.alignment)
                // Touch the pages before the HAL callback without binding the storage to a sample type.
                memset(storage, 0, bufferCount * bytesPerBuffer)
            }

            deinit {
                buffers.unsafeMutablePointer.deallocate()
                storage.deallocate()
            }
        }

        static let slotCount = 64

        private let lock: os_unfair_lock_t
        private let slots: [Slot]
        private let maxBuffers: Int
        private let bytesPerBuffer: Int
        private var readIndex = 0
        private var pendingCount = 0
        // Only the HAL IOProc writes this flag, including when it cannot acquire the FIFO lock.
        private var droppedBuffer = false
        private let format: AudioStreamBasicDescription
        private let ready: DispatchSourceUserDataAdd
        private let onBuffer: @Sendable (ProcessTapAudioBuffer) -> Void

        init(
            format: AudioStreamBasicDescription,
            maxFrames: Int,
            workerQueue: DispatchQueue,
            onBuffer: @escaping @Sendable (ProcessTapAudioBuffer) -> Void
        ) {
            self.format = format
            lock = .allocate(capacity: 1)
            lock.initialize(to: os_unfair_lock())
            maxBuffers = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 ? Int(format.mChannelsPerFrame) : 1
            let byteCount = maxFrames * Int(format.mBytesPerFrame)
            let alignment = MemoryLayout<Float>.alignment
            bytesPerBuffer = (byteCount + alignment - 1) / alignment * alignment
            slots = (0..<Self.slotCount).map { [maxBuffers, bytesPerBuffer] _ in
                Slot(bufferCount: maxBuffers, bytesPerBuffer: bytesPerBuffer)
            }
            self.onBuffer = onBuffer
            ready = DispatchSource.makeUserDataAddSource(queue: workerQueue)
            ready.setEventHandler { [weak self] in self?.drain() }
            ready.activate()
        }

        deinit {
            ready.cancel()
            lock.deinitialize(count: 1)
            lock.deallocate()
        }

        private func tryAcquireLock() -> Bool {
            for _ in 0..<8 where os_unfair_lock_trylock(lock) {
                return true
            }
            return false
        }

        func enqueue(bufferList: UnsafePointer<AudioBufferList>, inputTime: UnsafePointer<AudioTimeStamp>) {
            let startsNewSpan = droppedBuffer
            droppedBuffer = true
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            guard !buffers.isEmpty, buffers.count <= maxBuffers, tryAcquireLock() else { return }
            let slotIndex: Int? = pendingCount < slots.count
                ? (readIndex + pendingCount) % slots.count
                : nil
            os_unfair_lock_unlock(lock)
            guard let slotIndex else { return }

            let slot = slots[slotIndex]
            slot.buffers.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(buffers.count)
            for index in buffers.indices {
                var buffer = buffers[index]
                if let data = buffer.mData, buffer.mDataByteSize > 0 {
                    guard Int(buffer.mDataByteSize) <= bytesPerBuffer else { return }
                    let destination = slot.storage.advanced(by: index * bytesPerBuffer)
                    destination.copyMemory(from: data, byteCount: Int(buffer.mDataByteSize))
                    buffer.mData = destination
                } else {
                    buffer.mData = nil
                }
                slot.buffers[index] = buffer
            }

            slot.hostTimeNanos = inputTime.pointee.mFlags.contains(.hostTimeValid)
                ? AudioConvertHostTimeToNanos(inputTime.pointee.mHostTime)
                : nil
            slot.startsNewSpan = startsNewSpan

            guard tryAcquireLock() else { return }
            pendingCount += 1
            os_unfair_lock_unlock(lock)
            droppedBuffer = false
            ready.add(data: 1)
        }

        private func drain() {
            while true {
                os_unfair_lock_lock(lock)
                let slot = pendingCount > 0 ? slots[readIndex] : nil
                os_unfair_lock_unlock(lock)
                guard let slot else { break }

                let channels = StereoAudioResampler.extractChannels(from: slot.buffers.unsafePointer, asbd: format)
                let hostTimeNanos = slot.hostTimeNanos
                let startsNewSpan = slot.startsNewSpan
                // Keep the slot occupied until decoding has finished reading its bytes.
                os_unfair_lock_lock(lock)
                readIndex = (readIndex + 1) % slots.count
                pendingCount -= 1
                os_unfair_lock_unlock(lock)
                onBuffer(ProcessTapAudioBuffer(channels: channels, hostTimeNanos: hostTimeNanos, startsNewSpan: startsNewSpan))
            }
        }
    }

    func startIOProc(
        deviceID: AudioObjectID,
        format: AudioStreamBasicDescription,
        queue: DispatchQueue,
        onBuffer: @escaping @Sendable (ProcessTapAudioBuffer) -> Void
    ) throws -> AudioDeviceIOProcID {
        let frameRange = Self.readScalar(
            deviceID,
            Self.address(kAudioDevicePropertyBufferFrameSizeRange),
            fallback: AudioValueRange(mMinimum: 0, mMaximum: 4096)
        )
        guard let maxFrames = Int(exactly: frameRange.mMaximum.rounded(.up)),
              maxFrames > 0, format.mBytesPerFrame > 0
        else { throw ProcessTapCaptureError.invalidStreamFormat }

        let handoff = RawIOBufferHandoff(format: format, maxFrames: maxFrames, workerQueue: queue, onBuffer: onBuffer)
        var ioProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil) { _, inInputData, inInputTime, _, _ in
            handoff.enqueue(bufferList: inInputData, inputTime: inInputTime)
        }
        guard createStatus == noErr, let validIOProcID = ioProcID else {
            throw ProcessTapCaptureError.ioProcCreationFailed(createStatus)
        }

        let startStatus = AudioDeviceStart(deviceID, validIOProcID)
        guard startStatus == noErr else {
            _ = AudioDeviceDestroyIOProcID(deviceID, validIOProcID)
            throw ProcessTapCaptureError.deviceStartFailed(startStatus)
        }
        return validIOProcID
    }

    func stopAndDestroyIOProc(deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID) {
        _ = AudioDeviceStop(deviceID, ioProcID)
        _ = AudioDeviceDestroyIOProcID(deviceID, ioProcID)
    }

    func addProcessListListener(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> HALListenerToken? {
        CoreAudioListenerToken(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: Self.address(kAudioHardwarePropertyProcessObjectList),
            queue: queue,
            handler: handler
        )
    }

    func addDefaultOutputDeviceListener(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> HALListenerToken? {
        CoreAudioListenerToken(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: Self.address(kAudioHardwarePropertyDefaultOutputDevice),
            queue: queue,
            handler: handler
        )
    }

    func addTapFormatListener(tapID: AudioObjectID, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> HALListenerToken? {
        CoreAudioListenerToken(
            objectID: tapID,
            address: Self.address(kAudioTapPropertyFormat),
            queue: queue,
            handler: handler
        )
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func readScalar<Value>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        fallback: Value
    ) -> Value {
        var addr = address
        var value = fallback
        var size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutableBytes(of: &value) { buffer in
            guard let base = buffer.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, base)
        }
        return status == noErr ? value : fallback
    }

    private static func readCFString(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var addr = address
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let unmanaged = cfStr else { return nil }
        return unmanaged.takeRetainedValue() as String
    }

    private static func ancestorBundleIdentifiers(for pid: pid_t, halBundleID: String?, maxDepth: Int = 8) -> [String] {
        var ancestors: [String] = []
        var current = pid
        for _ in 0..<maxDepth {
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            let result = proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, infoSize)
            guard result == infoSize else { break }
            let parent = pid_t(info.pbi_ppid)
            if parent <= 1 {
                guard current == pid else { break }
                let host = ProcessTapResolver.responsibleBundleIdentifier(halBundleID: halBundleID, parentPID: parent) {
                    processArguments(for: pid)
                }
                if let host {
                    ancestors.append(host)
                }
                break
            }
            guard parent != current else { break }
            if let bundleID = NSRunningApplication(processIdentifier: parent)?.bundleIdentifier, !bundleID.isEmpty {
                ancestors.append(bundleID)
            }
            current = parent
        }
        return ancestors
    }

    /// Reads `KERN_PROCARGS2` for the eligible WebKit helper.
    private static func processArguments(for pid: pid_t) -> (arguments: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size
        else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size
        else { return nil }

        let argc: Int32 = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }

        var cursor = MemoryLayout<Int32>.size
        // Skip executable path and trailing NUL padding.
        while cursor < size, buffer[cursor] != 0 {
            cursor += 1
        }
        while cursor < size, buffer[cursor] == 0 {
            cursor += 1
        }

        var strings: [String] = []
        while cursor < size {
            let start = cursor
            while cursor < size, buffer[cursor] != 0 {
                cursor += 1
            }
            guard cursor < size else { break }
            guard let string = String(bytes: buffer[start..<cursor], encoding: .utf8) else { return nil }
            strings.append(string)
            cursor += 1
        }
        let argCount = Int(argc)
        guard argCount <= strings.count else { return nil }
        let arguments = Array(strings.prefix(argCount))
        let environment = Array(strings.dropFirst(argCount))
        return (arguments, environment)
    }
}

/// Core Audio Process Tap implementation of `AudioCaptureProviding` for macOS 14.2+.
/// Captures stereo playback audio directly from `coreaudiod` without Screen Recording permission.
@available(macOS 14.2, *)
final class ProcessTapAudioCapture: AudioCaptureProviding, @unchecked Sendable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.arya.BarTune", category: "process-tap")

    /// Each IOProc owns its resampler and batcher and uses them only on the IO queue.
    private final class BufferProcessor: @unchecked Sendable {
        private let resampler: StereoAudioResampler
        private let onAudioSamples: (@Sendable (CapturedAudio) -> Void)?
        private var batcher = AudioCaptureBatcher()
        // A new pipeline follows a capture gap (rebuild); its first delivery starts a new span.
        private var startsNewSpan = true

        init(resampler: StereoAudioResampler, onAudioSamples: (@Sendable (CapturedAudio) -> Void)?) {
            self.resampler = resampler
            self.onAudioSamples = onAudioSamples
        }

        func receive(_ buffer: ProcessTapAudioBuffer) {
            if buffer.startsNewSpan || buffer.channels.isEmpty {
                resampler.reset()
                startsNewSpan = true
            }
            guard !buffer.channels.isEmpty else { return }
            let uptimeNow = ProcessInfo.processInfo.systemUptime
            let delay = buffer.hostTimeNanos.flatMap { hostNanos -> Double? in
                let nowNanos = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
                guard hostNanos > 0, hostNanos <= nowNanos else { return nil }
                return Double(nowNanos - hostNanos) / 1_000_000_000
            }
            let capturedAt = uptimeNow - (delay ?? 0)

            let (mid, side) = resampler.process(channels: buffer.channels)
            guard !mid.isEmpty else { return }
            let captured = CapturedAudio(
                samples: mid,
                side: side,
                sampleRate: resampler.outputSampleRate,
                captureDelay: delay,
                capturedAt: capturedAt,
                startsNewSpan: startsNewSpan
            )
            startsNewSpan = false
            guard let onAudioSamples else { return }
            for batch in batcher.append(captured, deliveryUptime: uptimeNow) {
                onAudioSamples(batch)
            }
        }
    }

    private let callbackLock = NSLock()
    private var _onAudioSamples: (@Sendable (CapturedAudio) -> Void)?
    private var _onCaptureFailure: (@Sendable (Error) -> Void)?

    var onAudioSamples: (@Sendable (CapturedAudio) -> Void)? {
        get { callbackLock.withLock { _onAudioSamples } }
        set { callbackLock.withLock { _onAudioSamples = newValue } }
    }

    var onCaptureFailure: (@Sendable (Error) -> Void)? {
        get { callbackLock.withLock { _onCaptureFailure } }
        set { callbackLock.withLock { _onCaptureFailure = newValue } }
    }

    /// The control queue retains these resources through teardown, even after the capture is released.
    private final class HALResources: @unchecked Sendable {
        var processListListener: HALListenerToken?
        var defaultOutputListener: HALListenerToken?
        var tapFormatListener: HALListenerToken?
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        var tappedProcessIDs: [AudioObjectID] = []
        var pipelineGeneration: UInt64 = 0

        func teardownPipeline(backend: ProcessTapBackend) {
            pipelineGeneration &+= 1
            tapFormatListener = nil
            if let ioProcID {
                backend.stopAndDestroyIOProc(deviceID: aggregateDeviceID, ioProcID: ioProcID)
                self.ioProcID = nil
            }
            if aggregateDeviceID != kAudioObjectUnknown {
                backend.destroyAggregateDevice(deviceID: aggregateDeviceID)
                aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            }
            if tapID != kAudioObjectUnknown {
                backend.destroyTap(tapID: tapID)
                tapID = AudioObjectID(kAudioObjectUnknown)
            }
            tappedProcessIDs = []
        }

        func teardownAll(backend: ProcessTapBackend) {
            processListListener = nil
            defaultOutputListener = nil
            teardownPipeline(backend: backend)
        }
    }

    private let backend: ProcessTapBackend
    private let resources = HALResources()
    // HAL invokes the IOProc synchronously. Lifecycle calls must be free to wait for it.
    private let controlQueue = DispatchQueue(label: "com.arya.bartune.processtap.control", qos: .utility)
    private let ioQueue = DispatchQueue(label: "com.arya.bartune.processtap.io", qos: .userInitiated)
    private let rebuildDebounceSeconds: Double
    private let excludedPID: pid_t
    private var processSnapshotRetryDelay: Double { max(rebuildDebounceSeconds, 0.2) }

    // All mutable capture state below is confined to `controlQueue`.
    private var isActive = false
    private var sessionID: UInt64 = 0
    private var targetBundleIds: Set<String> = []
    private var targetSampleRate: Double = StereoAudioResampler.targetSampleRate
    private var sessionAudioHandler: (@Sendable (CapturedAudio) -> Void)?
    private var sessionFailureHandler: (@Sendable (Error) -> Void)?
    private var pendingRebuild: DispatchWorkItem?
    private var pendingProcessSnapshotRetry: DispatchWorkItem?

    init(
        backend: ProcessTapBackend = LiveProcessTapBackend(),
        rebuildDebounceSeconds: Double = 0.2,
        excludedPID: pid_t = getpid()
    ) {
        self.backend = backend
        self.rebuildDebounceSeconds = rebuildDebounceSeconds
        self.excludedPID = excludedPID
    }

    deinit {
        controlQueue.async { [resources, backend] in
            resources.teardownAll(backend: backend)
        }
    }

    @MainActor
    func start(targetBundleIds: Set<String>, sampleRate: Int = 16000) async throws {
        guard !targetBundleIds.isEmpty else {
            throw SystemAudioCaptureError.unresolvedPlayer
        }

        let resolvedRate = sampleRate > 0 ? Double(sampleRate) : StereoAudioResampler.targetSampleRate
        let (audioHandler, failureHandler) = callbackLock.withLock { (_onAudioSamples, _onCaptureFailure) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controlQueue.async {
                do {
                    try self.startOnQueue(
                        targetBundleIds: targetBundleIds,
                        targetSampleRate: resolvedRate,
                        audioHandler: audioHandler,
                        failureHandler: failureHandler
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @MainActor
    func stop() {
        controlQueue.async { [weak self] in
            self?.teardownAllOnQueue()
        }
    }

    // MARK: - Queue-confined lifecycle

    private func startOnQueue(
        targetBundleIds: Set<String>,
        targetSampleRate: Double,
        audioHandler: (@Sendable (CapturedAudio) -> Void)?,
        failureHandler: (@Sendable (Error) -> Void)?
    ) throws {
        teardownAllOnQueue()
        let currentSession = sessionID
        self.targetBundleIds = targetBundleIds
        self.targetSampleRate = targetSampleRate
        sessionAudioHandler = audioHandler
        sessionFailureHandler = failureHandler

        installSystemListenersOnQueue(session: currentSession)
        let matched = matchingProcessesOnQueue()

        do {
            if matched?.isEmpty != false {
                let normalizedTargets = Set(targetBundleIds.map { $0.lowercased() })
                guard !normalizedTargets.isDisjoint(with: backend.runningApplicationBundleIDs()) else {
                    throw SystemAudioCaptureError.unresolvedPlayer
                }
            }
            guard resources.processListListener != nil else {
                throw ProcessTapCaptureError.processListListenerUnavailable
            }
            guard resources.defaultOutputListener != nil else {
                throw ProcessTapCaptureError.routeListenerUnavailable
            }
            // A running player without a stream stays armed for the next process-list change.
            if let matched, !matched.isEmpty {
                try buildPipelineOnQueue(processObjectIDs: matched, session: currentSession)
            }
            isActive = true
            if matched == nil {
                scheduleProcessSnapshotRetryOnQueue(session: currentSession)
            }
        } catch {
            teardownAllOnQueue()
            throw error
        }
    }

    private func installSystemListenersOnQueue(session: UInt64) {
        resources.processListListener = backend.addProcessListListener(queue: controlQueue) { [weak self] in
            self?.handleProcessListChangedOnQueue(session: session)
        }
        resources.defaultOutputListener = backend.addDefaultOutputDeviceListener(queue: controlQueue) { [weak self] in
            self?.scheduleRebuildOnQueue(session: session, reason: "default-output-changed")
        }
    }

    private func buildPipelineOnQueue(processObjectIDs: [AudioObjectID], session: UInt64) throws {
        resources.teardownPipeline(backend: backend)

        let createdTap = try backend.createTap(processObjectIDs: processObjectIDs)
        resources.tapID = createdTap.tapID
        let generation = resources.pipelineGeneration

        do {
            resources.tapFormatListener = backend.addTapFormatListener(tapID: createdTap.tapID, queue: controlQueue) { [weak self] in
                guard let self, self.resources.pipelineGeneration == generation else { return }
                self.scheduleRebuildOnQueue(session: session, reason: "tap-format-changed")
            }
            guard resources.tapFormatListener != nil else {
                throw ProcessTapCaptureError.formatListenerUnavailable
            }
            guard let format = backend.tapFormat(tapID: createdTap.tapID),
                  let resampler = StereoAudioResampler(asbd: format, targetSampleRate: targetSampleRate)
            else { throw ProcessTapCaptureError.invalidStreamFormat }

            resources.aggregateDeviceID = try backend.createAggregateDevice(tapUID: createdTap.tapUID)
            let processor = BufferProcessor(resampler: resampler, onAudioSamples: sessionAudioHandler)
            resources.ioProcID = try backend.startIOProc(deviceID: resources.aggregateDeviceID, format: format, queue: ioQueue) { buffer in
                processor.receive(buffer)
            }
            resources.tappedProcessIDs = processObjectIDs
        } catch {
            resources.teardownPipeline(backend: backend)
            throw error
        }
    }

    private func matchingProcessesOnQueue() -> [AudioObjectID]? {
        guard let processes = backend.listAudioProcesses() else { return nil }
        return ProcessTapResolver.matchingProcessObjectIDs(in: processes, targetBundleIds: targetBundleIds, excludedPID: excludedPID)
    }

    private func handleProcessListChangedOnQueue(session: UInt64) {
        guard isActive, sessionID == session else { return }
        pendingProcessSnapshotRetry?.cancel()
        pendingProcessSnapshotRetry = nil
        guard let matched = matchingProcessesOnQueue() else {
            scheduleProcessSnapshotRetryOnQueue(session: session)
            return
        }
        guard matched != resources.tappedProcessIDs else { return }
        guard !matched.isEmpty else {
            resources.teardownPipeline(backend: backend)
            return
        }

        if resources.ioProcID != nil {
            do {
                try backend.updateTap(tapID: resources.tapID, processObjectIDs: matched)
                resources.tappedProcessIDs = matched
                return
            } catch {
                Self.logger.debug("Updating tap process list failed (\(error.localizedDescription)); rebuilding tap")
            }
        }

        scheduleRebuildOnQueue(session: session, reason: "process-list-changed")
    }

    private func scheduleProcessSnapshotRetryOnQueue(session: UInt64) {
        let work = DispatchWorkItem { [weak self] in
            self?.handleProcessListChangedOnQueue(session: session)
        }
        pendingProcessSnapshotRetry = work
        controlQueue.asyncAfter(deadline: .now() + processSnapshotRetryDelay, execute: work)
    }

    private func scheduleRebuildOnQueue(session: UInt64, reason: String, retryingSnapshot: Bool = false) {
        guard isActive, sessionID == session else { return }
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, self.sessionID == session else { return }
            self.pendingRebuild = nil
            guard let matched = self.matchingProcessesOnQueue() else {
                self.scheduleRebuildOnQueue(session: session, reason: reason, retryingSnapshot: true)
                return
            }
            guard !matched.isEmpty else {
                self.resources.teardownPipeline(backend: self.backend)
                return
            }
            do {
                try self.buildPipelineOnQueue(processObjectIDs: matched, session: session)
            } catch {
                Self.logger.error("Process tap rebuild (\(reason)) failed: \(error.localizedDescription)")
                let failureHandler = self.sessionFailureHandler
                self.teardownAllOnQueue()
                failureHandler?(error)
            }
        }
        pendingRebuild = work
        let delay = retryingSnapshot ? processSnapshotRetryDelay : rebuildDebounceSeconds
        if delay <= 0 {
            controlQueue.async(execute: work)
        } else {
            controlQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func teardownAllOnQueue() {
        sessionID &+= 1
        isActive = false
        pendingRebuild?.cancel()
        pendingRebuild = nil
        pendingProcessSnapshotRetry?.cancel()
        pendingProcessSnapshotRetry = nil
        targetBundleIds = []
        resources.teardownAll(backend: backend)
        sessionAudioHandler = nil
        sessionFailureHandler = nil
    }
}
