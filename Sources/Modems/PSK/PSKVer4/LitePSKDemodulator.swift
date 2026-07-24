//
//  LitePSKDemodulator.swift
//  cocoaModem 2.0  v0.57b
//
//  Created by Kok Chen on 10/19/08.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//  Swift port of LitePSKDemodulator.m.
//

import Cocoa

@objc(LitePSKDemodulator)
class LitePSKDemodulator: NSObject {

    //  States
    private static let kDemodulatorIdle: Int32 = 0
    private static let kDemodulatorAcquire: Int32 = 1
    private static let kDemodulatorStartDecode: Int32 = 2
    private static let kDemodulatorDecode: Int32 = 3

    private var hub: PSKBrowserHub!
    private var state_: Int32 = 0            //  kDemodulatorIdle, etc
    private var frequency_: Float = 0

    private var vco: VCO8k!
    private var decimateFilter: UnsafeMutablePointer<CMComplexFIR>!
    private var input: UnsafeMutablePointer<CMAnalyticBuffer>!
    //  float decimatedI[64], decimatedQ[64]  -> heap buffers (freed in deinit)
    private let decimatedI = UnsafeMutablePointer<Float>.allocate(capacity: 64)
    private let decimatedQ = UnsafeMutablePointer<Float>.allocate(capacity: 64)

    //  clock extraction
    private var comb: UnsafeMutablePointer<CMFIR>!
    private var previousClockSample: Float = 0

    //  matched filter
    private var matchedFilter: LitePSKMatchedFilter!

    //  decoder
    private var varicode: CMVaricode!
    private var varicodeCharacter: Int = 0      //  was C long
    private var decodeOffset: Int32 = 0
    private var disabled_: Bool = false

    //  v0.70
    private var doubleByteIndex: Int32 = 0
    private var doubleByteValue = [Int32](repeating: 0, count: 16)

    // afc
    private var cycle: Int32 = 0
    private var finishedAcquire: Bool = false
    private var acquireCount: Int32 = 0
    private var freqError: Float = 0
    private var freqErrors = [Float](repeating: 0, count: 32)

    //  used by client (for sorting)
    private var userIndex_: Int32 = -1          //  negative if a row has not yet been assigned
    private var uniqueID_: Int32 = 0
    private var removeCount_: Int32 = 0
    private var mark_: Int32 = 0

    //  debug
    private var lastQuality: Float = 0
    private var lastDecoded: Int32 = 0

    @objc(initWithClient:uniqueID:)
    init(client: PSKBrowserHub, uniqueID uid: Int32) {
        super.init()
        decimatedI.initialize(repeating: 0, count: 64)
        decimatedQ.initialize(repeating: 0, count: 64)

        hub = client
        frequency_ = 0
        state_ = LitePSKDemodulator.kDemodulatorIdle
        uniqueID_ = uid
        userIndex_ = -1             // negative if a row in the TableViews has not yet been assigned
        decodeOffset = 0
        mark_ = 0
        doubleByteIndex = 0

        removeCount_ = 0
        // VCO
        vco = VCO8k()
        vco.setCarrier(frequency_)
        //  decimation filter (8000 s/s input, 1000 s/s output)
        decimateFilter = CMComplexFIRDecimateWithCutoff(8, 31.25 * 0.91, 8000.0, 512)
        //  comb filter to extract clock
        previousClockSample = 0.0
        comb = CMFIRCombFilter(31.25, 8000.0 / 8, 2048, 0.1)
        //  Matched filter
        matchedFilter = LitePSKMatchedFilter(client: self)
        matchedFilter.setDelegate(self)
        //  Varicode decoder
        varicode = CMVaricode()
        varicodeCharacter = 0
        //  afc
        cycle = 0
        freqError = 0
        for i in 0..<32 { freqErrors[i] = 0 }
        //  aligned memory for vDSP
        input = CMMallocAnalyticBuffer(16)
    }

    //  The ObjC dealloc had a bug ([ VCO8k release ] released the class, not
    //  the instance); ARC now releases vco/matchedFilter/varicode correctly.
    //  We still free the malloc'd C filters and analytic buffer.
    deinit {
        CMDeleteFIR(comb)
        CMDeleteComplexFIR(decimateFilter)
        freeAnalyticBuffer(input)
        decimatedI.deallocate()
        decimatedQ.deallocate()
    }

    @objc(activateWithFrequency:)
    func activateWithFrequency(_ freq: Float) {
        userIndex_ = -1
        frequency_ = freq
        vco.setCarrier(frequency_)
        state_ = LitePSKDemodulator.kDemodulatorAcquire
        removeCount_ = 0
        disabled_ = false
    }

    @objc(afcToFrequency:)
    func afcToFrequency(_ freq: Float) {
        if disabled_ { return }

        let old = vco.frequency
        frequency_ = frequency_ * 0.7 + freq * 0.3
        if abs(frequency_ - old) > 0.027 /* 10 degrees */ { vco.setCarrier(frequency_) }
    }

