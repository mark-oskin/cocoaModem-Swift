//
//  BackgroundTextField.swift
//  cocoaModem
//
//  Created by Kok Chen on 11/23/04.
//  Swift port of BackgroundTextField.m.
//

import Cocoa

@objc(BackgroundTextField)
class BackgroundTextField: NSTextField {

    override func awakeFromNib() {
        isBezeled = true
        drawsBackground = true
    }
}
