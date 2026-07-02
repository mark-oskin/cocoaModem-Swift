//
//  PSKContestTxControl.swift
//  cocoaModem
//
//  Created by Kok Chen on 11/12/04.
//  Swift port of PSKContestTxControl.m.  Subclass of the (now Swift)
//  PSKTransmitControl.  PSK stays Objective-C (header in the bridging header).
//

import Cocoa

@objc(PSKContestTxControl)
class PSKContestTxControl: PSKTransmitControl {

    @objc(initIntoView:client:)
    override init?(intoView view: NSView?, client modem: Modem?) {
        super.init()
        receiver = nil
        psk = modem as? PSK
        index = 0
        if Bundle.main.loadNibNamed("PSKContestTxControl", owner: self, topLevelObjects: nil) {
            // loadNib should have set up controlView connection
            if let view = view, let cv = controlView { view.addSubview(cv) }
            index = Int32(vfoMenu?.indexOfSelectedItem ?? 0)
            return
        }
        return nil
    }

    @objc(flushBuffer:)
    func flushBuffer(_ sender: Any?) {
        if let psk = psk { psk.flushAndLeaveTransmit() }
    }
}
