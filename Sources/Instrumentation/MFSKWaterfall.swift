//
//  MFSKWaterfall.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 6/28/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//  Swift port of MFSKWaterfall.m.
//

import Cocoa

@objc(MFSKWaterfall)
class MFSKWaterfall: Waterfall {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setSpread(15 * 15.625)      // lowest to highest tone for MFSK16
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setSpread(15 * 15.625)      // lowest to highest tone for MFSK16
    }

    override func drawMarkers() {
        //  additional drawing here
        if click > 0 {
            var p = click + 0.5
            drawMarker(p, width: 2, color: black)
            drawMarker(p, width: 1.25, color: green)

            p = click + spread + 0.5
            drawMarker(p, width: 2, color: black)
            drawMarker(p, width: 1.25, color: green)
        }
    }
}
