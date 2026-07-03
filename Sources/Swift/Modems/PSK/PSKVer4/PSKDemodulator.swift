//
//  PSKDemodulator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 6/11/07.
//
//  Swift port of PSKDemodulator.m -- the PSK Ver4 demodulator (8000 s/s VCO,
//  32 samples/chip).  A CMPSKDemodulator subclass; decode-critical.  Exact FFT
//  sizes (1024 spectrum / 512 IMD), decimation factors, comb / data / acquisition
//  filter bandwidths, matched-filter dispatch, AFC heuristics and IMD ring buffer
//  are preserved.  C buffers become UnsafeMutablePointer allocations freed in
//  deinit.  Base ivars from CMPSKDemodulator / CMToneReceiver are accessed by
//  their original names.
//
//  Notes: the Objective-C ivar "defer" is renamed "deferCount" (defer is a Swift
//  keyword).  In -estimateIMD the C code read the uninitialised local "power2";
//  it is initialised to power20 here (the documented "quieter sideband" intent)
//  -- this affects only the IMD quality meter, not decoding.
//

import Cocoa

private let kBPSK31: Int32 = 0
private let kBPSK63: Int32 = 1
private let kQPSK31: Int32 = 2
import Accelerate

private struct IMDBuffer {
    var imd: Float = 0
    var carrier: Float = 0
    var noise: Float = 0
}

//  file statics from PSKDemodulator.m
private var frame: Int32 = 0
private var pass: Int32 = 0
private let ibuf = UnsafeMutablePointer<Float>.allocate(capacity: 256)
private let qbuf = UnsafeMutablePointer<Float>.allocate(capacity: 256)
private let bbuf = UnsafeMutablePointer<Float>.allocate(capacity: 256)

//  soft companding curve (unused helper preserved from the C file)
private func px(_ g: Float) -> Float {
    if g >= 0 { return pow(g, 0.98) } else { return -pow(-g, 0.9) }
}

private let STARTWAIT: Int32 = 11
private let ROUGHFETCH: Int32 = 12
private let ROUGHACQUIRE: Int32 = 13
private let ROUGHWAIT: Int32 = 14
private let FINEFETCH: Int32 = 15
private let FINEACQUIRE: Int32 = 16

@objc(PSKDemodulator)
class PSKDemodulator: CMPSKDemodulator {

    internal var decimate125: UnsafeMutablePointer<CMComplexFIR>!   // v0.64f
    internal var psk125: Bool = false

    internal var previousClockSample: Float = 0
    internal var bitSyncPhase: Int32 = 0
    internal var previousI: Float = 0
    internal var previousQ: Float = 0        // simple I,Q from wideband channel

    internal var speci = [Float](repeating: 0, count: 2048)
    internal var specq = [Float](repeating: 0, count: 2048)

    //  frequency indicator
    internal var freqIndicatorMux: Int32 = 0
    internal let freqIndicatorBufI = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
    internal let freqIndicatorBufQ = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
    internal var imdMux: Int32 = 0
    internal let imdBufI = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    internal let imdBufQ = UnsafeMutablePointer<Float>.allocate(capacity: 512)

    //  AFC
    internal var acqFilterI: UnsafeMutablePointer<CMFIR>!
    internal var acqFilterQ: UnsafeMutablePointer<CMFIR>!
    internal var freqError: Float = 0
    internal var freqErrors = [Float](repeating: 0, count: 32)
    internal var forcedAFC: Int32 = 0
    //  acquisition
    internal var acquireIndex: Int32 = 0
    internal let acquisitionBufferI = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
    internal let acquisitionBufferQ = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
    internal var deferCount: Int32 = 0          // was ivar "defer"

    //  IMD (double ring buffer)
    private let imdRingBuffer = UnsafeMutablePointer<IMDBuffer>.allocate(capacity: 256)
    internal var imdBufferIndex: Int32 = 0

    //  cr/lf check
    internal var crlfCheck: Int32 = 0

    internal var modem: PSK?
    internal var modemIndex: Int32 = 0

    //  reusable scratch buffers (were stack arrays in the C code)
    private let bufferI = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let bufferQ = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let decimatedI = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let decimatedQ = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let widebandSpecI = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
    private let widebandSpecQ = UnsafeMutablePointer<Float>.allocate(capacity: 1024)

