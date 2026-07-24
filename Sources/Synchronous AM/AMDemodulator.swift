//
//  AMDemodulator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/18/07.
//  Swift port of AMDemodulator.m.
//
//  Synchronous-AM DSP demodulator.  The filters (carrierFilter, sidebandFilter,
//  ...) are C CMFIR objects (float* buffers), the VCOs are CMPCO Objective-C
//  objects and the equalizer is a ParametricEqualizer.  No float->int
//  conversion happens in the signal path, so there is nothing to clamp here;
//  the arithmetic is pure Float (Float does not trap).
//

import Cocoa

private let CMFsF: Float = 11025.0   // CMFs

@objc(AMDemodulator)
class AMDemodulator: NSObject {

    private weak var client: SynchAM?
    private var carrierFilter: UnsafeMutablePointer<CMFIR>?
    private var sidebandFilter: UnsafeMutablePointer<CMFIR>?
    private var iFilter: UnsafeMutablePointer<CMFIR>?
    private var qFilter: UnsafeMutablePointer<CMFIR>?
    private var iAudioFilter: UnsafeMutablePointer<CMFIR>?
    private var qAudioFilter: UnsafeMutablePointer<CMFIR>?
    private var outputFilter: UnsafeMutablePointer<CMFIR>?
    private var carrierVco: CMPCO!
    private var downshiftVco: CMPCO!
    private var upshiftVco: CMPCO!
    private var cyclesSinceAdjust: Int32 = 0
    private var fc: Float = 0.0
    private var fd: Float = 0.0
    private var fshift: Float = 0.0
    private var fl: Float = 0.0
    private var fh: Float = 0.0
    private var volume: Float = 0.0
    private var excessDelta: Float = 0.0
    //  ParametricEqualizer
    private var equalizer: ParametricEqualizer!
    private var eqFilter: UnsafeMutablePointer<CMFIR>?
    private var equalizerEnable: Bool = false

    override init() {
        super.init()

        client = nil
        carrierFilter = CMFIRBandpassFilter(80, 320, CMFsF, 512)
        iFilter = CMFIRLowpassFilter(50, CMFsF / 4, 128)
        qFilter = CMFIRLowpassFilter(50, CMFsF / 4, 128)
        carrierVco = CMPCO()
        fc = 200.0
        fl = 150
        fh = 250
        fd = 0.0
        carrierVco.setCarrier(fc)
        cyclesSinceAdjust = 1000
        excessDelta = 0

        //  signal filters (oversampled by 2)
        let low = fc + 50.0
        let high = fc + 4500.0
        let bw = (high - low) * 0.50
        sidebandFilter = CMFIRBandpassFilter(low, high, CMFsF * 2, 512)
        iAudioFilter = CMFIRLowpassFilter(bw, CMFsF * 2, 256)
        qAudioFilter = CMFIRLowpassFilter(bw, CMFsF * 2, 256)

        outputFilter = CMFIRLowpassFilter(high * 0.9 - low, CMFsF * 2, 256)

        fshift = (high + low) * 0.5
        downshiftVco = CMPCO()
        downshiftVco.setCarrier(fshift * 0.5)

        upshiftVco = CMPCO()
        upshiftVco.setCarrier((fshift - fc) * 0.5)                   //  downShift - upShift = carrier frequency

        volume = 0.01

        var range = [ParametricRange](repeating: ParametricRange(low: 0, high: 0, value: 0), count: 5)
        range[0].low =         0.0 ; range[0].high =  150.0 ; range[0].value = 1.0
        range[1].low = range[0].high ; range[1].high =  300.0 ; range[1].value = 1.0
        range[2].low = range[1].high ; range[2].high =  600.0 ; range[2].value = 1.0
        range[3].low = range[2].high ; range[3].high = 1200.0 ; range[3].value = 1.0
        range[4].low = range[3].high ; range[4].high = 2400.0 ; range[4].value = 1.0

        equalizer = range.withUnsafeMutableBufferPointer {
            ParametricEqualizer($0.baseAddress, ranges: 5, order: 256)
        }
        eqFilter = equalizer.filter()
        equalizerEnable = false
    }

    @objc(setClient:)
    func setClient(_ owner: SynchAM?) {
        client = owner
    }

    @objc func carrier() -> Float {
        return fc
    }

    @objc(setTrack:low:high:)
    func setTrack(_ carrier: Float, low: Float, high: Float) {
        fc = carrier
        fl = low
        fh = high
        CMUpdateFIRBandpassFilter(carrierFilter, low - 10, high + 10)
    }

    @objc(setEqualizerEnable:)
    func setEqualizerEnable(_ state: Bool) {
        equalizerEnable = state
    }

    //  perform a CMFIR filter on Swift Float buffers
    @inline(__always)
    private func performFIR(_ fir: UnsafeMutablePointer<CMFIR>?, _ input: inout [Float], _ n: Int32, _ output: inout [Float]) {
        input.withUnsafeMutableBufferPointer { ip in
            output.withUnsafeMutableBufferPointer { op in
                CMPerformFIR(fir, ip.baseAddress, n, op.baseAddress)
            }
        }
    }

