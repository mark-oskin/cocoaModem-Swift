//
//  FAXReceiver.swift
//  cocoaModem
//
//  Created by Kok Chen on 3/6/2006.
//
//  Swift port of FAXReceiver.m.  A CMToneReceiver that FM-demodulates the HF
//  FAX signal.  DSP-critical: exact filter bandwidths, the soft-limiter (pow
//  0.45), the Al-Alaoui IIR differentiator coefficients and the slow AGC are
//  preserved.  Fixed C float buffers become UnsafeMutablePointer allocations
//  (zeroed to match zero-initialised Objective-C ivars) and are freed in deinit.
//
//  Note: the Objective-C ivar "client" (a Modem*) is renamed to "modemClient"
//  here because CMPipe already defines a -client method; the selector is
//  unaffected (the ivar was never messaged externally).
//

import Cocoa

@objc(FAXReceiver)
class FAXReceiver: CMToneReceiver {

    internal var modemClient: Modem?            //  was ivar "client" (renamed: collides with CMPipe -client)
    internal var view: FAXDisplay?

    //  agc
    internal var agc: Float = 0

    //  decimating filter
    internal var iFilter: UnsafeMutablePointer<CMFIR>!
    internal var qFilter: UnsafeMutablePointer<CMFIR>!
    internal var inputBandpassFilter: UnsafeMutablePointer<CMFIR>!
    internal var limiterBandpassFilter: UnsafeMutablePointer<CMFIR>!
    //  filter bands
    internal var iFilterN = [UnsafeMutablePointer<CMFIR>?](repeating: nil, count: 3)
    internal var qFilterN = [UnsafeMutablePointer<CMFIR>?](repeating: nil, count: 3)
    internal var inputBandpassFilterN = [UnsafeMutablePointer<CMFIR>?](repeating: nil, count: 3)
    internal var limiterBandpassFilterN = [UnsafeMutablePointer<CMFIR>?](repeating: nil, count: 3)
    //  limiter
    internal let bandpassFilteredInput = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    internal let limited = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    //  mixer output (before IF filter)
    internal let iMixer = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    internal let qMixer = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    //  IF filtered buffer
    internal let iOutput = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    internal let qOutput = UnsafeMutablePointer<Float>.allocate(capacity: 512)

    internal var iReg = [Float](repeating: 0, count: 3)
    internal var qReg = [Float](repeating: 0, count: 3)
    internal var iDelay = [Float](repeating: 0, count: 3)
    internal var qDelay = [Float](repeating: 0, count: 3)
    internal var mag: Float = 0

    internal var datapipe: DataPipe!

    func buildFilter(_ n: Int, bandpass: Float) {
        inputBandpassFilterN[n] = CMFIRBandpassFilter(1900 - bandpass, 1900 + bandpass, Float(CMFs), 256)
        limiterBandpassFilterN[n] = CMFIRBandpassFilter(1900 - bandpass, 1900 + bandpass, Float(CMFs), 256)
        iFilterN[n] = CMFIRLowpassFilter(bandpass, Float(CMFs), 256)
        qFilterN[n] = CMFIRLowpassFilter(bandpass, Float(CMFs), 256)
    }

    @objc(initFromModem:)
    init(fromModem modem: Modem?) {
        super.init()

        //  zero the C float buffers (Objective-C ivars were zero-initialised)
        bandpassFilteredInput.initialize(repeating: 0, count: 512)
        limited.initialize(repeating: 0, count: 512)
        iMixer.initialize(repeating: 0, count: 512)
        qMixer.initialize(repeating: 0, count: 512)
        iOutput.initialize(repeating: 0, count: 512)
        qOutput.initialize(repeating: 0, count: 512)

        view = (modem as? FAX)?.faxView()
        //  set center of VCO
        vco.setCarrier(1900.0)

        //  iReg[0]=iReg[1]=iReg[3]=0 in the original; iReg has 3 elements so [3]
        //  was a benign out-of-bounds write of 0.  Everything is already zeroed.
        iReg[0] = 0; iReg[1] = 0
        qReg[0] = 0; qReg[1] = 0

        modemClient = modem
        agc = 1.0
        mag = 1.0

        for i in 0..<512 { iOutput[i] = qOutput[i] }

        buildFilter(0, bandpass: 480)
        buildFilter(1, bandpass: 650)
        buildFilter(2, bandpass: 1200)
        changeBandwidth(to: 1)

        //  DataPipe has 131,072 floating point samples (approx 12 seconds)
        datapipe = DataPipe(capacity: Int32(512 * 256 * MemoryLayout<Float>.size))
        Thread.detachNewThreadSelector(#selector(pullThread(_:)), toTarget: self, with: self)
    }

    deinit {
        bandpassFilteredInput.deallocate()
        limited.deallocate()
        iMixer.deallocate()
        qMixer.deallocate()
        iOutput.deallocate()
        qOutput.deallocate()
    }

    @objc(changeBandwidthTo:)
    func changeBandwidth(to index: Int32) {
        if index < 0 || index > 2 { return }

        inputBandpassFilter = inputBandpassFilterN[Int(index)]
        limiterBandpassFilter = limiterBandpassFilterN[Int(index)]
        iFilter = iFilterN[Int(index)]
        qFilter = qFilterN[Int(index)]
    }

    override func selectFrequency(_ freq: Float, fromWaterfall: Bool) {
        //  do nothing, manually tuned
    }

    //	v0.57d  added DataPipe to buffer input data from the codec
    //  input data is pushed into a DataPipe and pulled here
    @objc(pullThread:)
    func pullThread(_ client: Any?) {
        let inputBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { inputBuffer.deallocate() }

        //  Initialised at declaration: they are captured by the autoreleasepool
        //  closure below (Swift forbids capturing an uninitialised local), and
        //  are all reassigned before use inside the loop.
        var pair = CMAnalyticPair()
        var u: Float = 0, v: Float = 0, freq: Float = 0, iDot: Float = 0, qDot: Float = 0

        //  Loop continuously requesting data at 11025 s/s from the DataPipe.
        while true {
            autoreleasepool {
                //  block here when there is no new data
                _ = datapipe.readData(inputBuffer, length: Int32(512 * MemoryLayout<Float>.size))
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

                    //  send oversampled data to FAXDisplay
                    view?.addPixel(freq)
                }
            }
        }
    }

    //  The input samples come in at 11025 samples/second (0.09 ms per sample).
    override func importData(_ pipe: CMPipe!) {
        if !receiverEnabledFlag { return }          //  wait for click

        let stream = pipe.stream()
        _ = datapipe.write(stream!.pointee.array!, length: Int32(512 * MemoryLayout<Float>.size))
    }
}
