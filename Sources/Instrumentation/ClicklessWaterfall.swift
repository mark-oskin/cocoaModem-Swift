//
//  ClicklessWaterfall.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/25/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//  Swift port of ClicklessWaterfall.m.
//

import Cocoa

@objc(ClicklessWaterfall)
class ClicklessWaterfall: Waterfall {

    override func mouseDown(with event: NSEvent) {
        //  do nothing in clickless waterfall
    }

    override func arrowKeyTune(_ notify: Notification) {
        //  do nothing in clickless waterfall
    }
}
