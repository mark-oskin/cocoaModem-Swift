//
//  RTTYAuralMonitor.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/8/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//  Swift port of RTTYAuralMonitor.m.  Subclass of ModemAuralMonitor (Swift).
//

import Cocoa

@objc(RTTYAuralMonitor)
class RTTYAuralMonitor: ModemAuralMonitor {

    private static let sin32: [Float] = [
        0.000,  0.195,  0.383,  0.556,  0.707,  0.831,  0.924,  0.981,
        1.000,  0.981,  0.924,  0.831,  0.707,  0.556,  0.383,  0.195,
        0.000, -0.195, -0.383, -0.556, -0.707, -0.831, -0.924, -0.981,
       -1.000, -0.981, -0.924, -0.831, -0.707, -0.556, -0.383, -0.195,
        0.000,  0.000,  0.000,  0.000,  0.000,  0.000,  0.000,  0.000
    ]

    private var monitorIsActive = false

    private var rxMonitorOn = false
    private var rxUseFloatingTone = false
    private var rxGain: Float = 0
    private var rxBaseGain: Float = 0

    private var rxBackgroundOn = false
    private var rxBackgroundGain: Float = 0
    private var rxBackgroundBaseGain: Float = 0
    private var backgroundBuffer = [Float](repeating: 0, count: 512)

    private var txMonitorOn = false
    private var txUseFloatingTone = false
    private var txGain: Float = 0
    private var txBaseGain: Float = 0

    private var auralWindow = [Float](repeating: 0, count: 512)
    private var clickBufferBeep = [Float](repeating: 0, count: 512)      //  v0.88c
    private var transmitEngaged = false                                  //  v0.88
    private var pttToneTimer: Timer?                                     //  v0.88
    private var pttBitIndex: Int32 = 0                                   //  v0.88
    private var pttSampleIndex: Int32 = 0

    private var pttDDA: Float = 0                                        //  v0.88
    private var pttDDAdelta: Float = 0
    private var pttMark: Float = 0                                       //  v0.88
    private var pttSpace: Float = 0
    private var baudot: Int32 = 0                                        //  v0.88
    private var transmitType: Int32 = 0                                  //  v0.88
    private var emitBeepFlag = false                                     //  v0.88c
    private var clickVolume: Float = 0                                   //  v0.88c
    private var useSoftLimiting = false                                  //  v0.88c
    private var agcVoltage: Float = 0                                    //  v0.88c

    private let receiveCarrier = UnsafeMutablePointer<CMDDA>.allocate(capacity: 1)
    private let transmitCarrier = UnsafeMutablePointer<CMDDA>.allocate(capacity: 1)
    private let receiveAuralCenter = UnsafeMutablePointer<CMDDA>.allocate(capacity: 1)
    private let transmitAuralCenter = UnsafeMutablePointer<CMDDA>.allocate(capacity: 1)

    //  v0.88c  "pitch" is between 400 and 1600
    @objc(setClickPitch:)
    func setClickPitch(_ value: Float) {
        let f = 0.3 * 1000.0 / ((2000.0 - Double(value)) + 0.1)
        let g = 2.3 * f

        for i in 0..<512 {
            clickBufferBeep[i] = Float((sin(Double(i) * g) * 0.4 + sin(Double(i) * g) * 0.1) * sqrt(1 - cos(Double(i) * 3.1415926 / 256)))
        }
    }

    //  v0.88
    private func setPttDDA(_ freq: Float) {
        pttDDA = 0                          //  pttDDA goes from 0 to 1 (for 0 to 2.pi) for CMFs sampling rate
        pttMark = Float((Double(freq) - 85.0) / CMFs)
        pttSpace = Float((Double(freq) + 85.0) / CMFs)
        pttDDAdelta = pttSpace
        pttBitIndex = 0
    }

