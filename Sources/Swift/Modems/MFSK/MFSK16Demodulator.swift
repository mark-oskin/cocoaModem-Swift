//
//  MFSK16Demodulator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 7/16/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of MFSK16Demodulator.m.
//

import Cocoa
import Accelerate

//  tone weights in gray code
private let grayDecode: [Int32] = [
    0x0, 0x1, 0x3, 0x2,
    0x6, 0x7, 0x5, 0x4,
    0xc, 0xd, 0xf, 0xe,
    0xa, 0xb, 0x9, 0x8
]

@objc(MFSK16Demodulator)
class MFSK16Demodulator: MFSKDemodulator {

    override init() {
        super.init()

        //  clock recovery (32 bins)
        clockExtractFFT = FFTForward(5, true /*window*/)
        //  N clock cycles of extraction kernel (each cycle is 32 samples)
        clockExtractionCycles = 15
        prevClock = 0.0
        clockExtractFilter = CMFIRLowpassFilter(4, 500, clockExtractionCycles * 32)
        let n = Int(clockExtractionCycles * 32)
        for i in 0..<n {
            let v = Float(-cos(Double(i) * 3.1415926535 / 16.0))
            clockExtractFilter.pointee.kernel[i] = v
            clockExtractKernel[i] = v
        }
        resetDemodulatorState()
    }

    override func setInterleaverStages(_ stages: Int32) {
        interleaverStages = 10
    }

    //  24 bins decoded from the raw signal, the 16 (18 for Domino) desired bins should be within this set.
    //  Wait until the highest received bin is 15 bins (17 for Domino) higher than the lowest; buffer input meanwhile.
    //  Returns the lowest bin chosen or zero if not yet locked.
    func newFreqVector(_ vector: UnsafeMutablePointer<Float>) -> Int32 {
        var lowest: Int32 = 0                       //  v0.73
        var searchVector = [Float](repeating: 0, count: 24)

        //  Keep constant track of the range of bins received; fast attack slow decay per bin.
        var maxv: Float = 0.001
        for i in 0..<24 {
            let v: Float
            if vector[i] > smoothedVector[i] {
                v = smoothedVector[i] * 0.5 + vector[i] * 0.5
            } else {
                v = smoothedVector[i] * 0.98 + vector[i] * 0.02
            }
            searchVector[i] = v
            smoothedVector[i] = v
            if v > maxv { maxv = v }
        }

        maxv = 1.0 / maxv
        var count: Int32 = 0
        for i in 0..<24 {
            searchVector[i] *= maxv
            if searchVector[i] > 0.1 { count += 1 } else { searchVector[i] = 0 }   //  v0.73 threshold
        }

        var delta: Int32 = 0
        if count > 2 {
            //  search for up to m largest ones (m = 16 for MFSK16, 18 for DominoEX-16,...)
            var highest: Int32 = 0
            lowest = 24
            for _ in 0..<Int(m) {
                var mv: Float = 0.0
                var index: Int32 = 0
                //  find surviving member
                for j in 0..<24 {
                    let v = searchVector[j]
                    if v > mv { mv = v; index = Int32(j) }
                }
                if mv < 0.01 { break }               //  finished search
                searchVector[Int(index)] = -1
                if index > highest { highest = index }
                if index < lowest { lowest = index }
            }
            delta = highest - lowest
        }

        lowestAFCBin = (delta == (m - 1)) ? lowest : -1

        if afcState == 1 {
            //  AFC is turned on.  Stay in sync while fewer than m bins separate the above-threshold bins.
            if delta >= m {
                hasSync = false
            } else {
                if hasSync {
                    hasSync = (count > 3)
                } else {
                    hasSync = (delta == (m - 1) && count >= 12)
                }
            }
        } else {
            //  AFC is either turned off or on hold
            if afcState == 0 {
                //  AFC off: use central 16 bins (if on hold, maintain the most recent AFC bin)
                lowestAFCBin = 5
            }
            lowest = lowestAFCBin
        }
        if delta == (m - 1) && count > 3 {
            //  candidate lowest/highest (plus two in between) bins identified; update UI
            updateRxFreqLabelAndField(lowestAFCBin)

            //  assume still in sync if delta is 15 and at least 4 bins recently touched
            if hasSync || count > 4 {
                //  intermediate bins all active, flush saved data
                while bufferedFreqConsumer != bufferedFreqProducer {
                    decodeBins(bufferedFreqBins + Int(bufferedFreqConsumer) * 24 + Int(lowest), buffered: true)
                    bufferedFreqConsumer = (bufferedFreqConsumer + 1) % 0xff
                }
                //  send most recent data
                decodeBins(vector + Int(lowest), buffered: false)
                //  reset the buffer pointers for the next time we are out of range
                bufferedFreqProducer = 0
                bufferedFreqConsumer = 0
                return lowestAFCBin
            }
        }
        //  Have not yet established a frequency range to decode the bins, buffer them up for now.
        //  v0.73 sanity check before buffering (delta > 1 confirms a DominoEX df = 2)
        if lowest > 0 && delta > 1 {
            if delta >= m {
                //  delta wider than MFSK range?
                bufferedFreqProducer = 0
                bufferedFreqConsumer = 0
            } else {
                let base = Int(bufferedFreqProducer) * 24
                for i in 0..<24 { bufferedFreqBins[base + i] = vector[i] }
                bufferedFreqProducer = (bufferedFreqProducer + 1) & 0xff
                if bufferedFreqProducer == bufferedFreqConsumer {
                    //  Overrun.  Keep only the most recent 256 values
                    bufferedFreqConsumer = (bufferedFreqConsumer + 1) & 0xff
                }
            }
        }
        return 0
    }

