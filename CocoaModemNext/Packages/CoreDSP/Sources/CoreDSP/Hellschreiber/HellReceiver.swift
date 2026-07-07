//
//  HellReceiver.swift
//  CoreDSP
//
//  Swift port of HellReceiver.swift (originally HellReceiver.m). A
//  CMToneReceiver subclass implementing Feld-Hell (CW/AM) and FM Hell
//  demodulation. DSP-critical and preserved verbatim: the matched-filter
//  kernel, decimation phase accumulator, Al-Alaoui differentiator, AGC, and
//  the FFT acquisition histogram.
//
//  The original ivar "client" (a Modem*, renamed "modemClient" in the prior
//  Swift port to avoid colliding with CMPipe's -client method) reached back
//  into the app via `(modemClient as? Hellschreiber)?.addColumn(...)` /
//  `.frequencyUpdated(to:)` -- Objective-C duck typing. Here that becomes a
//  proper Swift protocol, HellReceiverDelegate, with default no-op
//  implementations, and the raw `UnsafeMutablePointer<Float>` 28-pixel column
//  the original handed to its AppKit display view is copied into a plain
//  `[Float]` before being handed to the delegate (CoreDSP has no AppKit
//  dependency and must stay cross-platform).
//
//  The original also took an `init(fromModem:)` parameter purely to stash that
//  back-reference; since the back-reference is now the `delegate` property,
//  init() takes no parameter.
//

import Foundation
import Accelerate

private let hellPi: Double = Double.pi

protocol HellReceiverDelegate: AnyObject {
    /// One 28-half-pixel double-height column of demodulated image data.
    /// `index` is 0 for the normal receive path, 1 for a transmit echo (full
    /// duplex tap) -- mirrors the original's `addColumn(_:index:xScale:)`.
    func hellAddColumn(_ column: [Float], index: Int32)
    /// AFC/acquisition tone estimate, for driving a waterfall frequency marker.
    func hellFrequencyUpdated(to freq: Float)
}

extension HellReceiverDelegate {
    func hellAddColumn(_ column: [Float], index: Int32) {}
    func hellFrequencyUpdated(to freq: Float) {}
}

class HellReceiver: CMToneReceiver {

    weak var delegate: HellReceiverDelegate?

    //  matched filter
    internal var iMatchedFilter: UnsafeMutablePointer<CMFIR>!
    internal var qMatchedFilter: UnsafeMutablePointer<CMFIR>!
    internal let iDemod = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    internal let qDemod = UnsafeMutablePointer<Float>.allocate(capacity: 256)

    //  agc
    internal var agc: Float = 0

    //  decimating filter
    internal var iFilter: UnsafeMutablePointer<CMFIR>!
    internal var qFilter: UnsafeMutablePointer<CMFIR>!
    internal let iMixer = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    internal let qMixer = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    internal let iIF = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    internal let qIF = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    internal let freqBuf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    internal var iBuf0: UnsafeMutablePointer<Float>!
    internal var qBuf0: UnsafeMutablePointer<Float>!
    internal var iBuf1: UnsafeMutablePointer<Float>!
    internal var qBuf1: UnsafeMutablePointer<Float>!
    internal var currentIBuf: UnsafeMutablePointer<Float>!
    internal var currentQBuf: UnsafeMutablePointer<Float>!
    internal var inputIndex: Int = 0
    internal var outputIndex: Int = 0
    internal var inputPhase: Float = 0.0
    internal var phaseDecimation: Float = 0    // 5.0 nominal decimation

    //  mode (HELLFELD, HELLFM...)
    internal var mode: Int32 = 0
    internal var iReg = [Float](repeating: 0, count: 3)
    internal var qReg = [Float](repeating: 0, count: 3)
    internal var iDelay = [Float](repeating: 0, count: 3)
    internal var qDelay = [Float](repeating: 0, count: 3)
    internal var mag: Float = 0

    //  demod output
    internal let column = UnsafeMutablePointer<Float>.allocate(capacity: 32)  // 2x14 subpixels
    internal var columnPhase: Int = 0
    internal var sidebandState: Bool = false

    //  acquisition
    internal var fft: UnsafeMutablePointer<CMFFT>!
    internal var acquisitionPhase: Int = 0
    internal var acquisitionPass: Int = 0
    internal var histogram = [Int](repeating: 0, count: 80)
    internal var addedPhase: Int = 0
    internal var iBuf: UnsafeMutablePointer<Float>!
    internal var qBuf: UnsafeMutablePointer<Float>!
    internal var iSpec: UnsafeMutablePointer<Float>!
    internal var qSpec: UnsafeMutablePointer<Float>!
    internal var offset: Float = 0
    internal var lock: NSLock!
    var lockedFrequency: Float = 0

