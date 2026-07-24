//
//  CWReceiver.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/2/06.
//  Swift port of CWReceiver.m.
//
//  Subclass of RTTYReceiver for wideband CW.  Adds a sidetone FIR (a malloc'd
//  CMFIR freed nowhere in the original -- the receiver is never released -- so
//  it is freed in deinit here) and its own aural / monitor pipeline.  Base ivars
//  (uniqueID, receiveView, squelch, demodulator, clickBuffer, ...) are accessed
//  by their exact RTTYReceiver names.
//

import Cocoa

@objc(CWReceiver)
class CWReceiver: RTTYReceiver {

    var buffer: Int32 = 0
    var sidetoneFilter: UnsafeMutablePointer<CMFIR>!
    var cwBandwidth: Float = 0
    var cwFrequency: Float = 0
    var sidetoneFrequency: Float = 0
    var vco: CMPCO!
    var cwRxControl: CWRxControl!
    var aural: CWAuralFilter!
    var monitor: CWMonitor!

    @objc(initReceiver:modem:)
    override init(receiver index: Int32, modem: Modem!) {
        let defaultTones = CMTonePair(mark: 1500, space: 0.0, baud: 45.45)

        super.init()

        uniqueID = index
        receiveView = nil
        cwRxControl = nil
        squelch = nil
        currentTonePair = defaultTones
        enabled = false
        slashZero = false
        sidebandState = false
        demodulatorModeMatrix = nil                 //  only used by RTTYReceiver
        bandwidthMatrix = nil                       //  only used by RTTYReceiver
        appleScript = nil
        monitor = nil

        buffer = 0
        changingState(to: false)

        cwBandwidth = 100.0
        cwFrequency = Float(defaultTones.mark)
        sidetoneFrequency = 689.0
        sidetoneFilter = CMFIRBandpassFilter(sidetoneFrequency - cwBandwidth, sidetoneFrequency + cwBandwidth, Float(CMFs), 64)

        vco = CMPCO()
        vco.setOutputScale(1.0)
        vco.setCarrier(sidetoneFrequency)

        //  local CMDataStream
        cmData.pointee.samplingRate = 11025.0
        cmData.pointee.samples = 512
        cmData.pointee.components = 1
        cmData.pointee.channels = 1
        data = cmData
        newData = NSConditionLock(condition: kNoData)
        Thread.detachNewThreadSelector(#selector(receiveThread(_:)), toTarget: self, with: self)
        clickBufferLock = nil

        demodulator = CWDemodulator(fromReceiver: self)
        aural = CWAuralFilter(fromReceiver: self)
        bandpassFilter = nil
        updateFilters()
    }

    deinit {
        if sidetoneFilter != nil { CMDeleteFIR(sidetoneFilter) }
    }

    @objc(setupReceiverChain:monitor:)
    func setupReceiverChain(_ config: ModemConfig!, monitor mon: CWMonitor!) {
        monitor = mon
        //  decoder
        demodulator.setupDemodulatorChain()
        demodulator.setDelegate(self)   //  demodulator calls back to receivedCharacter: delegate
        //  aural
        aural.setupDemodulatorChain()
        aural.setDelegate(self)         //  demodulator calls back to receivedCharacter: delegate
    }

    @objc(setCWSpeed:limited:)
    func setCWSpeed(_ wpm: Float, limited: Bool) {
        let n = Int32(wpm + 0.5)
        if cwRxControl != nil { cwRxControl.setReportedSpeed(n, limited: limited) }
    }

    @objc(setMonitorEnable:)
    func setMonitorEnable(_ state: Bool) {
        if cwRxControl != nil { cwRxControl.setMonitorEnableButton(state) }
    }

    @objc(changeCodeSpeedTo:)
    func changeCodeSpeed(to speed: Int32) {
        (demodulator as? CWDemodulator)?.changeCodeSpeed(to: speed)
    }

    @objc(newClick:)
    func newClick(_ delta: Float) {
        (demodulator as? CWDemodulator)?.newClick(delta)
        aural.newClick(delta)
    }

    @objc(setLatency:)
    func setLatency(_ value: Int32) {
        (demodulator as? CWDemodulator)?.setLatency(value)
    }

    @objc(changeSquelchTo:fastQSB:slowQSB:)
    func changeSquelch(to db: Float, fastQSB fast: Float, slowQSB slow: Float) {
        (demodulator as? CWDemodulator)?.changeSquelch(to: db, fastQSB: fast, slowQSB: slow)
    }

    @objc(changingStateTo:)
    func changingState(to state: Bool) {
        //  CW receiver enable
    }

    @objc(received:quadrature:wide:samples:)
    func received(_ inph: UnsafeMutablePointer<Float>, quadrature quad: UnsafeMutablePointer<Float>, wide: UnsafeMutablePointer<Float>, samples n: Int32) {
        monitor?.push(inph, quadrature: quad, wide: wide, samples: n)   //  v0.78
    }

    @objc(setSidetoneFrequency:)
    func setSidetoneFrequency(_ freq: Float) {
        sidetoneFrequency = freq
        updateFilters()
        vco.setCarrier(sidetoneFrequency)
    }

    //  called from CWMonitor when it needs another buffer for the sound device
    @objc(needSidetone:inphase:quadrature:wide:samples:wide:)
    func needSidetone(_ outbuf: UnsafeMutablePointer<Float>, inphase inph: UnsafeMutablePointer<Float>, quadrature quad: UnsafeMutablePointer<Float>, wide: UnsafeMutablePointer<Float>, samples n: Int32, wide iswide: Bool) {
        if iswide {
            //  wideband request
            memcpy(outbuf, wide, MemoryLayout<Float>.size * Int(n))
            return
        }
        //  narrowband request
        var intermediate = [Float](repeating: 0, count: 512)
        for i in 0..<Int(n) {
            let x = inph[i]
            let y = quad[i]
            //  sidetone oscillator
            let pair = vco.nextVCOPair()
            intermediate[i] = x * pair.re + y * pair.im
        }
        CMPerformFIR(sidetoneFilter, &intermediate, 512, outbuf)
    }

    @objc(updateFilters)
    func updateFilters() {
        var low = sidetoneFrequency - cwBandwidth
        if low < 100 { low = 100 }
        var high = sidetoneFrequency + cwBandwidth
        if high > 2800 { high = 2800 }
        CMUpdateFIRBandpassFilter(sidetoneFilter, low, high)
    }

    @objc(rxTonePairChanged:)
    override func rxTonePairChanged(_ control: RTTYRxControl!) {
        cwRxControl = control as? CWRxControl
        var tonePair = control.rxTonePair()
        cwFrequency = Float(tonePair.mark)
        updateFilters()
        //  set mixer tones
        demodulator.setTonePair(&tonePair)
        aural.setTonePair(&tonePair)
    }

    //  set bandpass filter bandwidth for the receiver and any filters in the demodulator
    @objc(setCWBandwidth:)
    func setCWBandwidth(_ bandwidth: Float) {
        cwBandwidth = bandwidth
        updateFilters()
        if demodulator != nil { (demodulator as? CWDemodulator)?.setCWBandwidth(cwBandwidth) }
        if aural != nil { aural.setCWBandwidth(cwBandwidth) }
    }

    //  if the waterfall is clicked, the CWRxControl sends data here
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        //  send data to aural filter pipeline
        aural.importData(pipe)

        //  check if we have a click buffer by looking to see if a lock exists
        if clickBufferLock != nil {
            if clickBufferLock.try() {
                newData.lock(whenCondition: kNoData)
                //  copy data into tail of clickBuffer
                let stream = pipe.stream()
                let array = stream!.pointee.array
                let buf = clickBuffer[Int(clickBufferProducer)]
                clickBufferProducer = (clickBufferProducer + 1) & 0x1ff  //  512 click buffers
                memcpy(buf, array, 512 * MemoryLayout<Float>.size)
                //  run the receive thread
                cmData.pointee.userData = stream!.pointee.userData
                cmData.pointee.sourceID = stream!.pointee.sourceID
                //  signal receiveThread that new data has arrived
                newData.unlock(withCondition: kHasData)
                clickBufferLock.unlock()
            }
        } else {
            //  no click buffer -- simply use input stream
            demodulator.importData(pipe)
        }
    }
}
