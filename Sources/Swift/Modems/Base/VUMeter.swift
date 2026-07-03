//
//  VUMeter.swift
//  cocoaModem
//
//  Created by Kok Chen on 1/31/05.
//  Swift port of VUMeter.{h,m}.  A CMPipe that drives a 9-segment VU meter on
//  the main thread.
//
//  The original global `int vuSegmentTable[1416]` (defined in main.m, used only
//  by VUMeter) is here a file-private table with identical contents, rebuilt on
//  each -setup exactly as before.
//

import Cocoa

//  amplitude -> segment count lookup, filled by -setup (was the C global vuSegmentTable)
private var vuSegmentTable = [Int32](repeating: 0, count: 1416)

//  was the C `VUElement` struct (referenced only by VUMeter)
private struct VUElement {
    var segment: VUSegment?
    var state: Bool = false
    var onColor: NSColor?
}

@objc(VUMeter)
class VUMeter: CMPipe {

    @objc var matrix: NSMatrix!
    @objc var background: NSView!

    //  vu meter
    private var vu = [VUElement](repeating: VUElement(), count: 9)
    private var vuOffColor: NSColor?
    private var vuLevel: Float = 0.0

    private var overrunLock: NSLock?

    @objc func setup() {
        overrunLock = NSLock()
        //  VU meter
        vuOffColor = NSColor(calibratedRed: 0.25, green: 0.25, blue: 0.25, alpha: 1)
        for i in 0..<9 {
            vu[i].segment = matrix.cell(atRow: 0, column: i) as? VUSegment
            vu[i].state = false
            if i == 7 {
                vu[i].onColor = NSColor(calibratedRed: 0.9, green: 0.9, blue: 0, alpha: 1)
            } else if i == 8 {
                vu[i].onColor = NSColor(calibratedRed: 0.85, green: 0, blue: 0, alpha: 1)
            } else {
                vu[i].onColor = NSColor(calibratedRed: 0, green: 0.7, blue: 0, alpha: 1)
            }
            vu[i].segment?.backgroundColor = vuOffColor
        }

        //  red at -0.5 dBmax, yellow at -1.0 dBmax and then 3 dB per step below that
        for i in 0..<1416 {
            let v = Double(i) / 1415.0
            let n: Int32
            if v > 0.89 { n = 9 }
            else if v > 0.8 { n = 8 }
            else if v > 0.5656 { n = 7 }
            else if v > 0.4 { n = 6 }
            else if v > 0.2828 { n = 5 }
            else if v > 0.2 { n = 4 }
            else if v > 0.1414 { n = 3 }
            else if v > 0.1 { n = 2 }
            else if v > 0.0707 { n = 1 } else { n = 0 }
            vuSegmentTable[i] = n
        }
        vuLevel = 0.0
    }

    //  sets the color of each VU meter segment
    //  NOTE:  this is executed in the main thread from -importData
    @objc(importDataInMainThread:)
    func importDataInMainThread(_ pipe: CMPipe!) {
        guard let overrunLock = overrunLock, overrunLock.try() else { return }

        let array = pipe.stream().pointee.array!
        //  sample about 20ms of data for amplitude
        for i in 0..<30 {
            var v = array[i]
            if v < 0 { v = -v }
            if v > vuLevel { vuLevel = v } else { vuLevel = vuLevel * 0.998 + v * 0.002 }
        }

        let f = Double(vuLevel) * 1414.2
        var index = f.isFinite ? Int(f) : 0
        if index > 1415 { index = 1415 }
        if index < 0 { index = 0 }
        let n = vuSegmentTable[index]

        var hasChange = false
        for i in 0..<9 {
            if n >= Int32(i + 1) {
                if vu[i].state == false {
                    vu[i].segment?.backgroundColor = vu[i].onColor
                    vu[i].state = true
                    hasChange = true
                }
            } else {
                if vu[i].state == true {
                    vu[i].segment?.backgroundColor = vuOffColor
                    vu[i].state = false
                    hasChange = true
                }
            }
        }
        if hasChange { matrix.display() }       //  v0.73 changed from setNeedsDisplay
        overrunLock.unlock()
    }

    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        performSelector(onMainThread: #selector(importDataInMainThread(_:)), with: pipe, waitUntilDone: false)
    }
}
