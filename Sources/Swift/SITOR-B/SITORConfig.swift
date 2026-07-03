//
//  SITORConfig.swift
//  cocoaModem
//
//  Created by Kok Chen on Feb 6 06.
//  Swift port of SITORConfig.m.  SITORConfig is a subclass of WFRTTYConfig (in
//  this batch); it overrides -openPanel, -awakeFromModem:... and the
//  -importData: fast path.
//

import Cocoa

@objc(SITORConfig)
class SITORConfig: WFRTTYConfig {

    override func openPanel() {
        window.center()
        window.orderFront(self)
        //  set modem as delegate of config's window to catch closes.  The modem
        //  (Objective-C SITOR) implements -windowShouldClose: informally but does
        //  not declare <NSWindowDelegate>, so assign through the ObjC runtime
        //  rather than an `as? NSWindowDelegate` cast (which would yield nil).
        window.perform(Selector(("setDelegate:")), with: modemObj)
        configOpen = true
        updateInputSamplingState()
    }

    @objc(awakeFromModem:rttyRxControl:txConfig:)
    override func awakeFromModem(_ set: UnsafeMutablePointer<RTTYConfigSet>, rttyRxControl control: AnyObject?, txConfig inTxConfig: RTTYTxConfig?) {
        super.awakeFromModem(set, rttyRxControl: control, txConfig: nil)
        setInterface(vfoOffsetField, to: #selector(WFRTTYConfig.vfoOffsetChanged))
    }

    //  data arrived from sound source
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        if ((isActiveButton && !isTransmit) || (modemSource?.fileRunning() ?? false)) && interfaceVisible {
            if let src = pipe.stream(), let dst = self.stream() { dst.pointee = src.pointee }
            exportData()
            (vuMeter as? VUMeter)?.importData(pipe)
        }
        if configOpen, oscilloscope != nil {
            (oscilloscope as? Oscilloscope)?.addData(pipe.stream(), isBaudot: false, timebase: 1)
        }
    }
}
