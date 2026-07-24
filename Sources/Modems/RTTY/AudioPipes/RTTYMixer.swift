//
//  RTTYMixer.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/8/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//  Swift port of RTTYMixer.{h,m}.  A CMFSKMixer that also feeds the RTTY aural
//  monitor.
//

import Foundation

@objc(RTTYMixer)
class RTTYMixer: CMFSKMixer {

    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        super.importData(pipe)

        if let auralMonitor = auralMonitor {
            let stream = pipe.stream()!
            if let array = stream.pointee.array {
                auralMonitor.newBandpassFilteredData(array, scale: 1.0, fromReceiver: true)
            }
        }
    }

    @objc(setTonePair:)
    override func setTonePair(_ tonepair: UnsafePointer<CMTonePair>!) {
        super.setTonePair(tonepair)
        if let auralMonitor = auralMonitor { auralMonitor.setTonePair(tonepair) }
    }

    @objc(tonePairSelectedFromMemory:)
    func tonePairSelectedFromMemory(_ tonepair: UnsafePointer<CMTonePair>!) {
    }
}
