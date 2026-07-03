//
//  CMPSKDemodulator.swift
//  CoreModem
//
//  Created by Kok Chen on 11/3/05.
//
//  Swift port of CMPSKDemodulator.m.  DSP-critical: exact decimation / FFT /
//  Goertzel / AGC arithmetic and buffer sizes are preserved.  C analytic
//  buffers, FIR/FFT setups and large ring/click buffers stay as
//  UnsafeMutablePointer allocations freed in deinit.  Base ivars from
//  CMToneReceiver (vco, receiveFrequency, receiverEnabled, frequencyLocked,
//  acquire) are accessed by their original names.
//

import Cocoa

private let kBPSK31: Int32 = 0
private let kBPSK63: Int32 = 1
private let kQPSK31: Int32 = 2
import Accelerate

@objc(CMPSKDemodulator)
class CMPSKDemodulator: CMToneReceiver {

    //  ---- ivars (exact original names) ----
    @objc var delegate: AnyObject?              //  -delegate / -setDelegate:

    //  decimation filters
    internal var decimatedLength: Int32 = 0
    internal var decimatedOffset: Int32 = 0
    internal var decimatedBuffer: UnsafeMutablePointer<CMAnalyticBuffer>!
    internal var decimate: UnsafeMutablePointer<CMComplexFIR>!
    internal var decimate31: UnsafeMutablePointer<CMComplexFIR>!
    internal var decimate63: UnsafeMutablePointer<CMComplexFIR>!
    //  psk31 filters
    internal var comb: UnsafeMutablePointer<CMFIR>!
    internal var dataFilterI: UnsafeMutablePointer<CMFIR>!
    internal var dataFilterQ: UnsafeMutablePointer<CMFIR>!
    internal var imdFilterI: UnsafeMutablePointer<CMFIR>!
    internal var imdFilterQ: UnsafeMutablePointer<CMFIR>!
    //  data matched filter
    internal var pskMatchedFilter: CMPSKMatchedFilter!
    //  varicode decoder
    internal var varicode: CMVaricode!

    internal var baseI = [Float](repeating: 0, count: 65)
    internal var baseQ = [Float](repeating: 0, count: 65)
    internal var bitClock = [Float](repeating: 0, count: 65)
    internal var input: UnsafeMutablePointer<CMAnalyticBuffer>!
    internal var spec: UnsafeMutablePointer<CMAnalyticBuffer>!

    internal var fft: UnsafeMutablePointer<CMFFT>!
    internal var imdFFT: UnsafeMutablePointer<CMFFT>!
    internal var acquisitionFilter: Float = 0
    internal var printEnabled: Bool = false

