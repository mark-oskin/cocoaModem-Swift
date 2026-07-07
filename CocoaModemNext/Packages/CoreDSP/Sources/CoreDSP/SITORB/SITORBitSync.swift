//
//  SITORBitSync.swift
//  CoreDSP
//
//  Swift port of SITOR-B's bit-clock recovery / AGC stage (Sources/Swift/
//  SITOR-B/SITORBitSync.swift, itself a port of SITORBitSync.m). Sits between
//  the shared RTTY FSK matched filter (CMFSKMatchedFilter, reused as-is --
//  see CMFSKDemodulator.swift's RTTY transplant, which already ported it) and
//  MooreDecoder: takes the matched filter's 256-sample mark/space envelope
//  pair (at Fs/8), forms a mark-minus-space "sliced" signal, extracts a
//  bit-clock via a 100 Hz comb filter tuned to the envelope's squared
//  amplitude, and samples `sliced` at each clock edge to produce the
//  bit-level data stream MooreDecoder consumes.
//
//  Port notes:
//   * The original subclassed CMTappedPipe and held its own heap CMDataStream
//     (`bitStream`), overriding `-stream` to return it (Swift couldn't assign
//     the base class's @protected `data` pointer from Objective-C). This
//     Swift-native CoreDSP already exposes `data` as a plain internal stored
//     property on CMPipe (see CMPipe.swift's coordination note, and how the
//     already-ported CMFSKMixer/CMFSKMatchedFilter use it directly) -- so
//     this port writes straight into `data.pointee` instead of maintaining a
//     separate `bitStream`/`stream()` override.
//   * `SITORATCPair` (mark/space Float pair) is dropped in favor of the
//     already-ported, identically-shaped `CMATCPair` (RTTY/RTTYTypes.swift)
//     -- same fields, no need for a near-duplicate type.
//   * Dropped as dead/UI-only in the original: `atcBuffer`/`atcWaveformBuffer()`
//     (a scope tap that was never assigned anywhere), `setEqualize(_:)` and
//     `setBitSampling(fromBaudRate:)` (both literally empty `{ }` bodies in
//     the original -- SITOR-B's bit clock is fixed at 100 baud, there is no
//     equalizer), and the `#if RTTYTEST` 1.5-stop-bit test branch (RTTYTEST
//     was never defined).
//   * Wrapping arithmetic is not used in this file in the original beyond
//     plain float math, so none needed preserving here.
//

import Foundation

final class SITORBitSync: CMTappedPipe {

    //  bit-synced output samples (mark-minus-space amplitude, one per recovered bit)
    private let syncedData = UnsafeMutablePointer<Float>.allocate(capacity: 256)

    private var previousClockValue: Float = 0
    private var invert = false

    //  input delay lines (768 CMATCPair each) -- raw input and AGC-compensated
    private let inputData = UnsafeMutablePointer<CMATCPair>.allocate(capacity: 768)
    private let postAGCData = UnsafeMutablePointer<CMATCPair>.allocate(capacity: 768)

    //  ATC AGC state (postAGC)
    private var postAGCAttack: Float = 0
    private var postAGCDecay: Float = 0
    private var postAGCMarkAGC: Float = 0
    private var postAGCSpaceAGC: Float = 0

    private var bitClockFilter: UnsafeMutablePointer<CMFIR>?
    private weak var decoder: MooreDecoder?

    //  per-frame scratch buffers (256 each)
    private let sliced = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let squared = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let clockExtract = UnsafeMutablePointer<Float>.allocate(capacity: 256)

    override init() {
        super.init()

        syncedData.initialize(repeating: 0, count: 256)
        inputData.initialize(repeating: CMATCPair(), count: 768)
        postAGCData.initialize(repeating: CMATCPair(), count: 768)
        sliced.initialize(repeating: 0, count: 256)
        squared.initialize(repeating: 0, count: 256)
        clockExtract.initialize(repeating: 0, count: 256)

        //  set up bit-sync output stream
        data.pointee.array = syncedData
        data.pointee.samples = 256
        data.pointee.components = 1
        data.pointee.channels = 1

        previousClockValue = 0
        invert = false

        //  comb filter for transition at midbit, after delay through the comb filter
        bitClockFilter = CMFIRCombFilter(100.0, Float(CMFs / 8.0), 1024, 0.2)

        //  alpha^n = 1/2.71828, where n is in steps of Fs/8
        let g = Float(8.0 / CMFs)
        postAGCAttack = expf(-g / 0.0005)   //  0.5 ms attack time constant
        postAGCDecay = expf(-g / 0.120)     //  120 ms decay time constant
        postAGCMarkAGC = 0
        postAGCSpaceAGC = 0
    }

