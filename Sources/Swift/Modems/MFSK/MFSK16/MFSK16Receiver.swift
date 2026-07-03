//
//  MFSK16Receiver.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 7/16/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of MFSK16Receiver.m.  Uses the MFSKReceiver base setup
//  (-initReceiver) then installs the MFSK16 demodulator and 210 Hz decimation
//  filters.  Base ivars are accessed by their exact MFSKReceiver names.
//

import Cocoa

@objc(MFSK16Receiver)
class MFSK16Receiver: MFSKReceiver {

    override init() {
        super.init(receiverPartial: ())     //  [super initReceiver]
        demodulator = MFSK16Demodulator()
        //  input decimation
        decimationRatio = Float(CMFs / 500.0)
        iFilter = CMFIRLowpassFilter(210, Float(CMFs), 512)
        qFilter = CMFIRLowpassFilter(210, Float(CMFs), 512)
    }
}
