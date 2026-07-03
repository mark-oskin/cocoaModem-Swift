//
//  CWConfig.swift
//  cocoaModem
//
//  Created by Kok Chen on Dec 1 06.
//  Swift port of CWConfig.m.  CWConfig is a subclass of WFRTTYConfig (in this
//  batch); it overrides the -importData: fast path and adds -setCWKeyerMode:ptt:.
//

import Cocoa

@objc(CWConfig)
class CWConfig: WFRTTYConfig {

    //  data arrived from input sound source
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        if overrun?.`try`() == true {
            if interfaceVisible {
                if (isActiveButton && !isTransmit) || (modemSource?.fileRunning() ?? false) {
                    if let src = pipe.stream(), let dst = self.stream() { dst.pointee = src.pointee }
                    exportData()
                    (vuMeter as? VUMeter)?.importData(pipe)
                }
                if configOpen, oscilloscope != nil {
                    (oscilloscope as? Oscilloscope)?.addData(pipe.stream(), isBaudot: false, timebase: 1)
                }
            }
            overrun?.unlock()
        }
    }

    //  v0.87
    //  tag =   0   J2A
    //          1   OOK
    //          2   OOK : digiKeyer
    @objc(setCWKeyerMode:ptt:)
    func setCWKeyerMode(_ tag: Int32, ptt: PTT?) {
        //  Fixed CW Routing (OOK digiKeyer) or Fixed Digital Routing otherwise.
        let mode = (tag == 2) ? kMicrohamCWRouting : kMicrohamDigitalRouting
        ptt?.setKeyerMode(mode)
    }
}
