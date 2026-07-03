//
//  LiteRTTYControl.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/2/07.
//  Copyright 2007 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of LiteRTTYControl.m.  Thin RTTYRxControl subclass that also draws
//  the Lite RTTY spectrum.  Base ivars accessed by exact name.
//

import Cocoa

@objc(LiteRTTYControl)
class LiteRTTYControl: RTTYRxControl {

    @objc(initIntoView:client:index:)
    override init?(intoView view: NSView?, client modem: Modem?, index: Int32) {
        super.init()
        if Bundle.main.loadNibNamed("LiteRTTYControl", owner: self, topLevelObjects: nil) {
            //  loadNib should have set up controlView connection
            if let view = view, let cv = controlView {
                //  set level of NSPanel to floating level  v0.64e
                view.window?.level = .floating
                view.window?.orderOut(self)
                view.addSubview(cv)
                auxWindow?.title = (index == 0) ? NSLocalizedString("RTTY Receiver", comment: "") : NSLocalizedString("Sub Receiver", comment: "")
                setupWithClient(modem, index: index)
                activeIndicator?.backgroundColor = NSColor.gray
                return
            }
        }
        return nil
    }

    //  audio source starts at config and is routed here first
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        if receiver == nil || !receiver.enabled { return }

        super.importData(pipe)
        (client as? LiteRTTY)?.drawSpectrum(pipe)
    }

    //  v0.67
    @objc(setTonePair:mask:)
    override func setTonePair(_ tonepair: UnsafePointer<CMTonePair>, mask: Int32) {
        super.setTonePair(tonepair, mask: mask)
        if mask & 1 != 0 { (client as? LiteRTTY)?.changeMarkersInSpectrum(self) }
    }
}
