//
//  RTTYDemodulator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 2/27/07.
//  Swift port of RTTYDemodulator.m.
//
//  Subclass of the original CMFSKDemodulator in CoreModem v0.33.
//  Uses RTTYATC instead of CMATC in CoreModem.  (The original `[super initSuper]`
//  bare init is now `super.init()`.)
//

import Cocoa

@objc(RTTYDemodulator)
class RTTYDemodulator: CMFSKDemodulator {

    internal var decoder: RTTYBaudotDecoder?
    weak var auralMonitor: RTTYAuralMonitor?

    override init() {
        super.init()
    }

    @objc(initFromReceiver:)
    override init(fromReceiver rcvr: RTTYReceiver?) {
        super.init()
        delegate = nil
        receiver = rcvr
        let dec = RTTYBaudotDecoder(demodulator: self)
        decoder = dec
        let atc = CMATC()
        var defaultTonePair = CMTonePair(mark: 2125.0, space: 2295.0, baud: 45.45)
        initPipelineStages(&defaultTonePair, decoder: dec, atc: atc, bandwidth: 340.0)
        //  initpipeline should have set up isRTTY
        auralMonitor = isRTTY ? rcvr?.rttyAuralMonitor : nil
    }

    //  print FIGS, LTRS, CR, LF
    @objc(setPrintControl:)
    func setPrintControl(_ state: Bool) {
        decoder?.setPrintControl(state)
    }

    //  received wideband data from Core Audio.
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        //  v0.89 was commented away
        auralMonitor?.newWidebandData(pipe)

        //  send data through the processing chain starting at the bandpass filter
        pipeline?.bandpassFilter?.importData(pipe)
    }
}
