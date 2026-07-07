//
//  CMPSKDemodulator.swift
//  CoreDSP
//
//  DSP-critical: decimation / FFT / Goertzel / AGC arithmetic and buffer
//  sizes are preserved verbatim from the original port. The delegate was
//  Objective-C duck-typing (`AnyObject?` + optional-chained `@objc` methods);
//  here it's a plain Swift protocol with default no-op implementations, so a
//  conformer only needs to implement what it cares about.
//

import Foundation
import Accelerate

private let kBPSK31: Int32 = 0
private let kBPSK63: Int32 = 1
private let kQPSK31: Int32 = 2

public protocol CMPSKDemodulatorDelegate: AnyObject {
    func pskNewSpectrum(_ buf: UnsafeMutablePointer<DSPSplitComplex>, size: Int32)
    func pskAfcEnabled() -> Bool
    func pskSquelchValue() -> Float
    func pskUpdateIMD(_ imd: Float, snr: Float)
    func pskUpdateDisplayFrequency(_ tone: Float)
    func pskSetTransmitFrequency(_ tone: Float)
    func pskReceivedCharacter(_ c: Int32, spectrum: UnsafeMutablePointer<Float>)
    func pskUpdatePhase(_ ang: Float)
}

public extension CMPSKDemodulatorDelegate {
    func pskNewSpectrum(_ buf: UnsafeMutablePointer<DSPSplitComplex>, size: Int32) {}
    func pskAfcEnabled() -> Bool { false }
    func pskSquelchValue() -> Float { 0 }
    func pskUpdateIMD(_ imd: Float, snr: Float) {}
    func pskUpdateDisplayFrequency(_ tone: Float) {}
    func pskSetTransmitFrequency(_ tone: Float) {}
    func pskReceivedCharacter(_ c: Int32, spectrum: UnsafeMutablePointer<Float>) {}
    func pskUpdatePhase(_ ang: Float) {}
}

final class CMPSKDemodulator: CMToneReceiver, CMPSKMatchedFilterDelegate, CMPCODelegate {

    weak var delegate: CMPSKDemodulatorDelegate?

    //  decimation filters
    var decimatedLength: Int32 = 0
    var decimatedOffset: Int32 = 0
    var decimatedBuffer: UnsafeMutablePointer<CMAnalyticBuffer>!
    var decimate: UnsafeMutablePointer<CMComplexFIR>!
    var decimate31: UnsafeMutablePointer<CMComplexFIR>!
    var decimate63: UnsafeMutablePointer<CMComplexFIR>!
    //  psk31 filters
    var comb: UnsafeMutablePointer<CMFIR>!
    var dataFilterI: UnsafeMutablePointer<CMFIR>!
    var dataFilterQ: UnsafeMutablePointer<CMFIR>!
    var imdFilterI: UnsafeMutablePointer<CMFIR>!
    var imdFilterQ: UnsafeMutablePointer<CMFIR>!
    //  data matched filter
    var pskMatchedFilter: CMPSKMatchedFilter!
    //  varicode decoder
    var varicode: CMVaricode!

    var baseI = [Float](repeating: 0, count: 65)
    var baseQ = [Float](repeating: 0, count: 65)
    var bitClock = [Float](repeating: 0, count: 65)
    var input: UnsafeMutablePointer<CMAnalyticBuffer>!
    var spec: UnsafeMutablePointer<CMAnalyticBuffer>!

    var fft: UnsafeMutablePointer<CMFFT>!
    var imdFFT: UnsafeMutablePointer<CMFFT>!
    var acquisitionFilter: Float = 0
    var printEnabled: Bool = false

