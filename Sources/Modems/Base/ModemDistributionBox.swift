//
//  ModemDistributionBox.swift
//  cocoaModem
//
//  Created by Kok Chen on Wed Jun 09 2004.
//  Swift port of ModemDistributionBox.{h,m}.  Sends the audio stream to two
//  CMPipe destinations (each may be nil).
//

import Foundation

@objc(ModemDistributionBox)
class ModemDistributionBox: CMTappedPipe {

    internal var first: CMPipe?
    internal var second: CMPipe?

    override init() {
        super.init()
        first = nil
        second = nil
    }

    @objc(setFirst:second:)
    func setFirst(_ p1: CMPipe?, second p2: CMPipe?) {
        first = p1
        second = p2
    }

    @objc(setFirst:)
    func setFirst(_ p1: CMPipe?) {
        first = p1
    }

    @objc(setSecond:)
    func setSecond(_ p2: CMPipe?) {
        second = p2
    }

    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        if let first = first { first.importData(pipe) }
        if let second = second { second.importData(pipe) }
    }
}
