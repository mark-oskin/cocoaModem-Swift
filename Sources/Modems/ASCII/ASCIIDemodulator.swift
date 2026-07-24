//
//  ASCIIDemodulator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/29/10.
//  Copyright 2010 Kok Chen, W7AY. All rights reserved.
//  Swift port of ASCIIDemodulator.m.
//
//  8-bit ASCII FSK demodulator.  Subclass of RTTYDemodulator; uses ASCIIATC and
//  ASCIIDecoder.  (The original `[super init]` bare init is `super.init()`.)
//

import Cocoa

@objc(ASCIIDemodulator)
class ASCIIDemodulator: RTTYDemodulator {

    @objc(initFromReceiver:)
    override init(fromReceiver rcvr: RTTYReceiver?) {
        super.init()
        isRTTY = true
        delegate = nil
        receiver = rcvr
        let dec = ASCIIDecoder(demodulator: self)
        decoder = dec
        let atc = ASCIIATC()
        var defaultTonePair = CMTonePair(mark: 2125.0, space: 2295.0, baud: 110.0)
        initPipelineStages(&defaultTonePair, decoder: dec, atc: atc, bandwidth: 500.0)
    }

    //  aways keep USOS off
    @objc(setUSOS:)
    override func setUSOS(_ state: Bool) {
        pipeline?.decoder?.setUSOS(false)
    }

    @objc(setLTRS:)
    override func setLTRS(_ state: Bool) {
        //  do nothing in ASCII mode
    }
}
