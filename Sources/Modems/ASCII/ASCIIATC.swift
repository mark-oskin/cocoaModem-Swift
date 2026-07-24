//
//  ASCIIATC.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/29/10.
//  Copyright 2010 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of ASCIIATC.m.  A CMATC configured for 7-bit, 110 baud ASCII.
//  The Objective-C -init re-ran CMATC's own setup with the ASCII parameters;
//  since super.init() already establishes the identical AGC / atcCase / buffer
//  state, this port simply overrides the two differing parameters.
//

import Cocoa

@objc(ASCIIATC)
class ASCIIATC: CMATC {

    @objc override init() {
        super.init()
        //  7 bits ASCII, 110 baud
        bitsPerCharacter = 7
        setBitSampling(fromBaudRate: 110.0)
    }

    override func setBitsPerCharacter(_ bits: Int32) {
        super.setBitsPerCharacter(bits)
        setBitSampling(fromBaudRate: bitStream.samplingRate)
    }
}
