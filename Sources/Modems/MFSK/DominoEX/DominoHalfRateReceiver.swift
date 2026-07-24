//
//  DominoHalfRateReceiver.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 7/3/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of DominoHalfRateReceiver.m.  Half-rate DominoEX (4/5/8).  Calls
//  the MFSKReceiver full -init (via [super init]) and then rebuilds the VCO,
//  click buffer and decimation filters for the half-rate mode.  Base ivars
//  (including DominoReceiver's actualSamplingRate) are accessed by exact name.
//

import Cocoa

@objc(DominoHalfRateReceiver)
class DominoHalfRateReceiver: DominoReceiver {

    @objc(initAsMode:)
    override init(asMode mode: Int32) {
        let cutoff: Float

        super.init()        //  [super init] -> MFSKReceiver full -init

        enabled = false
        sidebandState = true
        demodulator = DominoHalfRateDemodulator(asMode: mode)

        //  set up VCO at tone's frequency
        receiveFrequency = 972.0 + Float(CARRIEROFFSET)
        vco = CMPCO()
        vco.setCarrier(receiveFrequency)

        //  click buffer
        createClickBuffer()

        //  reference sampling rate is 16000 s/s
        switch mode {
        case DOMINOEX5:
            //  input decimation, 160 Hz filter to capture 320 Hz of real signal
            actualSamplingRate = 11025.0
            decimationRatio = Float((CMFs / 500.0) * 16000.0 / 11025.0)
            cutoff = 160.0
        case DOMINOEX8:
            //  input decimation, 235 Hz filter to capture 470 Hz of real signal
            actualSamplingRate = 16000.0
            decimationRatio = Float(CMFs / 500.0)
            cutoff = 235.0
        default:    //  DOMINOEX4
            //  input decimation, 120 Hz filter to capture 230 Hz of real signal
            actualSamplingRate = 8000.0
            decimationRatio = Float((CMFs / 500.0) * 16000.0 / 8000.0)
            cutoff = 120.0
        }
        nextSample = 150
        outputIndex = 0
        iFilter = CMFIRLowpassFilter(cutoff, Float(CMFs), 1024)
        qFilter = CMFIRLowpassFilter(cutoff, Float(CMFs), 1024)
    }
}