    //  reusable double-height output column (28 pixels)
    private let pixelColumn = UnsafeMutablePointer<Float>.allocate(capacity: 28)

    override init() {
        super.init()

        lock = NSLock()

        iDemod.initialize(repeating: 0, count: 256)
        qDemod.initialize(repeating: 0, count: 256)
        iMixer.initialize(repeating: 0, count: 512)
        qMixer.initialize(repeating: 0, count: 512)
        iIF.initialize(repeating: 0, count: 512)
        qIF.initialize(repeating: 0, count: 512)
        freqBuf.initialize(repeating: 0, count: 512)
        column.initialize(repeating: 0, count: 32)
        pixelColumn.initialize(repeating: 0, count: 28)

        mode = HELLFELD
        //  matched filter (note: vDSP requires length >= 32)
        var kernel = [Float](repeating: 0, count: 36)
        for i in 0..<36 {
            let ang = 2.0 * hellPi * (Double(i) + 0.5) / 36.0
            kernel[i] = Float((1.0 - cos(ang)) * 0.5)
        }
        kernel.withUnsafeMutableBufferPointer { kp in
            iMatchedFilter = CMFIRFilter(kp.baseAddress, 36)
            qMatchedFilter = CMFIRFilter(kp.baseAddress, 36)
        }
        agc = 1.0
        addedPhase = 0
        sidebandState = false

        //  decimation
        fft = FFTForward(9, true)
        //  dual use buffers (IF during demod, FFT during acquisition)
        iBuf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        qBuf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        iSpec = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        qSpec = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        //  derivative IIR memory
        for i in 0..<3 { iReg[i] = 0; qReg[i] = 0; iDelay[i] = 0; qDelay[i] = 0 }
        agc = 1.0
        mag = 1.0

        //  demod buffers
        iBuf0 = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        qBuf0 = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        iBuf1 = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        qBuf1 = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        iBuf0.initialize(repeating: 0, count: 128)
        qBuf0.initialize(repeating: 0, count: 128)
        iBuf1.initialize(repeating: 0, count: 128)
        qBuf1.initialize(repeating: 0, count: 128)
        currentIBuf = iBuf0
        currentQBuf = qBuf0
        inputIndex = 0
        outputIndex = 0
        inputPhase = 0.0
        for i in 0..<256 { iDemod[i] = 0.0; qDemod[i] = 0.0 }
        //  pixel column
        columnPhase = 0
        phaseDecimation = 5.0
        for i in 0..<32 { column[i] = 0 }
        lockedFrequency = 0.0

        //  100 Hz IF filters for I and Q channel
        iFilter = CMFIRLowpassFilter(100.0, Float(CMFs), 256)
        qFilter = CMFIRLowpassFilter(100.0, Float(CMFs), 256)
    }

    deinit {
        iDemod.deallocate(); qDemod.deallocate()
        iMixer.deallocate(); qMixer.deallocate()
        iIF.deallocate(); qIF.deallocate(); freqBuf.deallocate()
        iBuf0?.deallocate(); qBuf0?.deallocate(); iBuf1?.deallocate(); qBuf1?.deallocate()
        iBuf?.deallocate(); qBuf?.deallocate(); iSpec?.deallocate(); qSpec?.deallocate()
        column.deallocate(); pixelColumn.deallocate()
    }

    func setMode(_ which: Int32) {
        var freq: Float

        mode = which

        if mode == HELLFM245 {
            freq = receiveFrequency + 245.0 * 0.25
            if sidebandState { freq -= 245.0 * 0.5 }
        } else if mode == HELLFM105 {
            freq = receiveFrequency + 105.0 * 0.25
            if sidebandState { freq -= 105.0 * 0.5 }
        } else {
            freq = receiveFrequency
        }
        vco.setCarrier(freq)
    }

    func setSidebandState(_ state: Bool) {
        sidebandState = state
        setMode(mode)
    }

    override func selectFrequency(_ freq: Float, fromWaterfall: Bool) {
        super.selectFrequency(freq, fromWaterfall: fromWaterfall)
        //  don't use AFC
        lockProcessStarted = false
        frequencyLocked = true
        receiveFrequency = freq
        lockedFrequency = freq
        setMode(mode)       // set correct frequency
    }