    override init() {
        receiveCarrier.initialize(to: CMDDA())
        transmitCarrier.initialize(to: CMDDA())
        receiveAuralCenter.initialize(to: CMDDA())
        transmitAuralCenter.initialize(to: CMDDA())
        super.init()

        setDDA(receiveCarrier, freq: 1585.0)
        setDDA(transmitCarrier, freq: 1585.0)
        setDDA(receiveAuralCenter, freq: 1760.0)
        setDDA(transmitAuralCenter, freq: 1048.0)
        setPttDDA(1048.0)

        demodulatorIsActive = false
        monitorIsActive = false
        rxMonitorOn = false; txMonitorOn = false; rxBackgroundOn = false
        rxUseFloatingTone = false; txUseFloatingTone = false
        rxGain = 0.25; rxBaseGain = 0.25
        txGain = 0.05; txBaseGain = 0.05
        rxBackgroundGain = 0.05; rxBackgroundBaseGain = 0.05
        agcVoltage = 1.0

        //  v0.88 apply smoothing window if frames are skipped
        for i in 0..<512 { auralWindow[i] = Float((8 - cos(Double(i) * 3.1415926 / 256)) * 0.111) }
        setClickPitch(1000.0)               //  v0.88

        clickBufferActive = false
        transmitEngaged = false
        pttToneTimer = nil
        transmitType = 0                    //  default to AFSK transmit
        baudot = 0x1f                       //  LTRS
        pttBitIndex = 0; pttSampleIndex = 0
        emitBeepFlag = false
        clickVolume = 0
        useSoftLimiting = false

        makeFilters()
    }

    deinit {
        receiveCarrier.deallocate()
        transmitCarrier.deallocate()
        receiveAuralCenter.deallocate()
        transmitAuralCenter.deallocate()
    }

    @objc(makeFilters)
    func makeFilters() {
        rxLowpassIFilter[0] = CMFIRLowpassFilter(400.0, 11025.0, 512)
        rxLowpassQFilter[0] = CMFIRLowpassFilter(400.0, 11025.0, 512)
        txLowpassIFilter[0] = CMFIRLowpassFilter(400.0, 11025.0, 512)
        txLowpassQFilter[0] = CMFIRLowpassFilter(400.0, 11025.0, 512)
    }

    @objc(setTonePair:)
    func setTonePair(_ tonepair: UnsafePointer<CMTonePair>) {
        setDDA(receiveCarrier, freq: Float((tonepair.pointee.mark + tonepair.pointee.space) * 0.5))
    }

    @objc(setTransmitTonePair:)
    func setTransmitTonePair(_ tonepair: UnsafePointer<CMTonePair>) {
        setDDA(transmitCarrier, freq: Float((tonepair.pointee.mark + tonepair.pointee.space) * 0.5))
    }

    //  ask auralMonitor to pull data from here
    private func updateAuralMonitorState() {
        if !muted && demodulatorIsActive {
            if !monitorIsActive { auralMonitor?.addClient(self) }
            monitorIsActive = true
        } else {
            if monitorIsActive { auralMonitor?.removeClient(self) }
            monitorIsActive = false
        }
    }

    @objc(setDemodulatorActive:)
    func setDemodulatorActive(_ state: Bool) {
        demodulatorIsActive = state
        updateAuralMonitorState()
    }

    @objc(setOutputFrequency:source:)
    func setOutputFrequency(_ freq: Float, source: Int32) {
        switch source {
        case AURALRECEIVE:
            setDDA(receiveAuralCenter, freq: freq)
        case AURALTRANSMIT:
            setDDA(transmitAuralCenter, freq: freq)
        default:
            break
        }
    }

    @objc(setFloatingTone:source:)
    func setFloatingTone(_ state: Bool, source: Int32) {
        switch source {
        case AURALRECEIVE:
            rxUseFloatingTone = state
        case AURALTRANSMIT:
            txUseFloatingTone = state
        default:
            break
        }
    }

    @objc(setClickVolume:)
    func setClickVolume(_ value: Float) {
        clickVolume = Float(pow(Double(value), 1.8))
    }

    @objc(setSoftLimit:)
    func setSoftLimit(_ state: Bool) {
        useSoftLimiting = state
    }

