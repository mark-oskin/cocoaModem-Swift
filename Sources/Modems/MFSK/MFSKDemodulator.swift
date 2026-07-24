//
//  MFSKDemodulator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 4/30/06.
//  Swift port of MFSKDemodulator.m.
//
//  Base class of the MFSK16 / DominoEX demodulator tree.  This is DSP code
//  (ring buffers, FFTs, FIR combs, float->int truncation, unsigned bit
//  registers), so the port mirrors C numeric semantics exactly:
//    - C fixed arrays that are handed to the CoreFilter/vDSP C functions are
//      UnsafeMutablePointer buffers of the exact original size, freed in deinit.
//    - Ring-buffer indices are masked/mod'd exactly as the C does.
//    - Float->int conversions use a guarded truncation (mfskTruncInt) that
//      mirrors C truncation toward zero (NaN->0, clamped) instead of trapping.
//    - The unsigned bit register uses wrapping operators (&*, &<<) where C
//      relied on silent overflow.
//

import Cocoa
import Accelerate

//  MFSKFREQOFFSET: pixels to the nominal first bin (was a #define in
//  MFSKDemodulator.h; other ObjC importers still get it from that header).
let MFSKFREQOFFSET: Int32 = 56

//  QuadBits (float bit[4]; bit[0]=MSB, bit[3]=LSB) is declared once at module
//  scope in MFSKModulator.swift (the ObjC QuadBits in MFSKFEC.h is not bridged).
//  We reuse that Swift value type here rather than redeclaring it.

//  Guarded float->Int32 truncation toward zero (mirrors C assignment of a
//  floating result to an int; C never traps on out-of-range / NaN).
@inline(__always)
func mfskTruncInt(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    let t = x.rounded(.towardZero)
    if t >= 2147483647.0 { return Int32.max }
    if t <= -2147483648.0 { return Int32.min }
    return Int32(t)
}

@objc(MFSKDemodulator)
class MFSKDemodulator: NSObject {

    //  ---- externally referenced by subclasses: internal ----
    var modem: MFSK?
    var m: Int32 = 16                        //  "m" for mFSK (16 for MFSK16, 18 for DominoEX)

    //  GUI
    var freqIndicator: MFSKIndicator?
    var freqLabel: MFSKIndicatorLabel?

    //  clock extraction (from input data) -- double ring buffers (1024 actual samples)
    var iTime: UnsafeMutablePointer<Float>
    var qTime: UnsafeMutablePointer<Float>
    var timeAperture: UnsafeMutablePointer<Float>   //  64: half-rate DominoEX needs all 64, MFSK16 / full-rate DominoEX need 32
    var ringIndex: Int32 = 0
    var timeOffset: Int32 = 0
    var prevClock: Float = 0
    var clockExtractionCycles: Int32 = 0
    var clockExtractFFT: UnsafeMutablePointer<CMFFT>!
    var clockExtractFilter: UnsafeMutablePointer<CMFIR>!
    var clockExtractKernel = [Float](repeating: 0, count: 768)

    //  AFC
    var afcFFT: UnsafeMutablePointer<CMFFT>!
    private var freqOffset: Float = 0
    private var dFreqOffset: Float = 0
    var absoluteOffset: Int32 = 0
    var correction: Float = 0
    var smoothedVector = [Float](repeating: 0, count: 24)
    //  bufferedFreqBins: FreqBins bufferedFreqBins[256], FreqBins = { float bin[24] }.
    //  Flattened to a single contiguous Float buffer so a pointer into a row can
    //  be handed to -decodeBins: exactly as the C did (&bufferedFreqBins[c].bin[lowest]).
    var bufferedFreqBins: UnsafeMutablePointer<Float>   //  256 * 24

    //  states
    var hasSync: Bool = false
    var softDecode: Bool = false
    private var sidebandState: Bool = false             //  NO = LSB
    var afcState: Int32 = 0
    var lowestAFCBin: Int32 = 0

    //  Data Pipeline (threaded)
    var bufferedFreqProducer: Int32 = 0
    var bufferedFreqConsumer: Int32 = 0

    //  deinterleaver
    var interleaverIndex: Int32 = 0
    var interleaverStages: Int32 = 0
    var interleaverRegister = [Float](repeating: 0, count: 160)

    //  convolutional decoder
    var fec: ConvolutionCode!
    var decodedBits: UInt32 = 0
    var decodeLag: Int32 = 0
    var varicode: MFSKVaricode!
    var useFEC: Bool = true

    //  CRLF detection
    var previousChar: Int32 = 0

    var squelchThreshold: Float = 0
    var cnr: Float = 0
    var delayedCNR = [Float](repeating: 0, count: 64)
    var cnrCycle: Int32 = 0

