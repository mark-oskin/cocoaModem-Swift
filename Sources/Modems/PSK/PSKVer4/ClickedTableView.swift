//
//  ClickedTableView.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/7/08.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//  Swift port of ClickedTableView.m.
//

import Cocoa

@objc(ClickedTableView)
class ClickedTableView: NSTableView {

    private var option: Bool = false
    //  ObjC stored NSControlKeyMask / NSAlternateKeyMask in an unsigned int.
    private var optionMask: NSEvent.ModifierFlags = .option

    @objc(useControlButton:)
    func useControlButton(_ state: DarwinBoolean) {
        option = false
        optionMask = state.boolValue ? .control : .option
    }

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags
        option = flags.contains(optionMask)
        super.mouseDown(with: event)
    }

    @objc func optionClicked() -> DarwinBoolean {
        return DarwinBoolean(option)
    }
}