    func canTransmit() -> Bool {
        return receiverEnabledFlag && lockedFrequency > 250 && lockedFrequency < 2800
    }

    override func importData(_ pipe: CMPipe!) {
        switch mode {
        case HELLFM105, HELLFM245:
            fmImport(pipe)
        default:    // HELLFELD
            feldImport(pipe)
        }
    }

    //	CW demodulator
    func feldImport(_ pipe: CMPipe!) {
        var pair: CMAnalyticPair
        var input = DSPSplitComplex(realp: iBuf, imagp: qBuf)
        var output = DSPSplitComplex(realp: iSpec, imagp: qSpec)
        var peak: Int, count: Int, median: Int, trunc: Int
        var v: Float, vPeak: Float

        if !receiverEnabledFlag { return }          //  wait for click

        let stream = pipe.stream()
        let array = stream!.pointee.array!

        //  decimate and process the 512 original input samples
        for i in 0..<512 {
            v = array[i]
            pair = vco.nextVCOPair()
            iMixer[i] = pair.re * v
            qMixer[i] = pair.im * v
        }
        CMPerformFIR(iFilter, iMixer, 512, iIF)
        CMPerformFIR(qFilter, qMixer, 512, qIF)

        //  ignore frequency lock and print right away (original condition "1 || frequencyLocked")
        //  decimate by 5 (phaseDecimation), giving 18 samples per Feld-Hell bit
        var i = 0
        while i < 512 {
            currentIBuf[outputIndex] = iIF[inputIndex]
            currentQBuf[outputIndex] = qIF[inputIndex]
            outputIndex += 1

            if addedPhase != 0 {
                if addedPhase > 0 && outputIndex < 100 {
                    for _ in 0..<3 {
                        currentIBuf[outputIndex] = 0
                        currentQBuf[outputIndex] = 0
                        outputIndex += 1
                    }
                    addedPhase -= 1
                }
                if addedPhase < 0 && outputIndex > 32 {
                    outputIndex -= 3
                    addedPhase += 1
                }
            }

            inputPhase += phaseDecimation
            trunc = Int(inputPhase)
            inputPhase -= Float(trunc)
            inputIndex += trunc

            if outputIndex >= 126 {
                //  send to demodulator when we have enough samples
                feldDemodulate(currentIBuf, quadrature: currentQBuf, length: 126)
                //  select next buffer
                if currentIBuf == iBuf0 {
                    currentIBuf = iBuf1
                    currentQBuf = qBuf1
                } else {
                    currentIBuf = iBuf0
                    currentQBuf = qBuf0
                }
                outputIndex = 0
            }
            if inputIndex >= 512 { break }
            i += 1
        }
        inputIndex &= 0x1ff     // mod 512

        if !frequencyLocked {
            //  AFC BYPASSED in v0.18
            lock.lock()
            // acquisition phase
            if !lockProcessStarted {
                //  first pass of the acquisition phase
                lockProcessStarted = true
                acquisitionPhase = 0
                acquisitionPass = 0
                offset = 0
                for h in 0..<80 { histogram[h] = 0 }
            }
            let k = acquisitionPhase * 32
            var j = 0
            while j < 512 {
                //  decimate by 8
                iBuf[k + j / 16] = iIF[j]
                qBuf[k + j / 16] = qIF[j]
                j += 16
            }
            acquisitionPhase += 1
            if acquisitionPhase >= 16 {
                input.realp = iBuf
                input.imagp = qBuf
                output.realp = iSpec
                output.imagp = qSpec
                CMPerformComplexFFT(fft, &input, &output)

                peak = 0
                vPeak = iSpec[peak] * iSpec[peak] + qSpec[peak] * qSpec[peak]
                for p in 1..<40 {
                    v = iSpec[p] * iSpec[p] + qSpec[p] * qSpec[p]
                    if v > vPeak {
                        vPeak = v
                        peak = p
                    }
                    v = iSpec[512 - p] * iSpec[512 - p] + qSpec[512 - p] * qSpec[512 - p]
                    if v > vPeak {
                        vPeak = v
                        peak = -p
                    }
                }
                histogram[peak + 40] += 1

                //  move indicator on waterfall for user feedback
                offset = Float((Double(offset) + Double(peak) * CMFs * 0.5 / (256.0 * 16.0)) * 0.5)
                delegate?.hellFrequencyUpdated(to: receiveFrequency + offset)
                acquisitionPhase = 0

                if histogram[peak + 40] >= 2 {
                    //  found confirming spectral peak
                    frequencyLocked = true
                } else {
                    // find median
                    acquisitionPass += 1
                    if acquisitionPass >= 5 {
                        frequencyLocked = true
                        lockProcessStarted = false
                        // find median in histogram
                        count = 0
                        median = acquisitionPass / 2
                        var idx = 0
                        for h in 0..<80 {
                            idx = h
                            count += histogram[h]
                            if count > median { break }
                        }
                        peak = idx - 40
                    }
                }
                if frequencyLocked {
                    lockProcessStarted = false
                    offset = Float(Double(peak) * CMFs * 0.5 / (256.0 * 16.0))
                    receiveFrequency += offset
                    lockedFrequency = receiveFrequency
                    vco.setCarrier(receiveFrequency)
                    delegate?.hellFrequencyUpdated(to: receiveFrequency)
                }
            }
            lock.unlock()
        }
    }

