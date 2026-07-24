//
//  OptionTextField.swift
//  cocoaModem
//
//  Created by Kok Chen on 12/1/04.
//  Swift port of OptionTextField.m.
//

import Cocoa

//  NSTextField that traps option key changes
@objc(OptionTextField)
class OptionTextField: NSTextField {

    //  NSResponder
    override func flagsChanged(with event: NSEvent) {
        NotificationCenter.default.post(name: NSNotification.Name("OptionKey"), object: event)
        super.flagsChanged(with: event)
    }
}