    @objc(setState:source:)
    func setState(_ state: Bool, source: Int32) {
        switch source {
        case AURALRECEIVE:
            rxMonitorOn = state
        case AURALTRANSMIT:
            txMonitorOn = state
        case AURALBACKGROUND:
            if !rxBackgroundOn { for i in 0..<512 { backgroundBuffer[i] = 0 } }
            rxBackgroundOn = state
        case AURALMASTER:
            muted = !state
            updateAuralMonitorState()
        default:
            break
        }
    }

    //  (Private API)
    private func setScalarGain(_ gain: Float, source: Int32) {
        switch source {
        case AURALRECEIVE:
            rxBaseGain = gain
            rxGain = gain * masterGain
        case AURALTRANSMIT:
            txBaseGain = gain
            txGain = gain * masterGain
        case AURALBACKGROUND:
            rxBackgroundBaseGain = gain
            rxBackgroundGain = gain * masterGain
        case AURALMASTER:
            masterGain = gain
            rxBackgroundGain = rxBackgroundBaseGain * masterGain
            rxGain = rxBaseGain * masterGain
            txGain = txBaseGain * masterGain
        default:
            break
        }
    }

    @objc(setGain:source:)
    func setGain(_ v: Float, source: Int32) {
        setScalarGain(v * v, source: source)
    }

    //  source: 0 = receiver, 1 = transmitter, 2 = background, 3 = master
    @objc(setAttenuation:source:)
    func setAttenuation(_ db: Int32, source: Int32) {
        setScalarGain(Float(pow(10.0, fabs(Double(db)) * (-0.05))), source: source)  //  v0.88 fabs()
    }

    //  (Private API)
    private func submitBufferToAuralMonitor(_ si: inout [Float], isReceiver: Bool) {
        si.withUnsafeMutableBufferPointer { p in
            if isReceiver {
                auralMonitor?.addLeft(p.baseAddress, right: nil, samples: 512, client: self)
            } else {
                auralMonitor?.addLeft(nil, right: p.baseAddress, samples: 512, client: self)
            }
        }
    }

    private func performFIR(_ fir: UnsafeMutablePointer<CMFIR>?, _ input: inout [Float], _ output: inout [Float]) {
        input.withUnsafeMutableBufferPointer { inp in
            output.withUnsafeMutableBufferPointer { outp in
                CMPerformFIR(fir, inp.baseAddress, 512, outp.baseAddress)
            }
        }
    }

    //  (Private API)
    private func newBandpassFilteredDataFromReceiver(_ array: UnsafeMutablePointer<Float>) {
        var si = [Float](repeating: 0, count: 512)
        var sq = [Float](repeating: 0, count: 512)
        var lpi = [Float](repeating: 0, count: 512)
        var lpq = [Float](repeating: 0, count: 512)
        var u: Float
        var v: Float

        if !rxUseFloatingTone {
            //  narrowband - first mix down to baseband
            if useSoftLimiting {
                //  apply a maximum of 26 dB of AGC
                u = 0.01
                for i in 0..<512 { v = abs(array[i]); if v > u { u = v } }
                agcVoltage = agcVoltage * 0.5 + 0.5 * u
                v = rxGain * 0.707 / (agcVoltage + 0.001)
            } else {
                v = rxGain          //  fixed gain
            }

            for i in 0..<512 {
                let vfo = updateDDA(receiveCarrier)
                u = array[i] * v
                si[i] = vfo.re * u
                sq[i] = vfo.im * u
            }

            //  lowpass the baseband signal
            performFIR(rxLowpassIFilter[0], &si, &lpi)
            performFIR(rxLowpassQFilter[0], &sq, &lpq)

            //  remodulate to target frequency
            for i in 0..<512 {
                let vfo = updateDDA(receiveAuralCenter)
                si[i] = (vfo.re * lpq[i] - vfo.im * lpi[i]) * 2.0
            }
        } else {
            if useSoftLimiting {
                u = 0.01
                for i in 0..<512 { v = abs(array[i]); if v > u { u = v } }
                agcVoltage = agcVoltage * 0.5 + 0.5 * u
                v = rxGain * 0.707 / (agcVoltage + 0.001)
            } else {
                v = rxGain          //  fixed gain
            }
            //  floating rx: just use input and apply rx gain
            for i in 0..<512 { si[i] = array[i] * v }
        }

        //  merge background if on
        if rxBackgroundOn { for i in 0..<512 { si[i] += backgroundBuffer[i] } }

        if emitBeepFlag {
            for i in 0..<512 { si[i] += clickBufferBeep[i] * clickVolume }
            emitBeepFlag = false
        }

        submitBufferToAuralMonitor(&si, isReceiver: true)
    }

