//
//  FAXReceiver.swift
//  CoreDSP
//
//  Swift port of FAXReceiver.m/.swift (old cocoaModem). A CMToneReceiver that
//  FM-demodulates the HF-FAX signal (centered at 1900 Hz) into a bipolar
//  brightness value per input sample. DSP-critical: exact filter bandwidths,
//  the soft-limiter (pow 0.45), the Al-Alaoui IIR differentiator coefficients
//  and the slow AGC are all preserved verbatim.
//
//  Threading change from the original: the old FAXReceiver pushed incoming
//  audio into a DataPipe and pulled/demodulated it on a background Thread
//  (Thread.detachNewThreadSelector...). CoreDSP is a synchronous, headless DSP
//  module (see CMPSKDemodulator.importData for the established precedent in
//  this package) and ModemEngine already calls receiveSamples off the audio
//  thread -- so importData(_:) now runs the exact same demodulation math
//  in-line, synchronously, once per 512-sample buffer. No DataPipe, no Thread.
//
//  The original ivar "client" (a Modem*) and the "view" (FAXDisplay*) ivar --
//  both Cocoa/UI-coupled -- are replaced by a plain Swift delegate protocol
//  (FAXReceiverDelegate) that receives one demodulated Float per input sample,
//  exactly what -view?.addPixel(freq) did.
//

import Foundation
import Accelerate

/// Receives one demodulated FAX brightness sample per input audio sample.
/// Bipolar, black about -0.23, white about +0.23 (mirrors the old
/// FAXDisplay.addPixel(_:) input contract).
public protocol FAXReceiverDelegate: AnyObject {
    func faxReceiverDidDemodulate(_ value: Float)
}

public extension FAXReceiverDelegate {
    func faxReceiverDidDemodulate(_ value: Float) {}
}

final class FAXReceiver: CMToneReceiver {

    weak var delegate: FAXReceiverDelegate?

    //  agc
    private var agc: Float = 0

    //  decimating filter
    private var iFilter: UnsafeMutablePointer<CMFIR>!
    private var qFilter: UnsafeMutablePointer<CMFIR>!
    private var inputBandpassFilter: UnsafeMutablePointer<CMFIR>!
    private var limiterBandpassFilter: UnsafeMutablePointer<CMFIR>!
    //  filter bands
    private var iFilterN = [UnsafeMutablePointer<CMFIR>?](repeating: nil, count: 3)
    private var qFilterN = [UnsafeMutablePointer<CMFIR>?](repeating: nil, count: 3)
    private var inputBandpassFilterN = [UnsafeMutablePointer<CMFIR>?](repeating: nil, count: 3)
    private var limiterBandpassFilterN = [UnsafeMutablePointer<CMFIR>?](repeating: nil, count: 3)
    //  limiter
    private let bandpassFilteredInput = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    private let limited = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    //  mixer output (before IF filter)
    private let iMixer = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    private let qMixer = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    //  IF filtered buffer
    private let iOutput = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    private let qOutput = UnsafeMutablePointer<Float>.allocate(capacity: 512)

    private var iReg = [Float](repeating: 0, count: 3)
    private var qReg = [Float](repeating: 0, count: 3)
    private var iDelay = [Float](repeating: 0, count: 3)
    private var qDelay = [Float](repeating: 0, count: 3)
    private var mag: Float = 0

    private func buildFilter(_ n: Int, bandpass: Float) {
        inputBandpassFilterN[n] = CMFIRBandpassFilter(1900 - bandpass, 1900 + bandpass, Float(CMFs), 256)
        limiterBandpassFilterN[n] = CMFIRBandpassFilter(1900 - bandpass, 1900 + bandpass, Float(CMFs), 256)
        iFilterN[n] = CMFIRLowpassFilter(bandpass, Float(CMFs), 256)
        qFilterN[n] = CMFIRLowpassFilter(bandpass, Float(CMFs), 256)
    }