    func clearImd() {
        imdBufferIndex = 0
        bitSyncPhase = -1
        previousI = 0
        previousQ = 0
        imdMux = 0
        //  NOTE: the C code never advances b in this loop, so only element [0] is cleared
        let b = imdRingBuffer
        for _ in 0..<64 {
            b.pointee.imd = 0
            b.pointee.carrier = 0
            b.pointee.noise = 0
        }
        updateIMD(0, snr: -1.0)
    }

    @objc override init() {
        imdRingBuffer.initialize(repeating: IMDBuffer(), count: 256)
        freqIndicatorBufI.initialize(repeating: 0, count: 1024)
        freqIndicatorBufQ.initialize(repeating: 0, count: 1024)
        imdBufI.initialize(repeating: 0, count: 512)
        imdBufQ.initialize(repeating: 0, count: 512)
        acquisitionBufferI.initialize(repeating: 0, count: 1024)
        acquisitionBufferQ.initialize(repeating: 0, count: 1024)
        bufferI.initialize(repeating: 0, count: 256)
        bufferQ.initialize(repeating: 0, count: 256)
        decimatedI.initialize(repeating: 0, count: 256)
        decimatedQ.initialize(repeating: 0, count: 256)
        widebandSpecI.initialize(repeating: 0, count: 1024)
        widebandSpecQ.initialize(repeating: 0, count: 1024)

        super.init()

        modem = nil                 //  v0.78 controlling modem
        modemIndex = 0              //  0 or 1 to identify the receiver

        clearImd()

        crlfCheck = 0
        psk125 = false

        freqError = 0
        for i in 0..<32 { freqErrors[i] = 0 }
        forcedAFC = 0
        previousClockSample = 0.1

        //  replace 512 point FFT with 1024 pt FFT
        CMDeleteFFT(fft)
        fft = FFTForward(10, true)
        freeAnalyticBuffer(spec)
        spec = CMMallocAnalyticBuffer(1024)

        //  update imd every 1/2 second
        CMDeleteFFT(imdFFT)
        imdFFT = FFTForward(9, true)

        //  swap a 8000 sampling rate VCO
        vco = VCO8k()
        vco.setCarrier(receiveFrequency)

        //  replace decimation filter with one that has 32 samples per chip
        CMDeleteComplexFIR(decimate31)
        CMDeleteComplexFIR(decimate63)
        //  100 Hz cutoff (matched filtering happens in PSKMatchedFilter)
        decimate = CMComplexFIRDecimateWithCutoff(8, 200.0, 8000.0, 512)
        decimate31 = decimate
        //  300 Hz cutoff for PSK63
        decimate63 = CMComplexFIRDecimateWithCutoff(4, 300.0, 8000.0, 512)
        //  400 Hz cutoff for PSK125
        decimate125 = CMComplexFIRDecimateWithCutoff(2, 400.0, 8000.0, 512)
        //  replace comb filter with a 1000 s/s one
        CMDeleteFIR(comb)
        comb = CMFIRCombFilter(31.25, 8000.0 / 8, 2048, -0.8)    //  v0.96b

        //  replace matched filter with the PSKVer3 matched filter
        pskMatchedFilter = PSKMatchedFilter()
        pskMatchedFilter.setDelegate(self)

        //  replace original data filters
        CMDeleteFIR(dataFilterI)
        CMDeleteFIR(dataFilterQ)
        var bw: Float = 31.25 * 0.98        //  v0.96c
        dataFilterI = CMFIRLowpassFilter(bw, 8000.0 / 8, 512)
        dataFilterQ = CMFIRLowpassFilter(bw, 8000.0 / 8, 512)

        //  48 Hz acquisition filter with Fs/8 sampling rate
        bw = 48
        acqFilterI = CMFIRLowpassFilter(bw, 8000.0 / 8, 512)
        acqFilterQ = CMFIRLowpassFilter(bw, 8000.0 / 8, 512)
    }

    deinit {
        freqIndicatorBufI.deallocate(); freqIndicatorBufQ.deallocate()
        imdBufI.deallocate(); imdBufQ.deallocate()
        acquisitionBufferI.deallocate(); acquisitionBufferQ.deallocate()
        imdRingBuffer.deallocate()
        bufferI.deallocate(); bufferQ.deallocate()
        decimatedI.deallocate(); decimatedQ.deallocate()
        widebandSpecI.deallocate(); widebandSpecQ.deallocate()
    }