    //  return the original userIndex
    @objc func setToIdle() -> Int32 {
        let result = userIndex_

        state_ = LitePSKDemodulator.kDemodulatorIdle
        frequency_ = 0
        userIndex_ = -1
        removeCount_ = 0
        disabled_ = false

        return result
    }

    @objc func uniqueID() -> Int32 {
        return uniqueID_
    }

    @objc func frequency() -> Float {
        return frequency_
    }

    // this is a user settable integer that can be used during searches, etc
    @objc func mark() -> Int32 {
        return mark_
    }

    @objc(setMark:)
    func setMark(_ value: Int32) {
        mark_ = value
    }

    @objc func clearRemoveCount() {
        removeCount_ = 0
    }

    @objc func increaseRemoveCount() -> Int32 {
        removeCount_ += 1
        return removeCount_
    }

    @objc(decreaseRemovalCount:)
    func decreaseRemovalCount(_ amount: Int32) {
        removeCount_ -= amount
        if removeCount_ < 0 { removeCount_ = 0 }
    }

    @objc func removeCount() -> Int32 {
        return removeCount_
    }

    //  I-Q mixer
    //	Input is an array of 512 real samples at 8000 s/s.
    //  Result is placed in the 64 point decimated I/Q buffers where 32 samples represents one chip.
    private func mix(_ array: UnsafeMutablePointer<Float>) {
        for n in 0..<64 {
            let j = n * 8
            for i in 0..<8 {
                let v = array[i + j]
                //  note:the VCO runs at a rate of Fs
                let pair = vco.nextVCOMixedPair(v)
                input.pointee.re[i] = pair.re
                input.pointee.im[i] = pair.im
            }
            let pair = CMDecimateAnalyticBuffer(decimateFilter, input, 0)   //  decimation filter cutoffs are at 100 Hz
            decimatedI[n] = pair.re
            decimatedQ[n] = pair.im
        }
    }

    private func acquire(_ buffer: UnsafeMutablePointer<Float>) {
        //  no rough tune, move to decode immediately
        state_ = LitePSKDemodulator.kDemodulatorStartDecode
        finishedAcquire = false
        acquireCount = 0
        matchedFilter.setPrintEnable(false)
    }

    //  v0.70  adapted to work with Shift-JIS double byte
    //  new bit received from Matched Filter
    @objc(receivedBit:quality:)
    func receivedBit(_ bit: Int32, quality: Float) {
        var quality = quality

        if userIndex_ < -1 { return }

        //  wait for start bit
        if bit == 0 && varicodeCharacter == 0 { return }

        //  wrapping shift-in of the varicode bit; the value is reset to 0 each
        //  time the low two bits become 0, but guard overflow just in case.
        varicodeCharacter = varicodeCharacter &* 2 &+ Int(bit)

        if (varicodeCharacter & 0x3) == 0 && varicodeCharacter != 0 {

            if (varicodeCharacter & 0xffffc000) == 0 {
                var c = Int32(varicode.decode(Int32(truncatingIfNeeded: varicodeCharacter))) & 0xff
                lastDecoded = c
                lastQuality = quality

                let useShiftJIS = hub.useShiftJIS()

                if c != 0 || useShiftJIS {
                    //  start only when quality is good
                    if userIndex_ < 0 && quality > 0.5 {
                        hub.demodulator(self, startingAtFrequency: frequency_)
                    }

                    if userIndex_ >= 0 {

                        if useShiftJIS {
                            if doubleByteIndex == 0 {
                                //  validate that it is the first byte of Shift-JIS
                                var isShiftJISCharacter = true
                                if !(c >= 0x81 && c <= 0x84) {
                                    if !(c >= 0x87 && c <= 0x9f) {
                                        if !(c >= 0xe0 && c <= 0xea) {
                                            if !(c >= 0xed && c <= 0xee) { isShiftJISCharacter = false }
                                        }
                                    }
                                }
                                if isShiftJISCharacter == false && c != 0 {
                                    //  Not a first byte for Shift-JIS, decode as ASCII
                                    if c == 0x09 || c == 0x0d || c == 0x0a { c = 0x20 }   // \t \r \n -> space
                                    hub.demodulator(self, newCharacter: c, quality: quality, frequency: frequency_)
                                    quality = 1.0
                                    varicodeCharacter = 0
                                    return
                                }
                                //  buffer up the first byte of a double byte character
                                doubleByteValue[0] = c
                                doubleByteIndex += 1
                            } else {
                                c = doubleByteValue[0] * 256 + c
                                doubleByteIndex = 0
                                if c == 0x09 || c == 0x0d || c == 0x0a { c = 0x20 }
                                hub.demodulator(self, newCharacter: c, quality: quality, frequency: frequency_)
                            }
                            quality = 1.0
                            varicodeCharacter = 0
                            return
                        }
                        //  not useShiftJIS
                        if c == 0x09 || c == 0x0d || c == 0x0a { c = 0x20 }
                        hub.demodulator(self, newCharacter: c, quality: quality, frequency: frequency_)
                    }
                }
            } else {
                removeCount_ += 1
            }

            quality = 1.0
            varicodeCharacter = 0
        }
    }

