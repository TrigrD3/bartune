import CoreAudio
import Foundation

/// Publishes default playback route latency on the main actor.
@MainActor
final class AudioOutputLatencyMonitor {
    private let queue = DispatchQueue(label: "BarTune.output-latency", qos: .utility)
    private let readDefaultDevice: @Sendable () -> AudioDeviceID
    private var observation: OutputLatencyObservation?

    init(readDefaultDevice: @escaping @Sendable () -> AudioDeviceID = { OutputLatencyObservation.defaultOutputDevice() }) {
        self.readDefaultDevice = readDefaultDevice
    }

    deinit {
        observation?.stop()
    }

    func start(onChange: @escaping @MainActor @Sendable (Double) -> Void) {
        stop()
        let observation = OutputLatencyObservation(queue: queue, readDefaultDevice: readDefaultDevice)
        self.observation = observation
        observation.start { [weak self, weak observation] latency in
            guard let observation, self?.observation === observation else { return }
            onChange(latency)
        }
    }

    func stop() {
        observation?.stop()
        observation = nil
    }

    nonisolated static func computeLatencySeconds(
        deviceFrames: UInt32, safetyOffsetFrames: UInt32, streamFrames: UInt32, sampleRate: Double
    ) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        let totalFrames = Double(deviceFrames) + Double(safetyOffsetFrames) + Double(streamFrames)
        return min(1, totalFrames / sampleRate)
    }
}

/// All HAL calls and mutable observation state are confined to the serial queue.
private final class OutputLatencyObservation: @unchecked Sendable {
    private final class Listener {
        private let object: AudioObjectID
        private let address: AudioObjectPropertyAddress
        private let queue: DispatchQueue
        private let block: AudioObjectPropertyListenerBlock

        init?(
            object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock
        ) {
            var address = address
            guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
            self.object = object
            self.address = address
            self.queue = queue
            self.block = block
        }

        deinit {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
    }

    private static let defaultDevice = address(kAudioHardwarePropertyDefaultOutputDevice)
    private static let deviceLatency = address(kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput)
    private static let safetyOffset = address(kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeOutput)
    private static let deviceStreams = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
    private static let sampleRate = address(kAudioDevicePropertyNominalSampleRate)
    private static let streamLatency = address(kAudioStreamPropertyLatency)

    private let queue: DispatchQueue
    private let readDefaultDevice: @Sendable () -> AudioDeviceID
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var streams: [AudioStreamID] = []
    private var defaultDeviceListener: Listener?
    private var deviceListeners: [Listener] = []
    private var streamListeners: [Listener] = []
    private var onChange: (@MainActor @Sendable (Double) -> Void)?

    private lazy var listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.refresh()
    }

    init(queue: DispatchQueue, readDefaultDevice: @escaping @Sendable () -> AudioDeviceID) {
        self.queue = queue
        self.readDefaultDevice = readDefaultDevice
    }

    func start(onChange: @escaping @MainActor @Sendable (Double) -> Void) {
        queue.async {
            self.onChange = onChange
            self.defaultDeviceListener = Listener(
                object: AudioObjectID(kAudioObjectSystemObject), address: Self.defaultDevice, queue: self.queue, block: self.listenerBlock
            )
            self.refresh()
        }
    }

    func stop() {
        queue.async {
            self.onChange = nil
            self.defaultDeviceListener = nil
            self.deviceListeners = []
            self.streamListeners = []
        }
    }

    static func defaultOutputDevice() -> AudioDeviceID {
        read(AudioObjectID(kAudioObjectSystemObject), defaultDevice, fallback: AudioObjectID(kAudioObjectUnknown))
    }

    private func refresh() {
        guard let onChange else { return }
        let latency = readLatency()
        DispatchQueue.main.async { onChange(latency) }
    }

    private func readLatency() -> Double {
        let defaultDevice = readDefaultDevice()
        if defaultDevice != device {
            deviceListeners = []
            streamListeners = []
            streams = []
            device = defaultDevice
            if device != kAudioObjectUnknown {
                deviceListeners = [Self.deviceLatency, Self.safetyOffset, Self.sampleRate, Self.deviceStreams].compactMap {
                    Listener(object: device, address: $0, queue: queue, block: listenerBlock)
                }
            }
        }
        guard device != kAudioObjectUnknown else { return 0 }

        let outputStreams = Self.outputStreams(of: device)
        if outputStreams != streams {
            streamListeners = []
            streams = outputStreams
            streamListeners = streams.compactMap { Listener(object: $0, address: Self.streamLatency, queue: queue, block: listenerBlock) }
        }
        // Streams run in parallel. Use the largest stream latency for the shared display clock.
        let streamFrames = streams.map { Self.read($0, Self.streamLatency, fallback: UInt32(0)) }.max() ?? 0
        return AudioOutputLatencyMonitor.computeLatencySeconds(
            deviceFrames: Self.read(device, Self.deviceLatency, fallback: 0),
            safetyOffsetFrames: Self.read(device, Self.safetyOffset, fallback: 0),
            streamFrames: streamFrames,
            sampleRate: Self.read(device, Self.sampleRate, fallback: 0)
        )
    }

    private static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<Value>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, fallback: Value) -> Value {
        var address = address
        var value = fallback
        var size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutableBytes(of: &value) { buffer in
            guard let data = buffer.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, data)
        }
        return status == noErr ? value : fallback
    }

    private static func outputStreams(of device: AudioObjectID) -> [AudioStreamID] {
        var address = deviceStreams
        var size: UInt32 = 0
        let stride = MemoryLayout<AudioStreamID>.stride
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              Int(size) >= stride else { return [] }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / stride)
        let status = streams.withUnsafeMutableBufferPointer { buffer in
            guard let data = buffer.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, data)
        }
        return status == noErr ? Array(streams.prefix(Int(size) / stride)) : []
    }
}
