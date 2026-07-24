//
//  MFSK16Modulator.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 7/16/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//  Swift port of MFSK16Modulator.m.
//
//  MFSK16 uses the full 10-stage interleaver; everything else is inherited from
//  MFSKModulator.
//

import Foundation

@objc(MFSK16Modulator)
class MFSK16Modulator: MFSKModulator {

    @objc(setInterleaverStages:)
    override func setInterleaverStages(_ stages: Int32) {
        interleaverStages = 10
    }
}
