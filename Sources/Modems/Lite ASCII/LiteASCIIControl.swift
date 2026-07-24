//
//  LiteASCIIControl.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/31/10.
//  Copyright 2010 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of LiteASCIIControl.m.  Thin RTTYRxControl subclass that draws the
//  Lite ASCII spectrum.  Loads the "LiteASCIIControl" nib.  Base ivars accessed by
//  exact name.
//

import Cocoa

@objc(LiteASCIIControl)
class LiteASCIIControl: RTTYRxControl {

    @objc(initIntoView:client:index:)
    override init?(intoView view: NSView?, client modem: Modem?, index: Int32) {
        super.init()
        if Bundle.main.loadNibNamed("LiteASCIIControl", owner: self, topLevelObjects: nil) {
            //  loadNib should have set up controlView connection
            if let view = view, let cv = controlView {
                //  set level of NSPanel to floating level  v0.64e
                view.window?.level = .floating
                view.window?.orderOut(self)
                view.addSubview(cv)
                auxWindow?.title = (index == 0) ? NSLocalizedString("ASCII Receiver", comment: "") : NSLocalizedString("Sub Receiver", comment: "")
                setupWithClient(modem, index: index)
                activeIndicator?.backgroundColor = NSColor.gray
                return
            }
        }
        return nil
    }

    //  audio source starts at config and is routed here first
    //  the data is sent to the receiver and the tuning and any spectrum
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        if receiver == nil || !receiver.enabled { return }

        super.importData(pipe)
        (client as? LiteASCII)?.drawSpectrum(pipe)
    }

    //  v0.67
    @objc(setTonePair:mask:)
    override func setTonePair(_ tonepair: UnsafePointer<CMTonePair>, mask: Int32) {
        super.setTonePair(tonepair, mask: mask)
        if mask & 1 != 0 { (client as? LiteASCII)?.changeMarkersInSpectrum(self) }
    }
}
