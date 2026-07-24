//
//  CWWaterfall.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/1/06.
//  Swift port of CWWaterfall.m.
//

import Cocoa

@objc(CWWaterfall)
class CWWaterfall: RTTYWaterfall {

    override func drawMarkers() {
        if !active[Int(waterfallID)] { return }

        var diff = abs(txMark - mark[Int(waterfallID)])
        let separateTxAndRx = (txMark > 5.0)
        let rxColor: NSColor
        if separateTxAndRx {
            rxColor = magenta
        } else {
            rxColor = green
            diff = 0
        }

        if !separateTxAndRx || diff > 2.0 {
            let p = mark[Int(waterfallID)] + 0.5
            drawMarker(p, width: 2, color: black)
            drawMarker(p, width: 1.25, color: rxColor)
        }

        if separateTxAndRx {
            let p = txMark + 0.5
            drawMarker(p, width: 2, color: black)
            drawMarker(p, width: 1.25, color: green)
        } else {
            if abs(ritOffset) > 1.0 {
                let p = mark[Int(waterfallID)] + ritOffset + 0.5
                drawMarker(p, width: 2, color: black)
                drawMarker(p, width: 1.25, color: magenta)
            }
        }
    }

    override func setTransmitTonePairMarker(_ tonepair: UnsafePointer<CMTonePair>, index n: Int32) {
        txMarkFreq = Float(tonepair.pointee.mark)
        txSpaceFreq = Float(tonepair.pointee.space)

        if txMarkFreq < 5 {
            // lock tx to rx markers
            txMark = 0
            txSpace = 0
            return
        }

        var mf = (Float(tonepair.pointee.mark) - firstBinFreq) / hzPerPixel
        var sf = (Float(tonepair.pointee.space) - firstBinFreq) / hzPerPixel
        if sideband == 0 {
            mf = Float(width) - mf - 0.5
            sf = Float(width) - sf - 0.5
        } else {
            mf -= 0.5
            sf -= 0.5
        }
        txMark = mf
        txSpace = sf
    }

    override func eitherMouseDown(_ event: NSEvent, secondRx option: Bool) {
        guard let modem = modem else { return }

        let flags = event.modifierFlags
        let shift = flags.contains(.shift)

        if shift {
            drawLock.lock()
            if !option { click = 0 } else { optionClick = 0 }
            drawLock.unlock()
            offset = 0
            modem.turnOffReceiver(Int32(waterfallID), option: option)
            return
        }

        let location = self.convert(event.locationInWindow, from: nil)
        var f = firstBinFreq + ((sideband == 1) ? /* USB */ hzPerPixel * Float(location.x)
                                                : /* LSB */ hzPerPixel * (Float(width) - Float(location.x) - 1))
        let g = Float(location.y) * (4096.0 / Float(CMFs))     // 4096 samples per scanline

        drawLock.lock()
        click = Float(location.x)
        drawLock.unlock()

        if sideband == 0 { f += 3.5 }   // adjustment for cursor
        modem.clicked(f, secondsAgo: g, option: option, fromWaterfall: true, waterfallID: Int32(waterfallID))
    }

    override func scrollWheel(with event: NSEvent) {
        if let modem = modem, modem.isActiveTab() {
            let df: Float = (event.deltaY > 0) ? -2.0 : 2.0
            let flags = event.modifierFlags
            let option = flags.contains(.control)

            //  base frequency
            var freq = markFreq[Int(waterfallID)]
            if option {
                // receive
                freq += ritOffsetFreq
            }
            let f: Float = (sideband == 0) ? freq - df : freq + df
            modem.clicked(f, secondsAgo: 0, option: option, fromWaterfall: false, waterfallID: Int32(waterfallID))
        }
    }
}
