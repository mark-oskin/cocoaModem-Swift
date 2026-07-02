//
//  OptionPanel.swift
//  cocoaModem
//
//  Created by Kok Chen on 10/15/04.
//  Swift port of OptionPanel.m.
//
//  Informs application of option key changes.
//

import Cocoa

@objc(OptionPanel)
class OptionPanel: NSPanel {

    //  NSResponder
    override func flagsChanged(with event: NSEvent) {
        NotificationCenter.default.post(name: NSNotification.Name("OptionKey"), object: event)
        super.flagsChanged(with: event)
    }
}