    @objc(receiverEnabled)
    func receiverEnabled() -> Bool {
        return receiverEnabledFlag
    }

    //  v0.78
    @objc(setPSKModem:index:)
    func setPSKModem(_ master: PSK?, index: Int32) {
        modem = master
        modemIndex = index
    }

    //  0.64f -- added PSK125 to setPSKMode
    override func setPSKMode(_ mode: Int32) {
        psk125 = (mode & 0x8) != 0
        pskMode = mode & 0x3

        //  samples per buffer after decimation
        if pskMode == Int32(kBPSK31) || pskMode == Int32(kQPSK31) {
            decimatedLength = 32
            decimate = decimate31
        } else {
            if !psk125 {
                decimatedLength = 64
                decimate = decimate63
            } else {
                decimatedLength = 128
                decimate = decimate125
            }
        }
        modem?.setReceiveFrequency(receiveFrequency, mode: decimatedLength, forReceiver: modemIndex)
        decimatedOffset = 512 - decimatedLength
    }

    //  prototype for -updateReceiveFrequencyDisplay in PSKReceiver
    @objc(updateReceiveFrequencyDisplay:)
    func updateReceiveFrequencyDisplay(_ freq: Float) {
    }

    //  prototype for -setTransmitFrequencyToReceiveFrequency in PSKReceiver
    @objc(setTransmitFrequencyToReceiveFrequency)
    func setTransmitFrequencyToReceiveFrequency() {
    }

    //  prototype for -setRxOffset in PSKReceiver
    @objc(setRxOffset:)
    func setRxOffset(_ freq: Float) {
    }

    func acquireFrequency(_ range: Int32) {
        var sinput = DSPSplitComplex(realp: acquisitionBufferI, imagp: acquisitionBufferQ)
        var output = DSPSplitComplex(realp: spec.pointee.re, imagp: spec.pointee.im)
        var u: Float, v: Float

        //  perform FFT
        sinput.realp = acquisitionBufferI
        sinput.imagp = acquisitionBufferQ
        output.realp = spec.pointee.re
        output.imagp = spec.pointee.im
        CMPerformComplexFFT(fft, &sinput, &output)

        //  numerator and denominator of centroid function
        var num: Float = 0.0000001
        var denom: Float = 0.0000001
        //  1 Hz per bin, AFC search over (+,-)128 bins
        var i = 1
        while i < Int(range) {
            let j = 1024 - i        // negative frequencies
            v = spec.pointee.re[j]
            u = spec.pointee.im[j]
            u = sqrt(v * v + u * u)
            num += Float(-i) * u
            denom += u
            i += 1
        }
        i = 0
        while i < Int(range) {
            v = spec.pointee.re[i]   // positive frequencies
            u = spec.pointee.im[i]
            u = sqrt(v * v + u * u)
            num += Float(i) * u
            denom += u
            i += 1
        }
        //  afcOffset: +ve means the signal is higher in tone than the VCO
        let afcOffset = num * 1.024 / denom
        vco.tune(afcOffset)
        receiveFrequency = vco.frequencyValue()
        delegate?.updateReceiveFrequencyDisplay?(receiveFrequency)
    }