    deinit {
        if let f = bitClockFilter { CMDeleteFIR(f) }
        syncedData.deallocate()
        inputData.deallocate()
        postAGCData.deallocate()
        sliced.deallocate()
        squared.deallocate()
        clockExtract.deallocate()
    }

    func setMooreDecoder(_ decode: MooreDecoder?) {
        decoder = decode
    }

    func setInvert(_ isInvert: Bool) {
        invert = isInvert
    }

    func setSquelch(_ value: Float) {
        //  squelch threshold (value = 0.0 == maximal squelching); the Moore
        //  decoder is the actual consumer of this value.
        decoder?.setSquelch(value)
    }

    //  computed AGC compensated data (looks at "future" data to determine AGC)
    private func updateAGC() {
        let att = postAGCAttack
        let dec = postAGCDecay
        //  look ahead 22ms to compute AGC
        var din = inputData.advanced(by: 384 + 100)
        var dout = postAGCData.advanced(by: 384)
        var m = postAGCMarkAGC
        var s = postAGCSpaceAGC
        for _ in 384..<(384 + 256) {
            var v = din.pointee.mark
            m = ((v > m) ? att : dec) * (m - v) + v
            dout.pointee.mark = v - m * 0.5
            v = din.pointee.space
            s = ((v > s) ? att : dec) * (s - v) + v
            dout.pointee.space = v - s * 0.5
            din = din.advanced(by: 1)
            dout = dout.advanced(by: 1)
        }
        postAGCMarkAGC = m
        postAGCSpaceAGC = s
    }

    //  NOTE: sampling rate here is Fs/8, decimated by the matched filter, with
    //        256 samples per frame.
    //
    //  new data is stuffed into the end of a 768-sample delay line
    override func importData(_ pipe: CMPipe!) {
        guard let streamPtr = pipe.stream() else { return }
        data.pointee.sourceID = streamPtr.pointee.sourceID
        var samples = Int(streamPtr.pointee.samples)
        if samples > 256 { samples = 256 }
        guard let base = streamPtr.pointee.array else { return }

        //  invert M/S polarity here.
        var m: UnsafeMutablePointer<Float>
        var s: UnsafeMutablePointer<Float>
        if invert {
            s = base
            m = base.advanced(by: samples)
        } else {
            m = base
            s = base.advanced(by: samples)
        }

        //  copy input data into tail of buffer (split complex -> CMATCPair)
        var p = inputData.advanced(by: 512)
        for _ in 0..<256 {
            p.pointee.mark = m.pointee; m = m.advanced(by: 1)
            p.pointee.space = s.pointee; s = s.advanced(by: 1)
            p = p.advanced(by: 1)
        }

        //  gain control the input data
        updateAGC()

        var q = postAGCData
        for i in 0..<256 {
            let v = q.pointee.mark - q.pointee.space
            sliced[i] = v
            squared[i] = v * v
            q = q.advanced(by: 1)
        }

        //  LPF data to extract clock (256-length symmetrical FIR -> 128 sample delay)
        if let f = bitClockFilter {
            CMPerformFIR(f, squared, 256, clockExtract)
        }

        //  actual data is here
        var dataBits = 0
        var v = previousClockValue
        var u: Float = 0
        for i in 0..<256 {
            u = clockExtract[i]
            if v <= 0.0 && u > 0 {
                //  leading edge of clock
                syncedData[dataBits] = sliced[i]
                dataBits += 1
            }
            v = u
        }
        previousClockValue = u
        data.pointee.samples = Int32(truncatingIfNeeded: dataBits)

        //  export to decoder
        exportData()

        //  move tail to head of buffers
        let size = MemoryLayout<CMATCPair>.stride * 512
        memmove(inputData, inputData.advanced(by: 256), size)
        memmove(postAGCData, postAGCData.advanced(by: 256), size)
    }
}