    //  v0.88c
    @objc(emitBeep)
    func emitBeep() {
        emitBeepFlag = true
    }

    //  v0.89
    @objc(clickBufferCleared)
    func clickBufferCleared() {
        clickBufferActive = false
    }

    //  v0.88 set from modems to indicate the click buffer is active
    @objc(setClickBufferActive:)
    override func setClickBufferActive(_ state: Bool) {
        clickBufferActive = state
        if !state { emitBeep() }            //  v0.88c  beep when click buffer reaches real time
    }

    //  (Private API)
    private func newBandpassFilteredDataFromTransmitter(_ array: UnsafeMutablePointer<Float>, scale: Float, shift: Bool) {
        var si = [Float](repeating: 0, count: 512)
        var sq = [Float](repeating: 0, count: 512)
        var lpi = [Float](repeating: 0, count: 512)
        var lpq = [Float](repeating: 0, count: 512)

        let gain = scale * txGain
        if shift {
            //  narrow band, first mix down to baseband
            for i in 0..<512 {
                let vfo = updateDDA(transmitCarrier)
                let u = array[i] * gain
                si[i] = vfo.re * u
                sq[i] = vfo.im * u
            }
            //  lowpass baseband
            performFIR(txLowpassIFilter[0], &si, &lpi)
            performFIR(txLowpassQFilter[0], &sq, &lpq)
            //  remodulate to target frequency
            for i in 0..<512 {
                let vfo = updateDDA(transmitAuralCenter)
                si[i] = (vfo.re * lpq[i] - vfo.im * lpi[i]) * 2.0
            }
        } else {
            //  floating tx: just use input and apply rx gain
            for i in 0..<512 { si[i] = array[i] * gain }
        }
        submitBufferToAuralMonitor(&si, isReceiver: false)
    }

    //  Bandpass filtered RTTY signal (11025 s/s before mixing) arrives
    @objc(newBandpassFilteredData:scale:fromReceiver:)
    func newBandpassFilteredData(_ array: UnsafeMutablePointer<Float>, scale: Float, fromReceiver: Bool) {
        if auralMonitor == nil || !monitorIsActive { return }

        //  v0.88 disable input to aural monitor while click buffer is active
        if clickBufferBusy() {
            if !performClickBufferResampling() || !rxMonitorOn { return }
            //  inside click buffer but is the first of a series of accelerated buffers
            var localArray = [Float](repeating: 0, count: 512)
            for i in 0..<512 { localArray[i] = array[i] * auralWindow[i] }
            localArray.withUnsafeMutableBufferPointer { p in
                newBandpassFilteredDataFromReceiver(p.baseAddress!)      //  v0.88 for new
            }
            return
        }

        //  sanity check for internal PTT tone
        if !transmitEngaged && pttToneTimer != nil {
            pttToneTimer?.invalidate()
            pttToneTimer = nil
        }

        if fromReceiver {
            //  check if receiver enabled (v0.89 need wideband also)
            if (rxMonitorOn || rxBackgroundOn) && !transmitEngaged {
                newBandpassFilteredDataFromReceiver(array)
            }
            return
        }
        //  check if transmitter is enabled and if artificial tones is not selected
        if txMonitorOn && transmitEngaged {
            if transmitType == 0 {
                //  is AFSK transmitter
                newBandpassFilteredDataFromTransmitter(array, scale: 1.0 / (scale + 0.01), shift: !txUseFloatingTone)
            }
        }
    }