    //  estimate IMD every 512 samples (spectrum resolution about 2 Hz)
    @discardableResult
    func estimateIMD(_ spectrum: UnsafeMutablePointer<DSPSplitComplex>) -> Bool {
        let re = spectrum.pointee.realp
        let im = spectrum.pointee.imagp
        var u: Float, v: Float, power: Float

        var index10 = 0
        var index11 = 0
        var power10: Float = -1
        var power11: Float = -1
        for i in 0..<16 {
            v = re[i]; u = im[i]
            power = v * v + u * u
            if power > power10 { power10 = power; index10 = i }
        }

        if index10 < 7 || index10 > 9 { return false }  //  ignore, too far off tuned

        for i in 1..<12 {
            v = re[512 - i]; u = im[512 - i]
            power = v * v + u * u
            if power > power11 { power11 = power; index11 = -i }
        }
        let diff = index10 - index11

        if diff < 15 || diff > 17 { return false }      // peaks don't correspond to idling PSK?

        //  power at 3rd IMD locations
        var i = index10 + 16
        v = re[i]; u = im[i]
        let power30 = v * v + u * u

        i = 512 + index11 - 16
        v = re[i]; u = im[i]
        let power31 = v * v + u * u

        //  power at 2nd IMD locations
        i = index10 + 24
        v = re[i]; u = im[i]
        var power20 = v * v + u * u
        i = index10 + 23
        v = re[i]; u = im[i]
        power20 += v * v + u * u

        var power21: Float
        i = 512 + index11 - 24
        v = re[i]; u = im[i]
        power21 = v * v + u * u
        i = 512 + index11 - 23
        v = re[i]; u = im[i]
        power21 += v * v + u * u

        //  choose the quieter sideband (in case of QRM)
        //  (C read power2 uninitialised here; initialise to power20 -- the apparent intent)
        var power2 = power20
        if power21 < power2 { power2 = power21 }

        var b = imdRingBuffer + Int(imdBufferIndex)
        let d = b + 128
        imdBufferIndex = (imdBufferIndex + 127) & 0x7f  //  ready bufferIndex (backwards) for next spectrum

        //  insert IMD and noise samples
        b.pointee.imd = power30 + power31;      d.pointee.imd = b.pointee.imd
        b.pointee.carrier = power10 + power11;  d.pointee.carrier = b.pointee.carrier
        b.pointee.noise = power2;               d.pointee.noise = b.pointee.noise

        //  only update every second
        if (imdBufferIndex & 1) != 0 { return false }

        //  start with two samples and double until we have enough SNR
        var imd: Float = 0, carrier: Float = 0, noise: Float = 0
        var k = 4
        var ii = 0

        for _ in 0..<3 {
            while ii < k {
                imd += b.pointee.imd
                carrier += b.pointee.carrier
                noise += b.pointee.noise
                b += 1
                ii += 1
            }
            if imd > noise * 4 || ii >= 128 { break }
            k *= 2
        }

        //  IMD, with noise correction term
        let imdr = (imd * imd) / (imd + noise + 0.0000001) / ((carrier * carrier) / (carrier + noise + 0.0000001) + 0.0000001)

        if imd > noise * 2 {
            //  if IMD is +6 dB of noise, report unqualified IMD
            updateIMD(imdr, snr: imdr * 1.01)
            return true
        }
        //  noise limited case
        if imdr < 0.0316 {
            //  if better than -15 dB IMD, report as noise limited number
            updateIMD(imdr, snr: imdr * 0.99)
        } else {
            //  otherwise report as "NL"
            updateIMD(-1.0, snr: 0.01)
        }
        return true
    }

    //  Process wide band input.  Each call has one chip (32 samples) at 1000 s/s.
    func processWidebandBuffer(_ inphase: UnsafeMutablePointer<Float>, quadrature: UnsafeMutablePointer<Float>) {
        var sinput = DSPSplitComplex(realp: imdBufI, imagp: imdBufQ)
        var output = DSPSplitComplex(realp: widebandSpecI, imagp: widebandSpecQ)
        var currentI: Float, currentQ: Float, detect: Float

        freqIndicatorMux = freqIndicatorMux & 0x3e0
        for i in 0..<32 {
            freqIndicatorBufI[i + Int(freqIndicatorMux)] = inphase[i]
            freqIndicatorBufQ[i + Int(freqIndicatorMux)] = quadrature[i]
        }

        //  simple BPSK demodulator to look for 180 degree phase transitions
        if bitSyncPhase >= 0 && bitSyncPhase < 32 {
            currentI = inphase[Int(bitSyncPhase)]
            currentQ = quadrature[Int(bitSyncPhase)]
            detect = currentI * previousI + currentQ * previousQ    //  Eq. 4.10, Okunev
            previousI = currentI
            previousQ = currentQ
            if detect >= 0 || imdMux > 15 { imdMux = 0 }            //  not a phase transition chip / sanity
            //  insert chip into buffer
            let off = Int(imdMux) * 32
            for i in 0..<32 {
                imdBufI[off + i] = inphase[i]
                imdBufQ[off + i] = quadrature[i]
            }
            imdMux += 1
            if imdMux >= 16 {
                imdMux = 0
                //  successfully gathered 256 samples of consecutive phase changes
                if frequencyLocked {
                    sinput.realp = imdBufI
                    sinput.imagp = imdBufQ
                    output.realp = widebandSpecI
                    output.imagp = widebandSpecQ
                    //  512 point FFT, windowed
                    CMPerformComplexFFT(imdFFT, &sinput, &output)
                    estimateIMD(&output)
                }
            }
        }

        freqIndicatorMux += 32
        if freqIndicatorMux >= 1024 {
            freqIndicatorMux = 0
            if frequencyLocked {
                sinput.realp = freqIndicatorBufI
                sinput.imagp = freqIndicatorBufQ
                output.realp = widebandSpecI
                output.imagp = widebandSpecQ
                //  1024 point FFT, windowed
                CMPerformComplexFFT(fft, &sinput, &output)
                newSpectrum(&output, size: 1024)
            }
        }
    }