    @objc func quality() -> Float {
        return lastQuality
    }

    @objc func decoded() -> Int32 {
        return lastDecoded
    }

    //  each call has 32 samples of baseband I/Q signal at 1000 samples per second
    private func processChipBuffer(_ inphase: UnsafeMutablePointer<Float>, quadrature: UnsafeMutablePointer<Float>) {
        for i in 0..<32 {
            let pi = inphase[i]
            let pq = quadrature[i]
            let mag = pi * pi + pq * pq + 0.00001
            let clockSample = CMSimpleFilter(comb, mag)
            let bitSync = (previousClockSample < 0 && clockSample >= 0)
            previousClockSample = clockSample

            _ = matchedFilter.bpsk(pi, imag: pq, bitSync: bitSync)

            if bitSync {

                //  afc track only every 16 chips, except for acquisition stage
                cycle = (cycle + 1) % 16
                if !finishedAcquire { cycle = 0 }

                let fe = (31.25 / (3.1415926 * 2)) * matchedFilter.phaseError()
                freqErrors[Int(cycle)] = fe
                freqError += fe

                if cycle == 0 {

                    if !finishedAcquire {
                        acquireCount += 1
                        if acquireCount > 4 {
                            matchedFilter.setPrintEnable(true)
                            finishedAcquire = true
                        }
                    }
                    var tune = -freqError * (3.1415926 * 0.5 / 16)      //  average data from collected chip
                    //  look for quality of phase error
                    var minerr = freqErrors[0]
                    var maxerr = freqErrors[0]
                    for e in 1..<16 {
                        if freqErrors[e] > maxerr { maxerr = freqErrors[e] }
                        if freqErrors[e] < minerr { minerr = freqErrors[e] }
                    }
                    var deltaerr = maxerr - minerr
                    if deltaerr < 1 { deltaerr = 1 }
                    //  adjust AFC correction term base on phase error quality
                    tune = tune / powf(deltaerr, 0.8)
                    if tune > 0.5 { tune = 0.5 } else if tune < -0.5 { tune = -0.5 }

                    if abs(tune) > 0.05 {
                        vco.tune(tune)
                        //  update demodulator frequency
                        frequency_ = vco.frequency
                    }
                    freqError = 0
                }
            }
        }
    }

    //  This is where the data arrives.
    //  Buffers are 512 samples in length, at a sampling rate of 8000 s/s.
    @objc(decode:offset:)
    func decode(_ buffer: UnsafeMutablePointer<Float>, offset index: Int32) {
        if disabled_ { return }

        if state_ == LitePSKDemodulator.kDemodulatorAcquire {
            let currentBuf = buffer + Int(index) * 512
            acquire(currentBuf)
            decodeOffset = (index - 40 + 64) % 64       //  40 buffers worth of click buffer.
            return
        }
        // return if state is not in decode
        if frequency_ < 10 {
            return
        }
        if state_ == LitePSKDemodulator.kDemodulatorStartDecode {
            decodeOffset %= 64
            var currentBuf = buffer + Int(decodeOffset) * 512
            mix(currentBuf)
            processChipBuffer(decimatedI, quadrature: decimatedQ)
            processChipBuffer(decimatedI + 32, quadrature: decimatedQ + 32)
            if decodeOffset == index {
                state_ = LitePSKDemodulator.kDemodulatorDecode      //  caught up with mini-click buffer
                return
            }
            decodeOffset = (decodeOffset + 1) % 64

            currentBuf = buffer + Int(decodeOffset) * 512
            mix(currentBuf)
            processChipBuffer(decimatedI, quadrature: decimatedQ)
            processChipBuffer(decimatedI + 32, quadrature: decimatedQ + 32)
            if decodeOffset == index { state_ = LitePSKDemodulator.kDemodulatorDecode }   //  caught up with mini-click buffer
            decodeOffset = (decodeOffset + 1) % 64
            return
        }
        //  State is kDemodulatorDecode, Decimate and decode current buffer
        let currentBuf = buffer + Int(index) * 512
        mix(currentBuf)
        processChipBuffer(decimatedI, quadrature: decimatedQ)
        processChipBuffer(decimatedI + 32, quadrature: decimatedQ + 32)
    }

    @objc func userIndex() -> Int32 {
        return userIndex_
    }

    @objc(setUserIndex:)
    func setUserIndex(_ index: Int32) {
        userIndex_ = index
    }

    @objc func state() -> Int32 {
        return state_
    }

    @objc func disabled() -> DarwinBoolean {
        return DarwinBoolean(disabled_)
    }

    @objc(setDisabled:)
    func setDisabled(_ d: DarwinBoolean) {
        disabled_ = d.boolValue
    }
}
