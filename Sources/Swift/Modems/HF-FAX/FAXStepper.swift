//
//  FAXStepper.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 3/19/06.
//  Swift port of FAXStepper.m.
//

import Cocoa

//  counts requests since mouse down
//  this allows stepping to be accelerated

@objc(FAXStepper)
class FAXStepper: NSStepper {

    private var stepCount: Int32 = 0

    override func mouseDown(with event: NSEvent) {
        stepCount = 0
        super.mouseDown(with: event)
    }

    @objc func steps() -> Int32 {
        stepCount &+= 1
        return stepCount
    }
}