    //  32 data samples (one chip) arrive per call (1000 s/s, not yet bit aligned)
    func processChipBuffer(_ inphase: UnsafeMutablePointer<Float>, quadrature: UnsafeMutablePointer<Float>) {
        var mag: Float, pi: Float, pq: Float, clockSample: Float
        var bitSync: Bool

        if acquire > 0 {
            switch acquire {
            case STARTWAIT:
                // wait for new acquisition buffer to make it through the pipeline after clicking
                acquireIndex += 1
                if acquireIndex > 8 {
                    acquireIndex = 0
                    acquire = ROUGHFETCH
                }
            case ROUGHFETCH, FINEFETCH:
                //  fetch buffers for FFT
                for i in 0..<32 {
                    acquisitionBufferI[Int(acquireIndex)] = inphase[i]
                    acquisitionBufferQ[Int(acquireIndex)] = quadrature[i]
                    acquireIndex += 1
                }
                if acquireIndex >= 1024 { acquire = (acquire == ROUGHFETCH) ? ROUGHACQUIRE : FINEACQUIRE }
            case ROUGHACQUIRE:
                // first (wideband) acquire frequency
                acquireFrequency(64)
                acquire = ROUGHWAIT
                acquireIndex = 0
            case ROUGHWAIT:
                // wait for vco change to make it through the pipeline before fine acquire
                acquireIndex += 1
                if acquireIndex > 2 {
                    acquireIndex = 0
                    acquire = 0             //  don't do fine adjustment, go directly to AFC
                    forcedAFC = 10
                }
            case FINEACQUIRE:
                // second (narrowband) acquire frequency to refine acquisition
                acquireFrequency(20)
                acquire = 0
            default:
                acquireIndex = 0
                forcedAFC = 0
                acquire = STARTWAIT
            }
            return
        }
        frame += 1

        for i in 0..<32 {
            pi = inphase[i]
            pq = quadrature[i]
            mag = pi * pi + pq * pq + 0.00001
            clockSample = CMSimpleFilter(comb, mag)
            bitSync = (previousClockSample < 0 && clockSample >= 0)
            previousClockSample = clockSample

            //  set up clock sync index in a unaligned chip (used by the IMD logic)
            if bitSync { bitSyncPhase = Int32(i) }

            ibuf[Int(pass)] = pi
            qbuf[Int(pass)] = pq
            bbuf[Int(pass)] = bitSync ? 1 : 0
            pass = (pass + 1) & 0xff

            if pskMode == Int32(kBPSK31) || pskMode == Int32(kBPSK63) {
                _ = (pskMatchedFilter as! PSKMatchedFilter).bpsk(pi, imag: pq, bitSync: bitSync)
            } else {
                _ = pskMatchedFilter.qpsk(pi, imag: pq, bitPhase: bitSync)
            }

            if bitSync {
                let chips: Int32 = (forcedAFC > 0) ? 16 : 32    //  1/2 second updates during initial tuning

                //  afc track only every 16 chips
                cycle = (cycle + 1) % chips

                let err = 31.25 * pskMatchedFilter.phaseError() / (3.1415926 * 2)
                freqErrors[Int(cycle)] = err
                freqError += err

                if cycle == 0 {
                    var tune = -freqError * 3.1415926 * 0.5 / Float(chips)   //  average of collected chips

                    //  check AFC
                    if afcEnabled() || forcedAFC > 0 {

                        if forcedAFC == 6 { frequencyLocked = true }    //  should be close enough to print now

                        //  look for quality of phase error
                        var minerr = freqErrors[0]
                        var maxerr = freqErrors[0]
                        var e = 1
                        while e < Int(chips) {
                            if freqErrors[e] > maxerr { maxerr = freqErrors[e] }
                            if freqErrors[e] < minerr { minerr = freqErrors[e] }
                            e += 1
                        }
                        var deltaerr = maxerr - minerr
                        if deltaerr < 1 { deltaerr = 1 }
                        //  adjust AFC correction term based on phase error quality
                        tune = tune / pow(deltaerr, 0.8)

                        if forcedAFC > 0 {
                            if tune > 1 { tune = 1 } else if tune < -1 { tune = -1 }
                        } else {
                            if tune > 0.25 { tune = 0.25 } else if tune < -0.25 { tune = -0.25 }
                        }

                        if abs(tune) > 0.05 {
                            vco.tune(tune)
                            receiveFrequency = vco.frequencyValue()
                            delegate?.updateReceiveFrequencyDisplay?(receiveFrequency)
                        }
                        if forcedAFC > 0 {
                            forcedAFC -= 1
                            if forcedAFC == 0 {
                                //  assume we are tuned; transfer frequency to transmitter
                                delegate?.setTransmitFrequencyToReceiveFrequency?()
                                frequencyLocked = true
                            }
                        }
                    }
                    freqError = 0
                }
            }
        }
    }

