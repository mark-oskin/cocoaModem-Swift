//
//  PushedStereoDest.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/1/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of PushedStereoDest.m.  A ModemDest whose ResamplingPipe is driven
//  in "pushed" mode (variable output buffer size).  Its client supplies stereo
//  data through -needData:samples:channels:.
//

import Foundation
import Cocoa

@objc(PushedStereoDest)
class PushedStereoDest: ModemDest {

    @objc(initIntoView:device:level:client:)
    init?(intoView view: NSView?, device name: String, level: NSView?, client inClient: DestClient?) {
        super.init(intoView: view, device: name, level: level, client: inClient, channels: 2)

        //  use a pushed resampling pipe instead
        resamplingPipe?.setUseConstantOutputBufferSize(false)
    }

    override func needData(_ outbuf: UnsafeMutablePointer<Float>, samples n: Int32, channels ch: Int32) -> Int32 {
        if let client = client {
            return client.needData(outbuf, samples: n, channels: ch)
        }
        memset(outbuf, 0, MemoryLayout<Float>.size * Int(n) * Int(ch))
        return n
    }
}