    let clickBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 0x20000)
    var clickBufferProducer: Int32 = 0
    var clickBufferConsumer: Int32 = 0

    var lastAng: Float = 0
    var phaseLoop: Float = 0
    var cycle: Int32 = 0
    var pskMode: Int32 = 0
    var mux: Int32 = 0
    var varicodeCharacter: Int32 = 0

    //  IMD
    var imdBufferPointer: Int32 = 0
    var lastIMD: Float = 0
    let imdBufferI = UnsafeMutablePointer<Float>.allocate(capacity: 288)
    let imdBufferQ = UnsafeMutablePointer<Float>.allocate(capacity: 288)
    let imdSpectrum = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    var hasIMD: Bool = false
    var lastBit: Bool = false

    override init() {
        super.init()

        delegate = nil
        vco.setDelegate(self)
        vco.setOutputScale(8.0)

        for i in 0..<65 { baseI[i] = 0; baseQ[i] = 0; bitClock[i] = 0 }
        for i in 0..<256 { imdSpectrum[i] = -1.0 }

        pskMatchedFilter = CMPSKMatchedFilter()
        pskMatchedFilter.delegate = self

        decimate = CMComplexFIRDecimateWithCutoff(16, 300.0, Float(CMFs), 256)
        decimate31 = decimate
        decimate63 = CMComplexFIRDecimateWithCutoff(8, 300.0, Float(CMFs), 256)

        dataFilterI = CMFIRLowpassFilter(32, Float(CMFs) / 16, 256)
        dataFilterQ = CMFIRLowpassFilter(32, Float(CMFs) / 16, 256)
        imdFilterI = CMFIRLowpassFilter(150, Float(CMFs) / 16, 256)
        imdFilterQ = CMFIRLowpassFilter(150, Float(CMFs) / 16, 256)

        comb = CMFIRCombFilter(31.25, Float(CMFs) / 16, 1024, 1.5708)

        varicode = CMVaricode()

        mux = 0
        pskMode = kBPSK31
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

    //  called from importData; 0.17 uses FFT to estimate IMD
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

        CMShiftAnalyticBuffer(decimatedBuffer, Int32(samples))

        iptr = decimatedBuffer.pointee.re + Int(decimatedOffset)
        qptr = decimatedBuffer.pointee.im + Int(decimatedOffset)

        for nn in 0..<samples {
            n = nn
            if samples == 32 {
                j = n * 16
                for ii in 0..<16 {
                    v = array[ii + j]
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

        iptr = decimatedBuffer.pointee.re + Int(decimatedOffset)
        qptr = decimatedBuffer.pointee.im + Int(decimatedOffset)
        baseI[0] = baseI[samples]
        baseQ[0] = baseQ[samples]
        bitClock[0] = bitClock[samples]

        for nn in 0..<samples {
            n = nn

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
                        cycle += 1
                        if cycle > 2 { cycle = 0 }
                    }
                }
                newBit = (bitClock[n] > 0 && bitClock[n + 1] <= 0)
                if pskMode == kBPSK31 || pskMode == kBPSK63 {
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
                            imdSpectrum[k] = spec.pointee.re[k] * spec.pointee.re[k] + spec.pointee.im[k] * spec.pointee.im[k]
                        }
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

                        peak += 18
                        fN = (imdSpectrum[peak - 2] + imdSpectrum[peak - 1] + imdSpectrum[peak] + imdSpectrum[peak + 1] + imdSpectrum[peak + 2]) * 2.0

                        snr = f0 / (fN + 0.0000001)
                        imd = f1 / f0
                        if f1 > fN { updateIMD(imd, snr: snr) }

                        imdBufferPointer = 0
                    }
                }
            }
        }

        mux += 1
        if mux >= 8 || acquire > 0 {
            sinput.realp = decimatedBuffer.pointee.re
            sinput.imagp = decimatedBuffer.pointee.im
            output.realp = spec.pointee.re
            output.imagp = spec.pointee.im
            CMPerformComplexFFT(fft, &sinput, &output)

            if acquire > 0 {
                hasIMD = false
                imdBufferPointer = 0
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

        memcpy(clickBuffer + Int(clickBufferProducer), array, MemoryLayout<Float>.size * 512)
        clickBufferProducer = (clickBufferProducer + 512) & 0x1ffff

        if !frequencyLocked {
            importBuffer(array)
        } else {
            if !printEnabled { varicodeCharacter = 0 }
            printEnabled = true
            for _ in 0..<4 {
                if clickBufferProducer == clickBufferConsumer { break }
                importBuffer(clickBuffer + Int(clickBufferConsumer))
                clickBufferConsumer = (clickBufferConsumer + 512) & 0x1ffff
            }
        }
    }

    func setPSKMode(_ mode: Int32) {
        pskMode = mode
        if pskMode == kBPSK31 || pskMode == kQPSK31 {
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
            frequencyLocked = false
            printEnabled = false
            clickBufferProducer = 0
            clickBufferConsumer = 0
            acquisitionFilter = 0.0
            acquire = 10
        } else {
            frequencyLocked = true
            acquire = 0
        }
        receiveFrequency = freq
        vco.setCarrier(freq)
        receiverEnabledFlag = true
    }

    //  CMPSKMatchedFilterDelegate: new bit received from Matched Filter
    func matchedFilterReceivedBit(_ bit: Int32) {
        var sinput = DSPSplitComplex(realp: spec.pointee.re, imagp: spec.pointee.im)
        var output = DSPSplitComplex(realp: spec.pointee.re, imagp: spec.pointee.im)

        if bit == 0 && varicodeCharacter == 0 { return }

        varicodeCharacter = varicodeCharacter &* 2 &+ bit
        if (varicodeCharacter & 0x3) == 0 {
            if printEnabled {
                let decoded = varicode.decode(varicodeCharacter)

                sinput.realp = decimatedBuffer.pointee.re + 256
                sinput.imagp = decimatedBuffer.pointee.im + 256
                output.realp = spec.pointee.re
                output.imagp = spec.pointee.im
                CMPerformComplexFFT(imdFFT, &sinput, &output)

                for i in 0..<256 {
                    imdSpectrum[i] = spec.pointee.re[i] * spec.pointee.re[i] + spec.pointee.im[i] * spec.pointee.im[i]
                }

                receivedCharacter(Int32(decoded), spectrum: imdSpectrum)
                varicodeCharacter = 0
            }
        }
    }

    func matchedFilterUpdateVCOPhase(_ ang: Float) {
        updatePhase(ang)
    }

    //  CMPCODelegate
    func vcoChanged(to tone: Float) {
        receiveFrequency = tone
        updateDisplayFrequency(tone)
    }

    //  forwards to the delegate
    func newSpectrum(_ buf: UnsafeMutablePointer<DSPSplitComplex>, size length: Int32) {
        delegate?.pskNewSpectrum(buf, size: length)
    }

    func afcEnabled() -> Bool {
        return delegate?.pskAfcEnabled() ?? false
    }

    func squelchValue() -> Float {
        return delegate?.pskSquelchValue() ?? 0
    }

    func updateIMD(_ imd: Float, snr: Float) {
        if imd == lastIMD { return }
        lastIMD = imd
        delegate?.pskUpdateIMD(imd, snr: snr)
    }

    func updateDisplayFrequency(_ tone: Float) {
        delegate?.pskUpdateDisplayFrequency(tone)
    }

    func setTransmitFrequency(_ tone: Float) {
        delegate?.pskSetTransmitFrequency(tone)
    }

    func receivedCharacter(_ c: Int32, spectrum: UnsafeMutablePointer<Float>) {
        delegate?.pskReceivedCharacter(c, spectrum: spectrum)
    }

    func updatePhase(_ ang: Float) {
        delegate?.pskUpdatePhase(ang)
    }
}