    //  Accepts a new vector of 32 (or 64) data samples aligned to the symbol clock and creates the frequency alignment.
    //  For MFSK16, length is assumed to always be 32.
    override func afcVector(_ vector: UnsafeMutablePointer<DSPSplitComplex>, length: Int32) {
        let vi = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let vq = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let iSpec = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let qSpec = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let iOrderedSpectrum = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let qOrderedSpectrum = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let powerSpectrum = UnsafeMutablePointer<Float>.allocate(capacity: 384)
        defer {
            vi.deallocate(); vq.deallocate(); iSpec.deallocate(); qSpec.deallocate()
            iOrderedSpectrum.deallocate(); qOrderedSpectrum.deallocate(); powerSpectrum.deallocate()
        }

        var input = DSPSplitComplex(realp: vi, imagp: vq)
        var output = DSPSplitComplex(realp: iSpec, imagp: qSpec)

        //  Zero fill and apply a 512 point FFT for a higher resolution spectrum.
        for i in 0..<32 {
            vi[i] = vector.pointee.realp[i]
            vq[i] = vector.pointee.imagp[i]
        }
        for i in 32..<512 { vi[i] = 0.0; vq[i] = 0.0 }
        input.realp = vi
        input.imagp = vq
        output.realp = iSpec
        output.imagp = qSpec
        CMPerformComplexFFT(afcFFT, &input, &output)
        //  512 point ordered spectrum from lowest to highest frequency
        for i in 0..<512 {
            let j = (i + 256) % 512
            iOrderedSpectrum[i] = iSpec[j]
            qOrderedSpectrum[i] = qSpec[j]
        }

        //  afcState = 0 no AFC; 1 perform AFC; 2 hold afc
        if afcState == 1 {
            //  find the offset of the global peak; v0.73 sum 11 bins instead of the tallest bin
            var offset: Int32 = 5
            var peak: Float = -1
            for i in 0..<(512 - 11) {
                var u: Float = 0
                var v: Float = 0
                for k in 0..<11 {
                    u += iOrderedSpectrum[i + k]
                    v += qOrderedSpectrum[i + k]
                }
                u = u * u + v * v
                if u > peak { peak = u; offset = Int32(i + 5) }
            }
            //  fold the offset (reduce it to offset within a bit width)
            offset = offset % 16

            //  accomodate DominoEX which uses offset as the "current" tone
            var diff = (offset - absoluteOffset + 1024) % 16
            if diff >= 8 { diff = diff - 16 }

            correction = correction * 0.75 + Float(diff) * 0.25
            absoluteOffset = mfskTruncInt(Double(Float(absoluteOffset) + correction))
        } else {
            if afcState == 0 { absoluteOffset = 48 }
        }

        //  Resample the spectrum at the absolute offset to get 24 samples.
        for i in 0..<24 {
            let j = Int(i) * 16 + Int(absoluteOffset) - 6                    //  v0.73
            var u: Float = 0
            var v: Float = 0
            for k in 0..<13 {
                u += iOrderedSpectrum[k + j]
                v += qOrderedSpectrum[k + j]
            }
            iSpec[i] = u * u + v * v
        }
        //  16 of these 24 bins are the actual data
        let binOffset = newFreqVector(iSpec)

        //  output to tuning indicator
        if freqIndicator != nil {
            for i in 0..<384 {
                let u = iOrderedSpectrum[i + Int(MFSKFREQOFFSET)]
                let v = qOrderedSpectrum[i + Int(MFSKFREQOFFSET)]
                powerSpectrum[i] = u * u + v * v
            }
            freqIndicator?.newSpectrum(powerSpectrum)
            var bo = binOffset
            if bo <= 0 { bo = 0 }
            updateRxFreqLabelAndField(bo)
        }
    }