    override init() {
        super.init()

        //  zero the C float buffers (Objective-C ivars were zero-initialised)
        bandpassFilteredInput.initialize(repeating: 0, count: 512)
        limited.initialize(repeating: 0, count: 512)
        iMixer.initialize(repeating: 0, count: 512)
        qMixer.initialize(repeating: 0, count: 512)
        iOutput.initialize(repeating: 0, count: 512)
        qOutput.initialize(repeating: 0, count: 512)

        //  set center of VCO
        vco.setCarrier(1900.0)

        iReg[0] = 0; iReg[1] = 0
        qReg[0] = 0; qReg[1] = 0

        agc = 1.0
        mag = 1.0

        //  verbatim transplant of the original's post-init copy loop; both
        //  buffers are already all-zero at this point, so this is a no-op --
        //  preserved rather than removed per the port's fidelity rules.
        for i in 0..<512 { iOutput[i] = qOutput[i] }

        buildFilter(0, bandpass: 480)
        buildFilter(1, bandpass: 650)
        buildFilter(2, bandpass: 1200)
        changeBandwidth(to: 1)
    }

    deinit {
        bandpassFilteredInput.deallocate()
        limited.deallocate()
        iMixer.deallocate()
        qMixer.deallocate()
        iOutput.deallocate()
        qOutput.deallocate()
    }

    func changeBandwidth(to index: Int32) {
        if index < 0 || index > 2 { return }

        inputBandpassFilter = inputBandpassFilterN[Int(index)]
        limiterBandpassFilter = limiterBandpassFilterN[Int(index)]
        iFilter = iFilterN[Int(index)]
        qFilter = qFilterN[Int(index)]
    }

    override func selectFrequency(_ freq: Float, fromWaterfall: Bool) {
        //  do nothing, manually tuned -- FAX receive frequency is fixed by the
        //  broadcasting station (1900 Hz IF center), not AFC-tracked.
    }

    //  Demodulates one 512-sample buffer synchronously. This is the exact math
    //  the original ran on its background pull-thread (see file header).
    private func demodulate(_ inputBuffer: UnsafeMutablePointer<Float>) {
        var pair: CMAnalyticPair
        var u: Float, v: Float, freq: Float, iDot: Float, qDot: Float

        //  bandpass signal before limiting
        CMPerformFIR(inputBandpassFilter, inputBuffer, 512, bandpassFilteredInput)

        //  Apply soft limiter to bandpassed input (factor 0.45 capture-ratio compromise)
        for i in 0..<512 {
            v = bandpassFilteredInput[i]
            u = pow(abs(v), 0.45)
            if v < 0 { u = -u }
            bandpassFilteredInput[i] = u
        }
        //  apply bandpass filter after limiting
        CMPerformFIR(limiterBandpassFilter, bandpassFilteredInput, 512, limited)

        //  Mix to I and Q channels by the FAX center frequency (1900 Hz).
        for i in 0..<512 {
            v = limited[i]
            pair = vco.nextVCOPair()
            iMixer[i] = pair.re * v
            qMixer[i] = pair.im * v
        }
        //  Apply lowpass to I and Q channels
        CMPerformFIR(iFilter, iMixer, 512, iOutput)
        CMPerformFIR(qFilter, qMixer, 512, qOutput)

        //  DirectFM demodulation using ( i.q_dot - q*i_dot )/( i.i + q.q )
        for i in 0..<512 {
            //  IIR differentiator using Al-Alaoui's 1994 algorithm
            iReg[0] = iOutput[i] - 0.5358 * iReg[1] - 0.0718 * iReg[2]
            iDot = iReg[2] - iReg[0]

            qReg[0] = qOutput[i] - 0.5358 * qReg[1] - 0.0718 * qReg[2]
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
            iDelay[2] = iOutput[i]
            qDelay[0] = qDelay[1]
            qDelay[1] = qDelay[2]
            qDelay[2] = qOutput[i]

            delegate?.faxReceiverDidDemodulate(freq)
        }
    }

    //  The input samples come in at 11025 samples/second (0.09 ms per sample).
    override func importData(_ pipe: CMPipe!) {
        if !receiverEnabledFlag { return }          //  wait for enableReceiver(true)

        let stream = pipe.stream()
        demodulate(stream!.pointee.array!)
    }
}
