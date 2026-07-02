//
//  SITORBitSync.swift
//  CoreModem 2.0
//
//  Created by Kok Chen on 2/7/06
//
//  Swift port of SITORBitSync.m.  SITORBitSync remains a subclass of the
//  Objective-C DSP pipe base CMTappedPipe (CMTappedPipe stays Objective-C; its
//  header is in the bridging header).
//
//  Obtain bit clock and feed the bits to the Moore decoder.
//
//  Note: the base CMPipe's @protected `data` pointer cannot be assigned from a
//  Swift subclass, so instead of `data = &bitStream` we override -stream to
//  return our own CMDataStream.  All sample buffers are C memory
//  (malloc'd equivalent) held in UnsafeMutablePointers and freed in deinit.
//

import Cocoa

//  local split-complex mark/space sample pair (mirror of the C ATCPair in
//  SITORBitSync.h -- kept private; no Objective-C importer needs it)
private struct SITORATCPair {
    var mark: Float = 0
    var space: Float = 0
}

@objc(SITORBitSync)
class SITORBitSync: CMTappedPipe {

    //  generated bit-synced data stream (returned by -stream)
    private let bitStream: UnsafeMutablePointer<CMDataStream>
    private let syncedData: UnsafeMutablePointer<Float>    //  256

    private var previousClockValue: Float = 0
    private var invert = false

    //  input delay lines (768 SITORATCPair each) -- input and AGC-compensated
    private let inputData: UnsafeMutablePointer<SITORATCPair>   //  768
    private let postAGCData: UnsafeMutablePointer<SITORATCPair> //  768

    //  ATC AGC state (postAGC)
    private var postAGCAttack: Float = 0
    private var postAGCDecay: Float = 0
    private var postAGCMarkAGC: Float = 0
    private var postAGCSpaceAGC: Float = 0

    private var bitClockFilter: UnsafeMutablePointer<CMFIR>?
    private weak var decoder: MooreDecoder?

    //  scope tap (never assigned in the original; always nil)
    private var atcBuffer: CMPipe?

    //  per-frame scratch buffers (256 each)
    private let sliced: UnsafeMutablePointer<Float>
    private let squared: UnsafeMutablePointer<Float>
    private let clockExtract: UnsafeMutablePointer<Float>

    @objc override init() {
        bitStream = UnsafeMutablePointer<CMDataStream>.allocate(capacity: 1)
        syncedData = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        inputData = UnsafeMutablePointer<SITORATCPair>.allocate(capacity: 768)
        postAGCData = UnsafeMutablePointer<SITORATCPair>.allocate(capacity: 768)
        sliced = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        squared = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        clockExtract = UnsafeMutablePointer<Float>.allocate(capacity: 256)

        syncedData.initialize(repeating: 0, count: 256)
        inputData.initialize(repeating: SITORATCPair(), count: 768)
        postAGCData.initialize(repeating: SITORATCPair(), count: 768)
        sliced.initialize(repeating: 0, count: 256)
        squared.initialize(repeating: 0, count: 256)
        clockExtract.initialize(repeating: 0, count: 256)

        super.init()

        //  set up bitsync type DataStream
        bitStream.pointee = CMDataStream()
        bitStream.pointee.array = syncedData
        bitStream.pointee.samples = 256
        bitStream.pointee.components = 1
        bitStream.pointee.channels = 1

        previousClockValue = 0
        invert = false
        decoder = nil

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
        bitStream.deallocate()
        syncedData.deallocate()
        inputData.deallocate()
        postAGCData.deallocate()
        sliced.deallocate()
        squared.deallocate()
        clockExtract.deallocate()
    }

    //  return our own data stream rather than the base @protected `data`
    override func stream() -> UnsafeMutablePointer<CMDataStream>! {
        return bitStream
    }

    @objc(setMooreDecoder:)
    func setMooreDecoder(_ decode: MooreDecoder?) {
        decoder = decode
    }

    @objc func atcWaveformBuffer() -> CMPipe? {
        return atcBuffer
    }

    @objc(setBitSamplingFromBaudRate:)
    func setBitSampling(fromBaudRate baudrate: Float) {
    }

    @objc(setEqualize:)
    func setEqualize(_ mode: Int32) {
        //  no equalizer in SITOR reader
    }

    @objc(setInvert:)
    func setInvert(_ isInvert: DarwinBoolean) {
        invert = isInvert.boolValue
    }

    @objc(setSquelch:)
    func setSquelch(_ value: Float) {
        //  squelch threshold (value = 0.0 == maximal squelching)
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
        bitStream.pointee.sourceID = streamPtr.pointee.sourceID
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

        //  copy input data into tail of buffer (split complex -> SITORATCPair)
        var p = inputData.advanced(by: 512)
        for _ in 0..<256 {
            p.pointee.mark = m.pointee; m = m.advanced(by: 1)
            p.pointee.space = s.pointee; s = s.advanced(by: 1)
            p = p.advanced(by: 1)
        }

        //  gain control the input data
        updateAGC()

        //  (RTTYTEST-gated 1.5 stop-bit test code is omitted; RTTYTEST is undefined)

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
        bitStream.pointee.samples = Int32(truncatingIfNeeded: dataBits)

        //  export to decoder
        exportData()

        //  move tail to head of buffers
        let size = MemoryLayout<SITORATCPair>.stride * 512
        memmove(inputData, inputData.advanced(by: 256), size)
        memmove(postAGCData, postAGCData.advanced(by: 256), size)
    }
}