    //  New data arrives in 512 sample buffers at 8000 s/s
    override func importBuffer(_ array: UnsafeMutablePointer<Float>) {
        var v: Float
        var pair: CMAnalyticPair
        let samples = Int(decimatedLength)

        //  decimate and process the 512 original input samples
        if samples == 32 {
            //  PSK31 (decimate by 8 -> 1000 s/s)
            for n in 0..<64 {
                let j = n * 8
                for i in 0..<8 {
                    v = array[i + j]
                    pair = vco.nextVCOMixedPair(v)
                    input.pointee.re[i] = pair.re
                    input.pointee.im[i] = pair.im
                }
                pair = CMDecimateAnalyticBuffer(decimate, input, 0)
                decimatedI[n] = pair.re
                decimatedQ[n] = pair.im
                if acquire != 0 {
                    bufferI[n] = CMSimpleFilter(acqFilterI, pair.re)
                    bufferQ[n] = CMSimpleFilter(acqFilterQ, pair.im)
                } else {
                    bufferI[n] = CMSimpleFilter(dataFilterI, pair.re)
                    bufferQ[n] = CMSimpleFilter(dataFilterQ, pair.im)
                }
            }
        } else if samples == 64 {
            //  PSK63 (decimate by 4 -> 2000 s/s)
            for n in 0..<128 {
                let j = n * 4
                for i in 0..<4 {
                    v = array[i + j]
                    pair = vco.nextVCOMixedPair(v)
                    input.pointee.re[i] = pair.re
                    input.pointee.im[i] = pair.im
                }
                pair = CMDecimateAnalyticBuffer(decimate, input, 0)
                decimatedI[n] = pair.re
                decimatedQ[n] = pair.im
                if acquire != 0 {
                    bufferI[n] = CMSimpleFilter(acqFilterI, pair.re)
                    bufferQ[n] = CMSimpleFilter(acqFilterQ, pair.im)
                } else {
                    bufferI[n] = CMSimpleFilter(dataFilterI, pair.re)
                    bufferQ[n] = CMSimpleFilter(dataFilterQ, pair.im)
                }
            }
        } else if samples == 128 {
            //  PSK125 (decimate by 2 -> 4000 s/s)
            for n in 0..<256 {
                let j = n * 2
                for i in 0..<2 {
                    v = array[i + j]
                    pair = vco.nextVCOMixedPair(v)
                    input.pointee.re[i] = pair.re
                    input.pointee.im[i] = pair.im
                }
                pair = CMDecimateAnalyticBuffer(decimate, input, 0)
                decimatedI[n] = pair.re
                decimatedQ[n] = pair.im
                if acquire != 0 {
                    bufferI[n] = CMSimpleFilter(acqFilterI, pair.re)
                    bufferQ[n] = CMSimpleFilter(acqFilterQ, pair.im)
                } else {
                    bufferI[n] = CMSimpleFilter(dataFilterI, pair.re)
                    bufferQ[n] = CMSimpleFilter(dataFilterQ, pair.im)
                }
            }
        }

        //  For PSK31 we have 64 samples (2 chips), for PSK63 128 samples (4 chips), etc.
        processChipBuffer(bufferI, quadrature: bufferQ)
        processChipBuffer(bufferI + 32, quadrature: bufferQ + 32)
        processWidebandBuffer(decimatedI, quadrature: decimatedQ)
        processWidebandBuffer(decimatedI + 32, quadrature: decimatedQ + 32)

        if samples != 32 {
            if samples == 64 {
                processChipBuffer(bufferI + 64, quadrature: bufferQ + 64)
                processChipBuffer(bufferI + 96, quadrature: bufferQ + 96)
                processWidebandBuffer(decimatedI + 64, quadrature: decimatedQ + 64)
                processWidebandBuffer(decimatedI + 96, quadrature: decimatedQ + 96)
            } else if samples == 128 {
                //  PSK125  v0.64f
                var k = 64
                while k < 256 {
                    processChipBuffer(bufferI + k, quadrature: bufferQ + k)
                    processWidebandBuffer(decimatedI + k, quadrature: decimatedQ + k)
                    k += 32
                }
            }
        }
    }

