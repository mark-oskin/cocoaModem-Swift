//
//  DominoHalfRateDemodulator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 7/4/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of DominoHalfRateDemodulator.m.
//

import Cocoa
import Accelerate

@objc(DominoHalfRateDemodulator)
class DominoHalfRateDemodulator: DominoDemodulator {

    private var inputMux: Int32 = 0
    private var codes = [Int32](repeating: 0, count: 16)
    private var previousCode: Int32 = 0
    private var nibbles: Int32 = 0

    //  Half Rate DominoEX
    @objc(initAsMode:) convenience init(asMode mode: Int32) {
        self.init(asDomino: mode)
        inputMux = 0
        previousCode = 256
        nibbles = 0

        //  clock recovery (64 bins)
        clockExtractFFT = FFTForward(6, false /* window */)

        //  N clock cycles of extraction kernel (each cycle is 64 samples)
        clockExtractionCycles = 2 * 6                        //  must be even number to represent 64 sample cycles
        prevClock = 0.0

        clockExtractFilter = CMFIRLowpassFilter(4, 500, clockExtractionCycles * 32)
        //  4 extra cycles for fading
        let n = Int(clockExtractionCycles * 32)
        for i in 0..<n {
            let v = Float(-cos(Double(i) * 3.1415926535 / 32.0))
            clockExtractFilter.pointee.kernel[i] = v
            clockExtractKernel[i] = v
        }
        waterfallClicked()
        resetDemodulatorState()
    }

    //  New buffer of 32 complex samples arrived (500 samples/second).  For half rate
    //  DominoEX we accumulate 64 samples before looking for symbol sync.
    //  -newBuffer:: finds the time alignment and -afcVector: finds the frequency alignment.
    override func newBufferedData(_ iBuf: UnsafeMutablePointer<Float>, imag qBuf: UnsafeMutablePointer<Float>) {
        if iBuf[0] == 0 && qBuf[0] == 0 { return }

        let iSpec = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        let qSpec = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        let track = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        defer { iSpec.deallocate(); qSpec.deallocate(); track.deallocate() }
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

        //  process every other 32-sample buffer, since we need 64 samples at a time
        let pm = inputMux
        inputMux += 1
        if pm < 1 { return }
        inputMux = 0

        //  Find approx time peak by sliding a 64-point window and taking a 64-point FFT for each window.
        for k in 0..<64 {
            let index = (ring + (1024 - 192)) % 1024
            input.realp = iTime + (k + index)
            input.imagp = qTime + (k + index)
            output.realp = iSpec
            output.imagp = qSpec
            //  64 point FFT
            CMPerformComplexFFT(clockExtractFFT, &input, &output)
            //  find bin leakage for non time-synchronized transforms
            var mean: Float = 0
            var maxv: Float = 0
            for i in 0..<64 {
                var v = iSpec[i] * iSpec[i] + qSpec[i] * qSpec[i]
                mean += v
                v = v * v
                if v > maxv { maxv = v }
            }
            if mean < 0.0001 { return }
            maxv = maxv / (mean * mean)
            timeAperture[k] = timeAperture[k] * 0.95 + maxv
        }

        //  apply the (running) lowpassed comb to find the symbol alignment
        CMPerformFIR(clockExtractFilter, timeAperture, 64, track)

        //  Find the zero crossing from the 64 filtered symbol transitions.
        for i in 0..<64 {
            //  look for a zero crossing and then apply offset to the peak (assume cycle of 64)
            if prevClock <= 0 && track[i] > 0 {
                //  found zero crossing, update median filter
                var dt = i
                if abs(prevClock) < track[i] * 1.5 { dt -= 1 }
                let index = (ring + dt + (1024 - 512 + 48)) % 1024   //  offset derived from optimizing DominoEX 8 at -14 dB SNR
                timeOffset = Int32(dt)
                input.realp = iTime + index
                input.imagp = qTime + index
                afcVector(&input, length: 64)
            }
            prevClock = track[i]
        }
    }

    //  (Private API) Differential 18FSK decode.  Input is an array of 16x oversampled frequency bins.
    override func ifskDecode(_ vector: UnsafeMutablePointer<Float>) {
        accumulatedCodes %= 8               //  sanity check

        //  find largest vector for each of the 16 sub-bins and energy
        var largestEnergy: Float = 0
        var subbinWithLargestEnergy: Int32 = 0
        var peakIndex = 0
        for bin in 0..<16 {
            let s = subbin + bin
            var maxv: Float = 0
            var avgv: Float = 0
            var index = 0
            var i = bin
            while i < 512 {
                let v = vector[i]
                avgv += v
                if v > maxv { maxv = v; index = i }
                i += 16
            }
            //  accumulate energy
            s.pointee.energy += maxv
            let v = s.pointee.energy
            if v > largestEnergy {
                largestEnergy = v
                subbinWithLargestEnergy = Int32(bin)
                peakIndex = index
            }
            let idx = ((index + 8) / 16) & 0x1f
            let fecCode = iFSKDecodeVector[idx * 32 + Int(s.pointee.mostRecentBin)]
            s.pointee.code[Int(accumulatedCodes)] = Int16(truncatingIfNeeded: fecCode)
            s.pointee.notDecoded = (fecCode < 0 || fecCode > 15)
            s.pointee.nextRecentBin = s.pointee.mostRecentBin
            s.pointee.bin[Int(accumulatedCodes)] = Int16(truncatingIfNeeded: idx)
            s.pointee.mostRecentBin = Int32(s.pointee.bin[Int(accumulatedCodes)])
        }

        let peak = vector[peakIndex]

        //  estimate carrier to noise ratio
        if peak > 0.000001 {
            var avgv = peak
            var i = peakIndex + 240
            while i < peakIndex + 272 {
                avgv += vector[i % 512]
                i += 1
            }
            avgv /= 32.0

            //  S/(S+N) = 1 when no noise
            if peak > 0.000001 {
                let p = peak / (peak + avgv)
                if p > ssnr { ssnr = ssnr * 0.92 + 0.08 * p } else { ssnr = ssnr * 0.98 + 0.02 * p }

                cnr = cnr * 0.92 + 0.08 * (peak / (avgv + 0.0000001))
            }
        }

        processSubbin(subbinWithLargestEnergy)
    }
}
