import AVFAudio
import Foundation

/// Cross-platform (macOS + iOS) audio I/O built on AVAudioEngine. Replaces the
/// old app's CoreAudio-HAL device-picker architecture entirely: no device
/// enumeration, no AudioDeviceIOProc -- AVAudioSession/AVAudioEngine own
/// routing, and on iOS that means whatever the system routes (built-in mic,
/// a USB-C audio-class interface, etc).
///
/// RX: a tap on the input node delivers mono Float buffers to the active
/// ModemEngine. TX: a source node pulls samples from the active ModemEngine
/// and plays them through the output node.
@MainActor
public final class AudioIOEngine: ObservableObject {
    public static let sampleRate: Double = CoreDSPSampleRate

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    @Published public private(set) var isRunning = false
    @Published public private(set) var lastErrorDescription: String?

    public weak var activeEngine: ModemEngine?

    public init() {}

    public func start() {
        guard !isRunning else { return }
        #if os(iOS)
        configureIOSSession()
        #endif

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        let rxFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: inputFormat.sampleRate,
                                     channels: 1,
                                     interleaved: false)!

        activeEngine?.configure(deviceSampleRate: inputFormat.sampleRate)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInput(buffer, nativeFormat: inputFormat, targetFormat: rxFormat)
        }

        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let source = AVAudioSourceNode(format: outputFormat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            self?.renderOutput(frameCount: frameCount, audioBufferList: audioBufferList, format: outputFormat) ?? noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: outputFormat)
        sourceNode = source

        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
        engine.stop()
        isRunning = false
    }

    // MARK: - RX

    private var resampleScratch = [Float](repeating: 0, count: 8192)

    private func handleInput(_ buffer: AVAudioPCMBuffer, nativeFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        // Mono-mix if the input device is stereo+.
        let channels = Int(buffer.format.channelCount)
        if resampleScratch.count < frameCount { resampleScratch = [Float](repeating: 0, count: frameCount) }
        resampleScratch.withUnsafeMutableBufferPointer { scratch in
            if channels == 1 {
                scratch.baseAddress!.update(from: channelData[0], count: frameCount)
            } else {
                for i in 0..<frameCount {
                    var sum: Float = 0
                    for c in 0..<channels { sum += channelData[c][i] }
                    scratch[i] = sum / Float(channels)
                }
            }
        }
        guard let engine = activeEngine else { return }
        resampleScratch.withUnsafeBufferPointer { ptr in
            engine.processReceiveAudio(ptr.baseAddress!, count: frameCount)
        }
    }

    // MARK: - TX

    private var txScratch = [Float](repeating: 0, count: 8192)

    private func renderOutput(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>, format: AVAudioFormat) -> OSStatus {
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let n = Int(frameCount)
        guard let engine = activeEngine else {
            for buffer in ablPointer { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            return noErr
        }
        if txScratch.count < n { txScratch = [Float](repeating: 0, count: n) }
        let produced = txScratch.withUnsafeMutableBufferPointer { scratch -> Int in
            engine.produceTransmitAudio(scratch.baseAddress!, count: n)
        }
        for i in produced..<n { txScratch[i] = 0 }

        let channels = Int(format.channelCount)
        for buffer in ablPointer {
            guard let mData = buffer.mData else { continue }
            let out = mData.assumingMemoryBound(to: Float.self)
            for i in 0..<n { out[i] = txScratch[i] }
            _ = channels
        }
        return noErr
    }

    #if os(iOS)
    private func configureIOSSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setPreferredSampleRate(Self.sampleRate)
            try session.setActive(true)
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }
    #endif
}

/// The DSP core's native sample rate (CMFs in CoreDSP). AVAudioEngine will
/// run the hardware at whatever rate it wants; each ModemEngine is
/// responsible for resampling to/from this rate internally (mirroring how
/// the original app's ResamplingPipe worked).
public let CoreDSPSampleRate: Double = 11025.0
