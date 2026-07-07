//
//  MFSKReceiverFrontEnd.swift
//  CoreDSP
//
//  Fresh glue class, NOT a verbatim transplant.  The old MFSKReceiver.swift
//  (base of MFSK16Receiver / DominoReceiver) mixed the incoming 11025 Hz audio
//  down to baseband with a VCO tuned near the requested tone, lowpass-filtered
//  it, and nearest-neighbor-resampled it to the demodulator's native 500
//  samples/second, handing 32-sample I/Q blocks to the demodulator -- all of
//  that is genuine DSP (kept verbatim below, from MFSKReceiver.importArray:).
//  What's dropped is the UI/threading baggage the porting brief calls out
//  (CMTappedPipe scope-tap plumbing, the 512-buffer click/history ring used to
//  rewind the waterfall, and enable/disable flags wired to app UI) -- none of
//  that changes the signal path, so this keeps the exact tone spacing / baud
//  rate / decimation-ratio behavior with a much smaller surface.
//
//  MFSKModes.h's CARRIEROFFSET (125 Hz -- the carrier offset relative to the
//  first FFT bin) is reproduced here since it only mattered for receiver
//  tuning math.
//

import Foundation

private let CARRIEROFFSET: Float = 125.0

final class MFSKReceiverFrontEnd {

    let demodulator: MFSKDemodulator

    //  mixer
    var vco: CMPCO
    var receiveFrequency: Float = 0
    let iMixer = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    let qMixer = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    var decimationRatio: Float
    var nextSample: Float = 150
    var outputIndex: Int32 = 0
    var iFilter: UnsafeMutablePointer<CMFIR>
    var qFilter: UnsafeMutablePointer<CMFIR>
    //  IF filtered buffer
    let iOutput = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    let qOutput = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    let iBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 32)
    let qBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 32)
    //  sideband
    var sidebandState: Bool = true      //  YES = USB

    init(demodulator: MFSKDemodulator) {
        self.demodulator = demodulator

        iMixer.initialize(repeating: 0, count: 512)
        qMixer.initialize(repeating: 0, count: 512)
        iOutput.initialize(repeating: 0, count: 512)
        qOutput.initialize(repeating: 0, count: 512)
        iBuffer.initialize(repeating: 0, count: 32)
        qBuffer.initialize(repeating: 0, count: 32)

        //  set up VCO at tone's frequency
        receiveFrequency = 972.0 + CARRIEROFFSET
        vco = CMPCO()
        vco.setCarrier(receiveFrequency)

        //  input decimation
        decimationRatio = Float(CMFs / 500.0)
        nextSample = 150
        outputIndex = 0
        iFilter = CMFIRLowpassFilter(210, Float(CMFs), 512)
        qFilter = CMFIRLowpassFilter(210, Float(CMFs), 512)
    }

    deinit {
        CMDeleteFIR(iFilter)
        CMDeleteFIR(qFilter)
        iMixer.deallocate()
        qMixer.deallocate()
        iOutput.deallocate()
        qOutput.deallocate()
        iBuffer.deallocate()
        qBuffer.deallocate()
    }

    func setSidebandState(_ state: Bool) {
        sidebandState = state
        demodulator.setSidebandState(state)
    }

    //  the 125 Hz offset "centers" the tone group inside the demodulator's
    //  24-bin capture window.
    func selectFrequency(_ freq: Float, fromWaterfall clicked: Bool) {
        if sidebandState {
            //  USB
            receiveFrequency = freq + CARRIEROFFSET
        } else {
            receiveFrequency = freq - CARRIEROFFSET
        }
        vco.setCarrier(receiveFrequency)
        if clicked {
            //  don't reset demodulator if it is a scroll wheel operation
            demodulator.resetDemodulatorState()
        }
    }

    //  import 512 samples at 11025 s/s, mix + decimate to 500 s/s, hand off
    //  32-sample blocks to the demodulator.
    func importArray(_ array: UnsafeMutablePointer<Float>) {
        if sidebandState == true {
            //  USB
            for i in 0..<512 {
                let v = array[i]
                let pair = vco.nextVCOPair()
                iMixer[i] = pair.re * v
                qMixer[i] = pair.im * v
            }
        } else {
            //  LSB -- reverse spectrum around DC
            for i in 0..<512 {
                let v = array[i]
                let pair = vco.nextVCOPair()
                iMixer[i] = pair.re * v
                qMixer[i] = -pair.im * v
            }
        }
        //  Apply lowpass to I and Q channels
        CMPerformFIR(iFilter, iMixer, 512, iOutput)
        CMPerformFIR(qFilter, qMixer, 512, qOutput)

        for _ in 0..<512 {
            //  resample the lowpass filtered I.F. using nearest neighbor
            let n = Int(nextSample)
            if n > 511 {
                nextSample -= 512
                break
            }
            if n < 511 {
                let fract = nextSample - Float(n)
                iBuffer[Int(outputIndex)] = iOutput[n] * (1 - fract) + iOutput[n + 1] * fract
                qBuffer[Int(outputIndex)] = qOutput[n] * (1 - fract) + qOutput[n + 1] * fract
            } else {
                iBuffer[Int(outputIndex)] = iOutput[n]
                qBuffer[Int(outputIndex)] = qOutput[n]
            }
            nextSample += decimationRatio
            outputIndex += 1
            if outputIndex >= 32 {
                //  send 32 samples to demodulator
                demodulator.newBuffer(iBuffer, imag: qBuffer)
                outputIndex = 0
            }
        }
    }
}
