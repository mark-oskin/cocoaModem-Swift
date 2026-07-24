//
//  DualRTTYConfig.swift
//  cocoaModem
//
//  Created by Kok Chen on 9/11/05.
//  Swift port of DualRTTYConfig.m.  DualRTTYConfig is a subclass of RTTYConfig
//  (now Swift); it only overrides the -importData: fast path.
//

import Cocoa

@objc(DualRTTYConfig)
class DualRTTYConfig: RTTYConfig {

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