    //  v0.73 import data into a pipe (decodeThread:)
    private var decodePipe: DataPipe!

    override init() {
        //  Allocate C ring/aperture/kernel buffers (were inline C-array ivars).
        iTime = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
        iTime.initialize(repeating: 0, count: 2048)
        qTime = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
        qTime.initialize(repeating: 0, count: 2048)
        timeAperture = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        timeAperture.initialize(repeating: 0, count: 64)
        bufferedFreqBins = UnsafeMutablePointer<Float>.allocate(capacity: 256 * 24)
        bufferedFreqBins.initialize(repeating: 0, count: 256 * 24)

        super.init()

        modem = nil
        m = 16                              //  16 for MFSK16, 18 for DominoEX
        useFEC = true
        interleaverStages = 10              //  10 for MFSK16, 4 default interleaver stages for DominoEX

        //  set up data pipeline (256 frames) and start decode thread
        decodePipe = DataPipe(capacity: Int32(MemoryLayout<Float>.size * 64 * 256))
        Thread.detachNewThreadSelector(#selector(decodeThread(_:)), toTarget: self, with: self)

        //  carrier to noise estimate and delay line
        cnr = 30.0
        for i in 0..<64 { delayedCNR[i] = 30.0 }
        cnrCycle = 0
        squelchThreshold = 1.5

        //  convolutional and varicode decoders
        decodeLag = 45
        fec = ConvolutionCode(constraintLength: 7, generator: 0x6d, generatorB: 0x4f)
        fec.setTrellisDepth(decodeLag)
        varicode = MFSKVaricode()
        decodedBits = 0
        previousChar = 0

        //  demodulator
        afcFFT = FFTForward(9, false /*window*/)
        freqIndicator = nil
        freqLabel = nil
        softDecode = true
        afcState = 1
        lowestAFCBin = 4
        freqOffset = 0.0
        dFreqOffset = 0.1
        sidebandState = true                //  usb (high RF = high audio)
        newFreqAlignment()
    }

    deinit {
        //  MRC dealloc -> deinit.  The original had no -dealloc: the CMFFT/CMFIR
        //  objects (afcFFT/clockExtractFFT/clockExtractFilter) were never freed,
        //  so we deliberately do not free them either (the demodulator lives for
        //  the app's lifetime).  We must free the C buffers we allocated here.
        iTime.deallocate()
        qTime.deallocate()
        timeAperture.deallocate()
        bufferedFreqBins.deallocate()
    }

    @objc(useFEC) func isUsingFEC() -> DarwinBoolean {
        return DarwinBoolean(useFEC)
    }

    @objc(setUseFEC:) func setUseFEC(_ state: DarwinBoolean) {
        //  Implemented in DominoDemodulator; MFSK16 always has FEC on
    }

    @objc(setInterleaverStages:) func setInterleaverStages(_ stages: Int32) {
        var s = stages
        if s < 4 { s = 4 } else if s > 10 { s = 10 }
        interleaverStages = s
    }

    @objc(setFreqIndicator:label:) func setFreqIndicator(_ indicator: MFSKIndicator?, label: MFSKIndicatorLabel?) {
        freqIndicator = indicator
        freqLabel = label
    }

    @objc(setModem:) func setModem(_ client: MFSK?) {
        modem = client
    }

    //  YES = USB (high RF = high audio)
    @objc(setSidebandState:) func setSidebandState(_ state: DarwinBoolean) {
        sidebandState = state.boolValue
    }

    private func resetFEC() {
        fec.resetTrellis()
        //  clear the bin averaging (for detecting lowest and highest frequency bins)
        for i in 0..<24 { smoothedVector[i] = 0 }
        //  choose 11 cycle comb for clock extraction filter
        setClockExtraction(11)
    }

    @objc(resetDemodulatorState) func resetDemodulatorState() {
        //  reset deinterleaver
        interleaverIndex = 0
        for i in 0..<160 { interleaverRegister[i] = 0 }

        timeAperture.update(repeating: 0, count: 64)
        iTime.update(repeating: 0, count: 2048)
        qTime.update(repeating: 0, count: 2048)
        ringIndex = 0
        //  Original fed an *uninitialized* float dummy[32] into the FIR to prime
        //  its delay line; that is C undefined behaviour.  We feed zeros (the
        //  only deterministic choice) which flushes the comb's delay line.
        let dummy = UnsafeMutablePointer<Float>.allocate(capacity: 32)
        dummy.initialize(repeating: 0, count: 32)
        defer { dummy.deallocate() }
        for _ in 0..<32 { CMPerformFIR(clockExtractFilter, dummy, 32, iTime) }

        resetFEC()
        hasSync = false
    }

    //  Once frequency is properly aligned, the lowerBound will point at the lowest tone and the upperBound will be lowerBound+15.
    @objc(newFreqAlignment) func newFreqAlignment() {
        //  start with a frequency offset of center of a bin that is 4 full bins into the 32 bin FFT
        //  this allows us to pull 24 bins out of the data and allow a drift of up of (+,-)4 bins (62.5 Hz)
        absoluteOffset = 3 * 16 + 8
        correction = 0.0
        bufferedFreqProducer = 0
        bufferedFreqConsumer = 0
    }

    //  set the length of the clock extraction kernel.
    //  1 <= cycles <= clockExtractionCycles
    //  use 5 cycles for acquisition, then switch to 11 then to 15 cycles once locked
    @objc(setClockExtraction:) func setClockExtraction(_ cycles: Int32) {
        var c = cycles
        if c > clockExtractionCycles { c = clockExtractionCycles }

        var i = 0
        let limit = Int((15 - c) * 32)
        while i < limit { clockExtractKernel[i] = 0; i += 1 }
        while i < 480 { clockExtractFilter.pointee.kernel[i] = clockExtractKernel[i]; i += 1 }
    }

    //  new buffer of 32 complex samples arrived, sampled at 500 samples/second
    //  (each symbol clock is 32 samples from one another).  A 32 point FFT is
    //  performed to find the symbol boundary; -newBuffer:: finds the time
    //  alignment and -afcVector: finds the frequency alignment.
    func newBufferedData(_ iBuf: UnsafeMutablePointer<Float>, imag qBuf: UnsafeMutablePointer<Float>) {
        if iBuf[0] == 0 && qBuf[0] == 0 { return }

        let iSpec = UnsafeMutablePointer<Float>.allocate(capacity: 32)
        let qSpec = UnsafeMutablePointer<Float>.allocate(capacity: 32)
        let track = UnsafeMutablePointer<Float>.allocate(capacity: 32)
        defer { iSpec.deallocate(); qSpec.deallocate(); track.deallocate() }
        var timeVector = [Float](repeating: 0, count: 32)
        var input = DSPSplitComplex(realp: iTime, imagp: qTime)
        var output = DSPSplitComplex(realp: iSpec, imagp: qSpec)

        //  copy the next 32 samples into the double ring buffer
        var ring = Int(ringIndex) % 1024
        (iTime + ring).update(from: iBuf, count: 32)
        (iTime + ring + 1024).update(from: iBuf, count: 32)
        (qTime + ring).update(from: qBuf, count: 32)
        (qTime + ring + 1024).update(from: qBuf, count: 32)
        ring = (ring + 32) % 1024
        ringIndex = Int32(ring)

        //  Find approx time peak by sliding a 32-point time window and taking a 32-point FFT for each window.
        var maxv: Float = 0
        for k in 0..<32 {
            let index = (ring + (1024 - 96)) % 1024
            input.realp = iTime + (k + index)
            input.imagp = qTime + (k + index)
            output.realp = iSpec
            output.imagp = qSpec
            //  32 point FFT
            CMPerformComplexFFT(clockExtractFFT, &input, &output)

            var mean: Float = 0
            for i in 0..<32 {
                let v = iSpec[i] * iSpec[i] + qSpec[i] * qSpec[i]
                mean += v * v
            }
            //  time vector
            timeVector[k] = mean
            if mean > maxv { maxv = mean }
        }
        if maxv < 0.0001 { return }

        //  average normalized vector into denoised timeAperture
        maxv = 1.0 / maxv
        for k in 0..<32 { timeAperture[k] = timeAperture[k] * 0.94 + timeVector[k] * maxv }

        //  apply the (running) lowpassed comb to find the symbol alignment
        CMPerformFIR(clockExtractFilter, timeAperture, 32, track)

        //  Find the zero crossing from the 32 filtered symbol transitions.
        for i in 0..<32 {
            //  look for a zero crossing and then apply offset to the peak (assume cycle of 32)
            if prevClock <= 0 && track[i] > 0 {
                let dt = i
                var index = (ring + dt + (1024 - 256 + 24)) % 1024   //  offset derived from optimizing DominoEX 11 at -10.5 dB SNR
                if abs(prevClock) < track[dt] * 1.5 { index -= 1 }     //  v0.73 pick the closer sample to zero crossing
                timeOffset = Int32(dt)
                input.realp = iTime + index
                input.imagp = qTime + index
                afcVector(&input, length: 32)
            }
            prevClock = track[i]
        }
    }

    //  (Thread) the actual decode/print is done from this thread so as not to back up earlier stages
    @objc func decodeThread(_ client: Any?) {
        let packed = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        packed.initialize(repeating: 0, count: 64)
        while true {
            autoreleasepool {
                _ = decodePipe.readData(packed, length: Int32(MemoryLayout<Float>.size * 32 * 2))
                newBufferedData(packed, imag: packed + 32)
            }
        }
    }

    //  v0.73 add a pipeline before processing the vector
    @objc(newBuffer:imag:) func newBuffer(_ iBuf: UnsafeMutablePointer<Float>, imag qBuf: UnsafeMutablePointer<Float>) {
        let packed = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        defer { packed.deallocate() }
        let q = packed + 32
        for i in 0..<32 {
            packed[i] = iBuf[i]
            q[i] = qBuf[i]
        }
        _ = decodePipe.write(packed, length: Int32(MemoryLayout<Float>.size * 32 * 2))
    }

    @objc(updateRxFreqField:) func updateRxFreqField(_ binoffset: Int32) {
        if binoffset != 0 {
            modem?.applyRxFreqOffset(Float(Double(absoluteOffset + (binoffset * 16) - 128) * 0.976))
        }
    }

    @objc(updateRxFreqLabelAndField:) func updateRxFreqLabelAndField(_ binoffset: Int32) {
        let offset: Int32 = (binoffset == 0) ? 0 : (absoluteOffset - MFSKFREQOFFSET + (binoffset * 16))
        freqLabel?.setOffset(offset)
        if binoffset != 0 {
            //  each bin equivalent to 500/512 Hz = 0.976 Hz; when tuned the total
            //  offset is 128 FFT bins away (absoluteOffset + binOffset*16 = 128)
            modem?.applyRxFreqOffset(Float(Double(absoluteOffset + (binoffset * 16) - 128) * 0.976))
        }
    }

    func afcVector(_ vector: UnsafeMutablePointer<DSPSplitComplex>, length: Int32) {
        //  override by implementation
    }

    func softEncode(_ vector: UnsafeMutablePointer<Float>) -> QuadBits {
        //  override by implementation
        return QuadBits()
    }

    //  v0.73
    @objc(waterfallClicked) func waterfallClicked() {
        resetDemodulatorState()
    }

    @objc(setTrellisDepth:) func setTrellisDepth(_ depth: Int32) {
        decodeLag = depth
        fec.setTrellisDepth(depth)
    }

    @objc(setSoftDecodeState:) func setSoftDecodeState(_ state: DarwinBoolean) {
        softDecode = state.boolValue
    }

    @objc(setAFCState:) func setAFCState(_ state: Int32) {
        afcState = state
    }

    @objc(setSquelchThreshold:) func setSquelchThreshold(_ value: Float) {
        squelchThreshold = value
    }

    //  ------- FEC -------

    //  Receives the next 4 bits of data (decoded from a gray code of one of the
    //  16 tone offsets); deinterleaving is done here.
    func decodeBits(_ quad: QuadBits) {
        //  deinterleave the soft quad, and send as dibits to the convolutional decoder
        let q = deinterleave(quad)
        convolutionDecodeMSB(q.bit[0], lsb: q.bit[1])   //  decode first two bits
        convolutionDecodeMSB(q.bit[2], lsb: q.bit[3])   //  decode next two bits
    }

    //  Use the convolutional decoder to decode the next soft dibit and send to Varicode decode
    func convolutionDecodeMSB(_ msb: Float, lsb: Float) {
        varicodeDecode(fec.decodeMSB(msb, lsb: lsb))
    }

    //  Accumulate bits into the bit register; when the end-of-character signature
    //  is seen, flush the accumulated bits to the Varicode decoder.
    func varicodeDecode(_ bit: Int32) {
        decodedBits = (decodedBits &* 2) | UInt32(bit & 1)

        let c0 = Int32(decodedBits & 0x7)
        if c0 == 0x1 {
            //  001 received.  00 is the stop bits of a code word and 1 is the start bit of the new code.
            let c = varicode.decode(Int32(decodedBits >> 1))
            if c > 0, modem != nil {
                if previousChar != 0x0d || c != 0x0a {          //  '\r' / '\n'
                    var cc = c
                    if c == 0x0d { cc = 0x0a }                   //  v0.73
                    if cnr > squelchThreshold { modem?.displayCharacter(cc) }
                }
                previousChar = c
            }
            //  retain only the most recent non-zero bit
            decodedBits = 1
        }
    }

    //  override this in MFSK16 and DominoEX classes
    func deinterleave(_ p: QuadBits) -> QuadBits {
        return p
    }
}
