//
//  DominoReceiver.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 6/23/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of DominoReceiver.m.
//
//  Documentation:
//    DominoEX implementation http://www.qsl.net/zl1bpu/DOMINO/Technical.htm
//    Domino Varicode http://www.qsl.net/zl1bpu/DOMINO/VaricodeEX.PDF
//    DominoEX modes http://www.qsl.net/zl1bpu/DOMINO/Index.htm
//    FEC Varicode    http://f6cte.free.fr/SPECIFICATIONS.ZIP
//
//  Subclass of MFSKReceiver (full-rate DominoEX 11/16/22).  `actualSamplingRate`
//  is a new EXACT-named ivar (accessed by DominoHalfRateReceiver).  -init just
//  forwards to the MFSKReceiver full -init so DominoHalfRateReceiver's [super init]
//  resolves here.
//

import Cocoa

@objc(DominoReceiver)
class DominoReceiver: MFSKReceiver {

    var actualSamplingRate: Float = 0

    //  reachable by DominoHalfRateReceiver via [super init] -> MFSKReceiver -init
    override init() {
        super.init()
    }

    @objc(initAsMode:)
    init(asMode mode: Int32) {
        let cutoff: Float
        let taps: Int32

        super.init(receiverPartial: ())     //  [super initReceiver]

        demodulator = DominoDemodulator(asMode: mode)

        //  reference sampling rate is 16000 s/s
        switch mode {
        case DOMINOEX16:
            //  input decimation, 235 Hz filter to capture 470 Hz of real signal
            actualSamplingRate = 16000.0
            decimationRatio = Float(CMFs / 500.0)
            cutoff = 235.0
            taps = 2560
        case DOMINOEX22:
            actualSamplingRate = 22050.0
            decimationRatio = Float((CMFs / 500.0) * 16000.0 / 22025.0)
            cutoff = 320.0
            taps = 1536
        default:    //  DOMINOEX11
            //  input decimation, 160 Hz filter to capture 320 Hz of real signal
            actualSamplingRate = 11025.0
            decimationRatio = Float((CMFs / 500.0) * 16000.0 / 11025.0)
            cutoff = 160.0
            taps = 1536
        }
        iFilter = CMFIRLowpassFilter(cutoff, Float(CMFs), taps)
        qFilter = CMFIRLowpassFilter(cutoff, Float(CMFs), taps)
    }

    //  the 125 Hz offset "centers" the 18 bands inside the 28 tuning bands for
    //  DominoEX 16.
    @objc(selectFrequency:fromWaterfall:)
    override func selectFrequency(_ freq: Float, fromWaterfall clicked: Bool) {
        if sidebandState {
            //  USB
            receiveFrequency = freq + Float(CARRIEROFFSET) * actualSamplingRate / 16000.0
        } else {
            receiveFrequency = freq - Float(CARRIEROFFSET) * actualSamplingRate / 16000.0
        }
        vco.setCarrier(receiveFrequency)
        if clicked {
            //  don't reset demodulator if it is a scroll wheel operation
            demodulator.resetDemodulatorState()
        }
    }
}
