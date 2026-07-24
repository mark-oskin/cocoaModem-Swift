//
//  ChannelSelector.swift
//  cocoaModem
//
//  Created by Kok Chen on 2/25/05.
//  Swift port of ChannelSelector.{h,m}.
//
//  Some CMPipe data streams contain two (stereo) channels arranged as vDSP
//  "split complex" channels: left[0..n-1], right[0..n-1].  ChannelSelector
//  passes the data out so it looks like just the left or the right channel.
//

import Foundation

@objc(ChannelSelector)
class ChannelSelector: CMTappedPipe {

    internal var selected: Int32

    override init() {
        selected = 0
        super.init()
        selected = 0
    }

    //  channel = { 0, 1 } for stereo (0 = left, 1 = right)
    @objc(selectChannel:)
    func selectChannel(_ channel: Int32) {
        var channel = channel
        if channel < 0 { channel = 0 } else if channel > 1 { channel = 1 }
        selected = channel
    }

    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        data.pointee = pipe.stream().pointee
        if selected != 0 && data.pointee.channels > 1 {
            var offset = selected
            if offset > (data.pointee.channels - 1) { offset = 0 }
            data.pointee.array = data.pointee.array?.advanced(by: Int(data.pointee.samples) * Int(offset))
        }
        exportData()
    }
}