    //  new data arrives from PSKHub (disable print if it is from the click buffer)
    @objc(newDataBuffer:samples:)
    func newDataBuffer(_ array: UnsafeMutablePointer<Float>, samples inSamples: Int32) {
        if !receiverEnabledFlag { return }

        assert(inSamples == 512)

        //  copy into clickBuffer
        memcpy(clickBuffer + Int(clickBufferProducer), array, MemoryLayout<Float>.size * 512)
        clickBufferProducer = (clickBufferProducer + 512) & 0x1ffff

        if !frequencyLocked {           //  use history click buffer
            importBuffer(array)
        } else {
            if !printEnabled { varicodeCharacter = 0 }
            printEnabled = true
            for _ in 0..<4 {
                //  flush and clicked data at 4x speed
                if clickBufferProducer == clickBufferConsumer { break }
                importBuffer(clickBuffer + Int(clickBufferConsumer))
                clickBufferConsumer = (clickBufferConsumer + 512) & 0x1ffff
            }
        }
    }

    override func selectFrequency(_ freq: Float, fromWaterfall: Bool) {
        // clear imd readings
        clearImd()
        super.selectFrequency(freq, fromWaterfall: fromWaterfall)
        modem?.setReceiveFrequency(freq, mode: decimatedLength, forReceiver: modemIndex)
    }

    //  delegate method
    @objc(receivedCharacter:spectrum:quality:)
    func receivedCharacter(_ c: Int32, spectrum: UnsafeMutablePointer<Float>!, quality: Float) {
        delegate?.receivedCharacter?(c, spectrum: spectrum, quality: quality)
    }

    @objc(receivedBit:)
    override func receivedBit(_ bit: Int32) {
        print("-receivedBit: deprecated, use -receivedBit:quality: instead")
    }

    //  delegate of CMPSKMatchedFilter to receive decoded bits
    @objc(receivedBit:quality:)
    func receivedBit(_ bit: Int32, quality: Float) {
        //  wait for start bit
        if bit == 0 && varicodeCharacter == 0 { return }

        varicodeCharacter = varicodeCharacter * 2 + bit
        if (varicodeCharacter & 0x3) == 0 {
            if printEnabled {
                //  this flushes two potential bad character syncs when print is initially enabled
                let wasNegative = deferCount < 0
                deferCount += 1
                if wasNegative { return }

                let decoded = varicode.decode(varicodeCharacter)

                //  ignore cr/lf pairs (v0.57): some programs send 0xd/0xa from a file
                let previous = crlfCheck
                crlfCheck = Int32(decoded)
                if (previous == 0xd && crlfCheck == 0xa) || (previous == 0xa && crlfCheck == 0xd) {
                    varicodeCharacter = 0
                    return
                }

                if deferCount == 1 { receivedCharacter(13 /* \r */, spectrum: imdSpectrum, quality: 1.0) }
                receivedCharacter(Int32(decoded), spectrum: imdSpectrum, quality: quality)
                deferCount = 1
                varicodeCharacter = 0
            } else {
                varicodeCharacter = 0
                deferCount = -2
            }
        }
    }
}