    //  FM demodulator
    func fmImport(_ pipe: CMPipe!) {
        var pair: CMAnalyticPair
        var trunc: Int
        var v: Float, iDot: Float, qDot: Float, freq: Float

        if !receiverEnabledFlag { return }          //  wait for click

        let stream = pipe.stream()
        let array = stream!.pointee.array!

        for i in 0..<512 {
            v = array[i]
            pair = vco.nextVCOPair()
            iMixer[i] = pair.re * v
            qMixer[i] = pair.im * v
        }
        CMPerformFIR(iFilter, iMixer, 512, iIF)
        CMPerformFIR(qFilter, qMixer, 512, qIF)

        //  in the future, any FM limiting can go here.

        for i in 0..<512 {
            //  IIR differentiator using Al-Alaoui's 1994 algorithm
            iReg[0] = iIF[i] - 0.5358 * iReg[1] - 0.0718 * iReg[2]
            iDot = iReg[2] - iReg[0]

            qReg[0] = qIF[i] - 0.5358 * qReg[1] - 0.0718 * qReg[2]
            qDot = qReg[2] - qReg[0]

            //  apply a slow AGC
            mag = mag * 0.9 + 0.1 * (iDelay[0] * iDelay[0] + qDelay[0] * qDelay[0])
            freq = (qDelay[0] * iDot - iDelay[0] * qDot) / mag

            //  update IIR registers for next pass
            iReg[2] = iReg[1]
            iReg[1] = iReg[0]
            qReg[2] = qReg[1]
            qReg[1] = qReg[0]
            iDelay[0] = iDelay[1]
            iDelay[1] = iDelay[2]
            iDelay[2] = iIF[i]
            qDelay[0] = qDelay[1]
            qDelay[1] = qDelay[2]
            qDelay[2] = qIF[i]

            freqBuf[i] = freq
        }

        var i = 0
        while i < 512 {
            currentIBuf[outputIndex] = freqBuf[inputIndex]
            outputIndex += 1

            //  decimate by phaseDecimation (approx 5 plus a correction factor)
            if addedPhase != 0 {
                if addedPhase > 0 && outputIndex < 100 {
                    for _ in 0..<3 {
                        currentIBuf[outputIndex] = 0
                        outputIndex += 1
                    }
                    addedPhase -= 1
                }
                if addedPhase < 0 && outputIndex > 32 {
                    outputIndex -= 3
                    addedPhase += 1
                }
            }
            inputPhase += phaseDecimation
            trunc = Int(inputPhase)
            inputPhase -= Float(trunc)
            inputIndex += trunc

            if outputIndex >= 126 {
                //  send to demodulator when we have enough samples
                if mode == HELLFM105 { fmResample105(currentIBuf) } else { fmResample245(currentIBuf) }
                //  select next buffer
                currentIBuf = (currentIBuf == iBuf0) ? iBuf1 : iBuf0
                outputIndex = 0
            }
            if inputIndex >= 512 { break }
            i += 1
        }
        inputIndex &= 0x1ff     // mod 512
    }