    @objc(importData:)
    func importData(_ pipe: CMPipe) {
        guard let stream = pipe.stream() else { return }
        let dataIn = stream.pointee.array          //  float* input (512 samples)

        var demod = [Float](repeating: 0, count: 512)
        var interpolatedBuf = [Float](repeating: 0, count: 1024)
        var sidebandBuf = [Float](repeating: 0, count: 1024)
        var shiftedBufI = [Float](repeating: 0, count: 1024)
        var shiftedBufQ = [Float](repeating: 0, count: 1024)
        var singleSidebandBufI = [Float](repeating: 0, count: 1024)
        var singleSidebandBufQ = [Float](repeating: 0, count: 1024)
        var unshiftedBuf = [Float](repeating: 0, count: 1024)
        var yi = [Float](repeating: 0, count: 128)
        var yq = [Float](repeating: 0, count: 128)
        var iReg = [Float](repeating: 0, count: 128)
        var qReg = [Float](repeating: 0, count: 128)

        //  audio processing (upsample input to CMFs (11025)*2)
        for i in 0..<512 {
            let j = i * 2
            interpolatedBuf[j] = dataIn![i]
            interpolatedBuf[j + 1] = dataIn![i]
        }
        //  interpolation filter and remove carrier
        performFIR(sidebandFilter, &interpolatedBuf, 1024, &sidebandBuf)

        //  shift passband down
        for i in 0..<1024 {
            let input = sidebandBuf[i]
            let mVfo = downshiftVco.nextVCOPair()
            shiftedBufI[i] = mVfo.re * input
            shiftedBufQ[i] = mVfo.im * input
        }
        //  apply lowpass to extract a single sideband
        performFIR(iAudioFilter, &shiftedBufI, 1024, &singleSidebandBufI)
        performFIR(qAudioFilter, &shiftedBufQ, 1024, &singleSidebandBufQ)

        //  shift passband back up, and form real signal again
        for i in 0..<1024 {
            let mVfo = upshiftVco.nextVCOPair()
            unshiftedBuf[i] = mVfo.re * singleSidebandBufI[i] + mVfo.im * singleSidebandBufQ[i]
        }
        //  lowpass output into sidebandBuf
        performFIR(outputFilter, &unshiftedBuf, 1024, &sidebandBuf)

        //  apply equalizer if needed
        if equalizerEnable {
            performFIR(eqFilter, &sidebandBuf, 1024, &interpolatedBuf)
            for i in 0..<512 { demod[i] = interpolatedBuf[i * 2] * volume }
        } else {
            for i in 0..<512 { demod[i] = sidebandBuf[i * 2] * volume }
        }

        demod.withUnsafeMutableBufferPointer { op in
            client?.setOutput(op.baseAddress, samples: 512)
        }

        //  carrier processing
        sidebandBuf.withUnsafeMutableBufferPointer { op in
            CMPerformFIR(carrierFilter, dataIn, 512, op.baseAddress)
        }

        //  mix and subsample by 8
        var j = 0
        for i in 0..<512 {
            let x = sidebandBuf[i]
            let mVfo = carrierVco.nextVCOPair()
            if i == j * 4 {
                yi[j] = mVfo.re * x
                yq[j] = mVfo.im * x
                j += 1
            }
        }

        // yi and yq are subsampled by 4 (128 samples)
        performFIR(iFilter, &yi, 128, &singleSidebandBufI)
        performFIR(qFilter, &yq, 128, &singleSidebandBufQ)

        //  hold off adjusting for a few cycles for VCO to settle.
        //  C: if ( cyclesSinceAdjust++ > 6 ) -- compare the pre-increment value,
        //  then increment unconditionally.
        let settled = cyclesSinceAdjust > 6
        cyclesSinceAdjust += 1
        if settled {

            //  track magnitude of signal
            var mag: Float = 0.00001
            for i in 0..<128 {
                let br = singleSidebandBufI[i]
                let bq = singleSidebandBufQ[i]
                mag += br * br + bq * bq
            }
            mag /= 128.0

            //  wait for vco/sampling to settle down after each change before measuring again
            //  IIR differentiator using Al-Alaoui's 1994 algorithm
            //	http://mechatronics.ece.usu.edu/yqchen/dd/AL_Ala4.pdf
            for i in 18..<102 {
                iReg[i] = singleSidebandBufI[i] - 0.5358 * singleSidebandBufI[i + 1] - 0.0718 * singleSidebandBufI[i + 2]
                qReg[i] = singleSidebandBufQ[i] - 0.5358 * singleSidebandBufQ[i + 1] - 0.0718 * singleSidebandBufQ[i + 2]
            }

            //  find average frequency in frame
            //  avergae freq deviation approx 0.00077 ticks/Hz
            var freq: Float = 0
            for i in 20..<100 {
                let iDot = iReg[i + 2] - iReg[i]
                let qDot = qReg[i + 2] - qReg[i]
                let br = iReg[i + 1]
                let bq = qReg[i + 1]
                freq += (bq * iDot - br * qDot)
            }
            freq *= 1.0 / (0.00077 * 80.0 * mag)
            freq += excessDelta * 0.5
            excessDelta = 0.75 * freq

            let ft = fc - freq * 0.25
            if ft > fl && ft < fh {
                fc = ft
                carrierVco.setCarrier(fc)
                upshiftVco.setCarrier((fshift - fc) * 0.5)                       //  factor of 2 from oversampling
                cyclesSinceAdjust = (client?.setLock(freq, freq: fc) ?? 0) > 1 ? -12 : 0    // check less often if in lock
            }
        }
    }

    @objc(setVolume:)
    func setVolume(_ value: Float) {
        volume = value * 2.0
    }

    @objc(setEqualizer:value:)
    func setEqualizer(_ freq: Int32, value v: Float) {
        let index: Int32
        switch freq {
        case 300:
            index = 0
        case 600:
            index = 1
        case 1200:
            index = 2
        case 2400:
            index = 3
        case 4800:
            index = 4
        default:
            return
        }
        equalizer.setRange(index, to: v)
    }
}
