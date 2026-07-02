//
//  TextFieldForScrolling.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 6/24/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of TextFieldForScrolling.m.
//

import Cocoa

@objc(TextFieldForScrolling)
class TextFieldForScrolling: NSTextField {

    private var paused = false

    //  nib-instantiated (initWithCoder:)
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        paused = false
    }

    //  Swift requires the sibling designated initializer once initWithCoder: is
    //  overridden; the C original only defined -initWithCoder:.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        paused = false
    }

    @objc(setPaused:)
    func setPaused(_ state: Bool) {
        paused = state
        //if ( paused == NO ) [ self display ] ;
    }

    override func draw(_ dirtyRect: NSRect) {
        if paused { return }
        super.draw(dirtyRect)
    }
}