    //  quadrature tone demodulator for FM HELL 245 (called when 126 samples collected)
    func fmResample245(_ freq: UnsafeMutablePointer<Float>) {
        var u: Float

        //  create 14 half-pixels from 126 sample with 9 element boxcar
        columnPhase = (columnPhase + 1) & 1

        var columnPtr = column + columnPhase * 16

        for i in 0..<14 {
            u = 0
            let k = i * 9
            for j in 0..<9 {
                u += (freq[k + j] * 14.3) + 0.5     // scale (-122.5,+122.5) Hz to (0,1.0)
            }
            u /= 9.0
            if u > 1.0 { u = 1.0 } else if u < 0 { u = 0 }
            columnPtr[i] = sidebandState ? (1.0 - u) : u
        }

        //  output double height column (28 pixels total)
        columnPtr = column + (columnPhase ^ 1) * 16
        for i in 0..<14 { pixelColumn[i] = columnPtr[i] }
        columnPtr = column + columnPhase * 16
        for i in 0..<14 { pixelColumn[i + 14] = columnPtr[i] }

        emitColumn()
    }

    //  quadrature tone demodulator for FM HELL 105 (called when 126 samples collected)
    func fmResample105(_ freq: UnsafeMutablePointer<Float>) {
        var u: Float

        //  create 12 half-pixels from 126 sample with 10/21 element boxcar
        columnPhase = (columnPhase + 1) & 1

        var columnPtr = column + columnPhase * 16

        var k = 0
        var i = 0
        while i < 12 {
            //  first half pixel
            u = 0
            for j in 0..<11 { u += (freq[k + j] * 24.5) + 0.5 }     // scale to (-1,+1)
            u /= 11.0
            if u > 1.0 { u = 1.0 } else if u < 0 { u = 0 }
            columnPtr[i] = sidebandState ? (1.0 - u) : u

            //  second half pixel
            u = 0
            for j in 11..<21 { u += (freq[k + j] * 24.5) + 0.5 }    // scale to (-1,+1)
            u /= 10.0
            if u > 1.0 { u = 1.0 } else if u < 0 { u = 0 }
            columnPtr[i + 1] = sidebandState ? (1.0 - u) : u

            k += 21
            i += 2
        }

        //  output double height column (28 pixels total)
        columnPtr = column + (columnPhase ^ 1) * 16
        for i in 0..<12 { pixelColumn[i + 2] = columnPtr[i] }
        columnPtr = column + columnPhase * 16
        for i in 0..<12 { pixelColumn[i + 14] = columnPtr[i] }
        pixelColumn[0] = 0; pixelColumn[1] = 0; pixelColumn[26] = 0; pixelColumn[27] = 0

        emitColumn()
    }

    //  quadrature tone demodulator for Hellschreiber (length should be 126)
    func feldDemodulate(_ inphase: UnsafeMutablePointer<Float>, quadrature: UnsafeMutablePointer<Float>, length: Int32) {
        var v: Float, u: Float
        let len = Int(length)

        columnPhase = (columnPhase + 1) & 1

        let size = MemoryLayout<Float>.size * len
        memmove(iDemod, iDemod + len, size)
        CMPerformFIR(iMatchedFilter, inphase, length, iDemod + len)
        memmove(qDemod, qDemod + len, size)
        CMPerformFIR(qMatchedFilter, quadrature, length, qDemod + len)

        //  each column of data consists of 7 full Hellschreiber pixels (18 samples each)
        var columnPtr = column + columnPhase * 16
        for i in 0..<14 {
            u = 0
            var k = i * 9
            for _ in 0..<9 {
                v = sqrt(iDemod[k] * iDemod[k] + qDemod[k] * qDemod[k])
                k += 1
                //  agc, fast charge, slow discharge
                agc = (v > agc) ? (agc * 0.9 + 0.1 * v) : (agc * 0.9995 + 0.0005 * v)
                u += v / (0.5 + agc * 0.5)
            }
            u /= 9.0
            if u > 1.0 { u = 1.0 }
            columnPtr[i] = u
        }

        //  output double height column (28 pixels total)
        columnPtr = column + (columnPhase ^ 1) * 16
        for i in 0..<14 { pixelColumn[i] = columnPtr[i] }
        columnPtr = column + columnPhase * 16
        for i in 0..<14 { pixelColumn[i + 14] = columnPtr[i] }
        emitColumn()
    }

    private func emitColumn() {
        var out = [Float](repeating: 0, count: 28)
        for i in 0..<28 { out[i] = pixelColumn[i] }
        delegate?.hellAddColumn(out, index: 0)
    }

    func slopeChanged(_ value: Float) {
        phaseDecimation = 5.0 - value
    }

    func positionChanged(_ direction: Int32) {
        addedPhase += Int(direction) * 3
    }
}