    internal let clickBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 0x20000)
    internal var clickBufferProducer: Int32 = 0
    internal var clickBufferConsumer: Int32 = 0

    internal var lastAng: Float = 0
    internal var phaseLoop: Float = 0
    internal var cycle: Int32 = 0
    internal var pskMode: Int32 = 0
    internal var mux: Int32 = 0
    internal var varicodeCharacter: Int32 = 0

    //  IMD
    internal var imdBufferPointer: Int32 = 0
    internal var lastIMD: Float = 0
    internal let imdBufferI = UnsafeMutablePointer<Float>.allocate(capacity: 288)
    internal let imdBufferQ = UnsafeMutablePointer<Float>.allocate(capacity: 288)
    internal let imdSpectrum = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    internal var hasIMD: Bool = false
    internal var lastBit: Bool = false

    @objc override init() {
        super.init()

        delegate = nil
        //  set up vco
        vco.setDelegate(self)
        vco.setOutputScale(8.0)

        for i in 0..<65 { baseI[i] = 0; baseQ[i] = 0; bitClock[i] = 0 }
        for i in 0..<256 { imdSpectrum[i] = -1.0 }

        //  matched filter
        pskMatchedFilter = CMPSKMatchedFilter()
        pskMatchedFilter.setDelegate(self)

        //  decimation lowpass filters for baseband analytic signal
        decimate = CMComplexFIRDecimateWithCutoff(16, 300.0, Float(CMFs), 256)
        decimate31 = decimate
        //  decimation lowpass filters for PSK63 baseband analytic signal
        decimate63 = CMComplexFIRDecimateWithCutoff(8, 300.0, Float(CMFs), 256)

        //  32 Hz data filter with Fs/16 sampling rate
        dataFilterI = CMFIRLowpassFilter(32, Float(CMFs) / 16, 256)
        dataFilterQ = CMFIRLowpassFilter(32, Float(CMFs) / 16, 256)
        //  150 Hz filter to estimate IMD (must have same length as above)
        imdFilterI = CMFIRLowpassFilter(150, Float(CMFs) / 16, 256)
        imdFilterQ = CMFIRLowpassFilter(150, Float(CMFs) / 16, 256)

        //  comb filter with phase to generate a -ve to +ve zero crossing at data mid-bit
        comb = CMFIRCombFilter(31.25, Float(CMFs) / 16, 1024, 1.5708)

        //  varicode decoder
        varicode = CMVaricode()

        mux = 0
        pskMode = Int32(kBPSK31)
        decimatedLength = 32
        decimatedOffset = 512 - decimatedLength
        phaseLoop = 0.0
        lastAng = 0.0
        imdBufferPointer = 0
        lastBit = false
        lastIMD = 123.0
        cycle = 0
        varicodeCharacter = 0
        frequencyLocked = false
        printEnabled = false
        clickBufferProducer = 0
        clickBufferConsumer = 0

        //  create aligned memory
        input = CMMallocAnalyticBuffer(16)
        decimatedBuffer = CMMallocAnalyticBuffer(512)
        spec = CMMallocAnalyticBuffer(512)

        fft = FFTForward(9, true)
        imdFFT = FFTForward(8, true)
    }

    deinit {
        clickBuffer.deallocate()
        imdBufferI.deallocate()
        imdBufferQ.deallocate()
        imdSpectrum.deallocate()
    }

    /* local */
    //  called from importData
    //  0.17 - use FFT to estimate IMD
    func importBuffer(_ array: UnsafeMutablePointer<Float>) {
        var u: Float, v: Float, pi: Float, pq: Float, sum: Float, diff: Float
        var mag: Float, angle: Float, dAngle: Float, imdi: Float, imdq: Float
        var f0: Float, f1: Float, fN: Float
        var iptr: UnsafeMutablePointer<Float>, qptr: UnsafeMutablePointer<Float>
        var snr: Float, imd: Float
        var pair: CMAnalyticPair
        var sinput = DSPSplitComplex(realp: spec.pointee.re, imagp: spec.pointee.im)
        var output = DSPSplitComplex(realp: spec.pointee.re, imagp: spec.pointee.im)
        var newBit: Bool, currentBit: Bool
        var i: Int, j: Int, n: Int
        let samples: Int = Int(decimatedLength)
        var peak: Int

        //  move old decimation data over
        CMShiftAnalyticBuffer(decimatedBuffer, Int32(samples))

        //  decimate and process the 512 original input samples
        iptr = decimatedBuffer.pointee.re + Int(decimatedOffset)
        qptr = decimatedBuffer.pointee.im + Int(decimatedOffset)

        for nn in 0..<samples {
            n = nn
            if samples == 32 {
                j = n * 16
                //  mix down to baseband I and Q
                for ii in 0..<16 {
                    v = array[ii + j]
                    //  note: the VCO runs at a rate of Fs
                    pair = vco.nextVCOMixedPair(v)
                    input.pointee.re[ii] = pair.re
                    input.pointee.im[ii] = pair.im
                }
            } else {
                j = n * 8
                for ii in 0..<8 {
                    v = array[ii + j]
                    pair = vco.nextVCOMixedPair(v)
                    input.pointee.re[ii] = pair.re
                    input.pointee.im[ii] = pair.im
                }
            }
            pair = CMDecimateAnalyticBuffer(decimate, input, 0)
            iptr[n] = pair.re
            qptr[n] = pair.im
        }

        //  process decimated data
        iptr = decimatedBuffer.pointee.re + Int(decimatedOffset)
        qptr = decimatedBuffer.pointee.im + Int(decimatedOffset)
        baseI[0] = baseI[samples]
        baseQ[0] = baseQ[samples]
        bitClock[0] = bitClock[samples]

        for nn in 0..<samples {
            n = nn

            //  data filter
            pi = CMSimpleFilter(dataFilterI, iptr[n]); baseI[n + 1] = pi
            pq = CMSimpleFilter(dataFilterQ, qptr[n]); baseQ[n + 1] = pq
            mag = pi * pi + pq * pq + 0.00001
            bitClock[n + 1] = CMSimpleFilter(comb, mag)

            imdi = CMSimpleFilter(imdFilterI, iptr[n])
            imdq = CMSimpleFilter(imdFilterQ, qptr[n])

            if imdBufferPointer >= 0 && imdBufferPointer < 288 {
                imdBufferI[Int(imdBufferPointer)] = imdi
                imdBufferQ[Int(imdBufferPointer)] = imdq
                imdBufferPointer += 1
            }

            if frequencyLocked {
                if bitClock[n] < 0 && bitClock[n + 1] >= 0 {
                    if afcEnabled() {
                        // AFC at midbit
                        if abs(pi) < 0.001 && abs(pq) < 0.001 { angle = 0.0 }
                        else if abs(pi) < abs(pq) { angle = -atan(pi / pq) }
                        else { angle = atan(pq / pi) }
                        if lastAng != 0 && lastAng * angle > 0 {
                            if cycle == 0 {
                                phaseLoop = phaseLoop * 0.99 + (angle - lastAng) * 0.01 * 0.05
                                dAngle = phaseLoop
                                vco.tune(dAngle)
                            }
                        }
                        lastAng = angle
                        //  afc track only every 2 cycles
                        cycle += 1
                        if cycle > 2 { cycle = 0 }
                    }
                }
                //  edge of data bit
                newBit = (bitClock[n] > 0 && bitClock[n + 1] <= 0)
                if pskMode == Int32(kBPSK31) || pskMode == Int32(kBPSK63) {
                    currentBit = pskMatchedFilter.bpsk(pi, imag: pq, bitPhase: newBit) != 0
                } else {
                    currentBit = pskMatchedFilter.qpsk(pi, imag: pq, bitPhase: newBit) != 0
                }
                if newBit {

                    if lastBit != currentBit || abs(pskMatchedFilter.phaseError()) > 0.5 { imdBufferPointer = 0 }
                    lastBit = currentBit

                    if imdBufferPointer >= 288 {

                        sinput.realp = imdBufferI + 32
                        sinput.imagp = imdBufferQ + 32
                        output.realp = spec.pointee.re
                        output.imagp = spec.pointee.im
                        CMPerformComplexFFT(imdFFT, &sinput, &output)

                        for k in 0..<256 {
                            // compute power spectrum
                            imdSpectrum[k] = spec.pointee.re[k] * spec.pointee.re[k] + spec.pointee.im[k] * spec.pointee.im[k]
                        }
                        //  search for peak at 0.5*31.25 Hz component
                        peak = 1
                        f0 = imdSpectrum[1]
                        for k in 2..<12 {
                            if imdSpectrum[k] > f0 {
                                f0 = imdSpectrum[k]
                                peak = k
                            }
                        }
                        f0 += imdSpectrum[peak - 1] + imdSpectrum[peak + 1] + 0.001

                        f1 = 0
                        for k in 6..<18 { f1 += imdSpectrum[peak + k] }

                        peak += 18       // position of 2.0*31.25 Hz (noise measure)
                        fN = (imdSpectrum[peak - 2] + imdSpectrum[peak - 1] + imdSpectrum[peak] + imdSpectrum[peak + 1] + imdSpectrum[peak + 2]) * 2.0

                        snr = f0 / (fN + 0.0000001)
                        imd = f1 / f0
                        if f1 > fN { updateIMD(imd, snr: snr) }

                        //  check for next idle pattern
                        imdBufferPointer = 0
                    }
                }
            }
        }
        //  at this point, we have gathered 32 new samples at a rate of Fs/16 (or 64 new samples at Fs/8 for PSK63)

        //  acquisition loop
        mux += 1
        if mux >= 8 || acquire > 0 {
            //  moving window FFT (32 samples are updated each time)
            sinput.realp = decimatedBuffer.pointee.re
            sinput.imagp = decimatedBuffer.pointee.im
            output.realp = spec.pointee.re
            output.imagp = spec.pointee.im
            CMPerformComplexFFT(fft, &sinput, &output)

            if acquire > 0 {
                hasIMD = false
                imdBufferPointer = 0
                //  FFT based AFC acquisition
                sum = 0.01
                diff = 0
                for k in 1..<24 {
                    v = spec.pointee.re[k]
                    u = spec.pointee.im[k]
                    u = sqrt(v * v + u * u)
                    diff += u * Float(k)
                    sum += u * Float(k)
                }
                for k in 1..<24 {
                    v = spec.pointee.re[512 - k]
                    u = spec.pointee.im[512 - k]
                    u = sqrt(v * v + u * u)
                    diff -= u * Float(k)
                    sum += u * Float(k)
                }
                u = diff / sum
                //  smoothing filter for acquisition loop
                acquisitionFilter = acquisitionFilter * 0.3 + u * 0.7

                vco.tune(acquisitionFilter)

                if abs(acquisitionFilter) < 0.03 {
                    acquire -= 1
                    if acquire <= 0 {
                        setTransmitFrequency(vco.frequencyValue())
                        frequencyLocked = true
                    }
                }
            }
        }
        newSpectrum(&output, size: 512)
    }

    //  new PSK data (512 samples per buffer, 0.046 seconds)
    override func importData(_ pipe: CMPipe!) {
        if !receiverEnabledFlag { return }

        let stream = pipe.stream()
        let array = stream!.pointee.array!

        //  copy into clickBuffer
        memcpy(clickBuffer + Int(clickBufferProducer), array, MemoryLayout<Float>.size * 512)
        clickBufferProducer = (clickBufferProducer + 512) & 0x1ffff       // wrap to 128K buffer

        if !frequencyLocked {           //  use history click buffer
            // not locked yet, feed new data into demodulator
            importBuffer(array)
        } else {
            if !printEnabled { varicodeCharacter = 0 }
            printEnabled = true
            for _ in 0..<4 {
                //  flush and clicked data at 4x speed
                if clickBufferProducer == clickBufferConsumer { break }
                importBuffer(clickBuffer + Int(clickBufferConsumer))
                clickBufferConsumer = (clickBufferConsumer + 512) & 0x1ffff  // wrap to 128K buffer
            }
        }
    }

    @objc(setPSKMode:)
    func setPSKMode(_ mode: Int32) {
        pskMode = mode
        //  samples per buffer after decimation
        if pskMode == Int32(kBPSK31) || pskMode == Int32(kQPSK31) {
            decimatedLength = 32
            decimate = decimate31
        } else {
            decimatedLength = 64
            decimate = decimate63
        }
        decimatedOffset = 512 - decimatedLength
    }

    override func selectFrequency(_ freq: Float, fromWaterfall: Bool) {
        if fromWaterfall {
            //  turn FFT based AFC acquisition on
            frequencyLocked = false
            printEnabled = false
            clickBufferProducer = 0
            clickBufferConsumer = 0
            acquisitionFilter = 0.0
            acquire = 10                    //  number of frame for acquisition
        } else {
            frequencyLocked = true
            acquire = 0
        }
        //  now setup receive VCO
        receiveFrequency = freq
        vco.setCarrier(freq)
        receiverEnabledFlag = true
    }

    //  delegate of CMPSKMatchedFilter to receive decoded bits
    //  new bit received from Matched Filter
    @objc(receivedBit:)
    func receivedBit(_ bit: Int32) {
        var sinput = DSPSplitComplex(realp: spec.pointee.re, imagp: spec.pointee.im)
        var output = DSPSplitComplex(realp: spec.pointee.re, imagp: spec.pointee.im)

        //  wait for start bit
        if bit == 0 && varicodeCharacter == 0 { return }

        varicodeCharacter = varicodeCharacter * 2 + bit
        if (varicodeCharacter & 0x3) == 0 {
            if printEnabled {
                let decoded = varicode.decode(varicodeCharacter)

                sinput.realp = decimatedBuffer.pointee.re + 256
                sinput.imagp = decimatedBuffer.pointee.im + 256
                output.realp = spec.pointee.re
                output.imagp = spec.pointee.im
                CMPerformComplexFFT(imdFFT, &sinput, &output)

                for i in 0..<256 {
                    // compute power spectrum
                    imdSpectrum[i] = spec.pointee.re[i] * spec.pointee.re[i] + spec.pointee.im[i] * spec.pointee.im[i]
                }

                receivedCharacter(Int32(decoded), spectrum: imdSpectrum)
                varicodeCharacter = 0
            }
        }
    }

    //  delegate of CMPSKMatchedFilter
    @objc(updateVCOPhase:)
    func updateVCOPhase(_ ang: Float) {
        updatePhase(ang)
    }

    //  delegate of CMPCO
    @objc(vcoChangedTo:)
    func vcoChanged(to tone: Float) {
        receiveFrequency = tone
        updateDisplayFrequency(tone)
    }

    //  delegate methods (forward to the demodulator's delegate) ----

    @objc(newSpectrum:size:)
    func newSpectrum(_ buf: UnsafeMutablePointer<DSPSplitComplex>!, size length: Int32) {
        delegate?.newSpectrum?(buf, size: length)
    }

    @objc(afcEnabled)
    func afcEnabled() -> Bool {
        return delegate?.afcEnabled?() ?? false
    }

    @objc(squelchValue)
    func squelchValue() -> Float {
        return delegate?.squelchValue?() ?? 0
    }

    @objc(updateIMD:snr:)
    func updateIMD(_ imd: Float, snr: Float) {
        //  snr == 0 -- no reading
        if imd == lastIMD { return }
        lastIMD = imd
        delegate?.updateIMD?(imd, snr: snr)
    }

    @objc(updateDisplayFrequency:)
    func updateDisplayFrequency(_ tone: Float) {
        delegate?.updateDisplayFrequency?(tone)
    }

    @objc(setTransmitFrequency:)
    func setTransmitFrequency(_ tone: Float) {
        delegate?.setTransmitFrequency?(tone)
    }

    @objc(receivedCharacter:spectrum:)
    func receivedCharacter(_ c: Int32, spectrum: UnsafeMutablePointer<Float>!) {
        delegate?.receivedCharacter?(c, spectrum: spectrum)
    }

    @objc(updatePhase:)
    func updatePhase(_ ang: Float) {
        delegate?.updatePhase?(ang)
    }
}