    //  Convert an array of 16 frequency bins into a 4 bit gray-coded index.
    //  Each of the 4 bits is returned as a float between 0 and 1.0, for soft decoding.
    override func softEncode(_ vector: UnsafeMutablePointer<Float>) -> QuadBits {
        var result = QuadBits()

        //  vector[0..15] is the range.  initialize to bin 0
        result.bit[0] = 0.0; result.bit[1] = 0.0; result.bit[2] = 0.0; result.bit[3] = 0.0

        //  check CNR: find largest vector
        var maxv = vector[0]
        var index = 0
        for i in 1..<16 {
            let v = vector[i]
            if v > maxv { maxv = v; index = i }
        }
        var noisev: Float = 0
        for i in 0..<16 {
            if i != index { noisev += vector[i] }
        }
        noisev = noisev / 15
        //  normalize noise to 1 Hz noise bandwidth, apply delay and then smooth
        let v = maxv / ((noisev + 0.000001) * 3)
        //  Estimate carrier to noise ratio (delayed through a 64 stage delay line)
        cnrCycle &= 0x3f
        delayedCNR[Int(cnrCycle)] = v
        cnrCycle += 1
        cnr = cnr * 0.92 + v * 0.08

        if !softDecode {
            //  hard decoder: use largest vector as 4 bit code word
            let largest = grayDecode[index]
            result.bit[0] = (largest & 0x8) != 0 ? 1.0 : 0.0
            result.bit[1] = (largest & 0x4) != 0 ? 1.0 : 0.0
            result.bit[2] = (largest & 0x2) != 0 ? 1.0 : 0.0
            result.bit[3] = (largest & 0x1) != 0 ? 1.0 : 0.0
        } else {
            //  soft decoder: factor of 1.35 arrived at empirically with Gaussian noise
            var mappedVector = [Float](repeating: 0, count: 16)
            for i in 0..<16 {
                let vv = vector[i]
                mappedVector[Int(grayDecode[i])] = powf(vv, 1.35)
            }
            //  normalize input vector into probabilities
            var u: Float = 0.0000001
            for i in 0..<16 { u += mappedVector[i] }
            for i in 0..<16 { mappedVector[i] /= u }

            var accum0: Float = 0, accum1: Float = 0, accum2: Float = 0, accum3: Float = 0
            for i in 0..<16 {
                let pr = mappedVector[i]
                if i & 0x8 != 0 { accum0 += pr }
                if i & 0x4 != 0 { accum1 += pr }
                if i & 0x2 != 0 { accum2 += pr }
                if i & 0x1 != 0 { accum3 += pr }
            }
            result.bit[0] = accum0
            result.bit[1] = accum1
            result.bit[2] = accum2
            result.bit[3] = accum3
        }
        return result
    }

    //  added v0.73
    @objc(decodeBins:buffered:) func decodeBins(_ vector: UnsafeMutablePointer<Float>, buffered state: DarwinBoolean) {
        decodeBits(softEncode(vector))
    }

    //  Concatenated deinterleaver of 10 stages of the IZ8BLY Diagonal Interleaver
    //  (single 160-unit linear table).
    override func deinterleave(_ p: QuadBits) -> QuadBits {
        var quad = QuadBits()

        //  fetch the four deinterleaved bits before overwriting some with the new data
        for i in 0..<4 { quad.bit[i] = interleaverRegister[(Int(interleaverIndex) + i * 41) % 160] }
        //  insert new bits into register
        for i in 0..<4 { interleaverRegister[Int(interleaverIndex) + i] = p.bit[i] }
        //  increment the pointer for the next QuadBits set
        interleaverIndex = (interleaverIndex + 4) % 160

        return quad
    }
}