    //  v0.88 Generate audio FSK transmit tones for FSK mode
    @objc(pttToneTimerProc:)
    func pttToneTimerProc(_ timer: Timer) {
        if !transmitEngaged || transmitType == 0 { return }

        let pttGain = txGain * 2.2
        var tone = [Float](repeating: 0, count: 512)

        for i in 0..<512 {
            pttSampleIndex += 1
            if pttSampleIndex >= 242 {
                //  Baudot bit boundary for 45.56 baud at 11025 samples/second
                pttSampleIndex = 0
                pttBitIndex += 1
                if pttBitIndex < 0 || pttBitIndex > 7 { pttBitIndex = 0 }

                if pttBitIndex == 0 {
                    //  fetch (roughly) the most recently sent Baudot character
                    baudot = (NSApp.delegate as? AppDelegate)?.application()?.fskHub()?.currentBaudotCharacter() ?? 0
                } else if pttBitIndex >= 4 {
                    baudot >>= 1
                }

                //  Bits 0 and 1 and random data bit is a mark.  bit 2 is a space.
                pttDDAdelta = (pttBitIndex == 0 || pttBitIndex == 1 || (pttBitIndex != 2 && (baudot & 1) == 1)) ? pttMark : pttSpace
            }
            //  sine wave dda
            pttDDA += pttDDAdelta
            if pttDDA > 1.0 { pttDDA -= 1.0 }
            var n = Int(pttDDA * 32)
            if n < 0 || n >= RTTYAuralMonitor.sin32.count { n = 0 }
            tone[i] = pttGain * RTTYAuralMonitor.sin32[n]
        }
        //  send PTT tone samples
        tone.withUnsafeMutableBufferPointer { p in
            newBandpassFilteredDataFromTransmitter(p.baseAddress!, scale: 1.0, shift: false)
        }
    }

    //  The artificial AFSK signal is generated by a NSTimer loop on a separate thread
    @objc func startGeneratorInSeparateThread() {
        autoreleasepool {
            let runLoop = RunLoop.current
            let timer = Timer.scheduledTimer(timeInterval: 512.0 / 11025.0, target: self,
                                             selector: #selector(pttToneTimerProc(_:)), userInfo: self, repeats: true)
            pttToneTimer = timer                //  keep timer thread alive
            runLoop.run()
        }
    }

    //  v0.88  transmitType = 0:AFSK, 1:FSK, 2:OOK
    @objc(setTransmitState:transmitType:)
    func setTransmitState(_ state: Bool, transmitType type: Int32) {
        transmitEngaged = state
        transmitType = type

        if transmitType == 0 && pttToneTimer != nil {
            //  sanity check
            pttToneTimer?.invalidate()
            pttToneTimer = nil
        }
        if state {
            if transmitType == 1 || transmitType == 2 {
                //  initialize FSK and OOK aural monitor to LTRS character (diddle)
                (NSApp.delegate as? AppDelegate)?.application()?.fskHub()?.setCurrentBaudotCharacter(0x1f)
            }
            if transmitType != 0 && txMonitorOn && pttToneTimer == nil {
                //  generate tone
                pttBitIndex = 0; pttSampleIndex = 0
                pttDDAdelta = pttMark
                baudot = 0xff
                //  start timer in separate thread
                Thread.detachNewThreadSelector(#selector(startGeneratorInSeparateThread), toTarget: self, with: nil)
            }
        } else {
            if pttToneTimer != nil {
                pttToneTimer?.invalidate()
                pttToneTimer = nil
            }
        }
    }

    //  Non-bandpass filtered RTTY signal (11025 s/s before BPF) arrives.
    @objc(newWidebandData:)
    func newWidebandData(_ pipe: CMPipe) {
        //  v0.89
        if !rxBackgroundOn || auralMonitor == nil || !monitorIsActive { return }

        //  v0.88
        if clickBufferBusy() { return }

        guard let array = pipe.stream()?.pointee.array else { return }
        for i in 0..<512 { backgroundBuffer[i] = array[i] * rxBackgroundGain }
    }

    //  same as above but with floating point buffer
    @objc(newWidebandBuffer:)
    func newWidebandBuffer(_ array: UnsafeMutablePointer<Float>) {
        //  v0.89
        if !rxBackgroundOn || auralMonitor == nil || !monitorIsActive { return }

        for i in 0..<512 { backgroundBuffer[i] = array[i] * rxBackgroundGain }
    }
}
