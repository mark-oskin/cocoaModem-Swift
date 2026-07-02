//
//  RTTYWaterfall.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/23/05.
//  Swift port of RTTYWaterfall.m.
//

import Cocoa

@objc(RTTYWaterfall)
class RTTYWaterfall: Waterfall {

    var mark: [Float] = [0, 0, 0, 0]
    var space: [Float] = [0, 0, 0, 0]
    var markFreq: [Float] = [0, 0, 0, 0]
    var spaceFreq: [Float] = [0, 0, 0, 0]
    var txMark: Float = 0, txSpace: Float = 0
    var txMarkFreq: Float = 0, txSpaceFreq: Float = 0
    var active: [Bool] = [false, false, false, false]

    var ritOffset: Float = 0, ritOffsetFreq: Float = 0
    var ignoreSideband = false
    var ignoreArrowKeys = false

    override func awakeFromModem() {
        super.awakeFromModem()
        for i in 0..<4 {
            mark[i] = 0
            space[i] = 0
            markFreq[i] = 2125.0
            spaceFreq[i] = 2295.0
            active[i] = false
            ritOffset = 0
            ritOffsetFreq = 0
            ignoreSideband = false
            ignoreArrowKeys = false
        }
        txMark = 0
        txSpace = 0
        txMarkFreq = 2125.0
        txSpaceFreq = 2295.0
    }

    //  v0.67 rewrite
    //  if effective receive tones (including RIT) is different from transmit tones, draw two sets of markers.
    override func drawMarkers() {
        if !active[Int(waterfallID)] { return }

        let actualRxMark = mark[Int(waterfallID)] + ritOffset
        let actualRxSpace = space[Int(waterfallID)] + ritOffset

        let actualTxMark: Float
        let actualTxSpace: Float
        if txMark < 5.0 {
            actualTxMark = mark[Int(waterfallID)]
            actualTxSpace = space[Int(waterfallID)]
        } else {
            actualTxMark = txMark
            actualTxSpace = txSpace
        }

        let separateTxAndRx = (abs(actualTxMark - actualRxMark) > 1.5) || (abs(actualTxSpace - actualRxSpace) > 1.5)

        let rxColor: NSColor = separateTxAndRx ? magenta : green

        //  draw receive frequency -- use magenta if receive != transmit
        var p = actualRxMark + 0.5
        if wideWaterfall {
            if sideband == 0 { p = p * 0.5 + Float(width) * 0.5 - 3.5 } else { p = p * 0.5 + 3.5 }
        }
        drawMarker(p, width: 2, color: black)
        drawMarker(p, width: 1.25, color: rxColor)

        p = actualRxSpace + 0.5
        if wideWaterfall {
            if sideband == 0 { p = p * 0.5 + Float(width) * 0.5 - 3.5 } else { p = p * 0.5 + 3.5 }
        }
        drawMarker(p, width: 2, color: black)
        drawMarker(p, width: 1.25, color: rxColor)

        //  if receive != transmit, draw transmit frequency
        if separateTxAndRx {
            p = actualTxMark + 0.5
            if wideWaterfall {
                if sideband == 0 { p = p * 0.5 + Float(width) * 0.5 - 3.5 } else { p = p * 0.5 + 3.5 }
            }
            drawMarker(p, width: 2, color: black)
            drawMarker(p, width: 1.25, color: green)

            p = actualTxSpace + 0.5
            if wideWaterfall {
                if sideband == 0 { p = p * 0.5 + Float(width) * 0.5 - 3.5 } else { p = p * 0.5 + 3.5 }
            }
            drawMarker(p, width: 2, color: black)
            drawMarker(p, width: 1.25, color: green)
        }
    }

    @objc(setIgnoreSideband:)
    func setIgnoreSideband(_ state: Bool) {
        ignoreSideband = state
        if ignoreSideband { sideband = 1 }
    }

    @objc(setIgnoreArrowKeys:)
    func setIgnoreArrowKeys(_ state: Bool) {
        ignoreArrowKeys = state
    }

    @objc(setActive:index:)
    func setActive(_ state: Bool, index n: Int32) {
        active[Int(n)] = state
        self.performSelector(onMainThread: #selector(NSView.display as (NSView) -> () -> Void), with: nil, waitUntilDone: false)
    }

    override func setSideband(_ which: Int32) {
        if !ignoreSideband {
            sideband = Int(which)
            ritOffset = 0
            useVFOOffset(vfoOffset)
        }
    }

    @objc(setTonePairMarker:index:)
    func setTonePairMarker(_ tonepair: UnsafePointer<CMTonePair>, index n: Int32) {
        markFreq[Int(n)] = Float(tonepair.pointee.mark)
        spaceFreq[Int(n)] = Float(tonepair.pointee.space)

        ritOffset = 0
        var mf = (Float(tonepair.pointee.mark) - firstBinFreq) / hzPerPixel
        var sf = (Float(tonepair.pointee.space) - firstBinFreq) / hzPerPixel
        if sideband == 0 {
            mf = Float(width) - mf - 0.5
            sf = Float(width) - sf - 0.5
        } else {
            mf -= 0.5
            sf -= 0.5
        }
        mark[Int(n)] = mf
        space[Int(n)] = sf
    }

    @objc(setTransmitTonePairMarker:index:)
    func setTransmitTonePairMarker(_ tonepair: UnsafePointer<CMTonePair>, index n: Int32) {
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

    @objc(setRITOffset:)
    func setRITOffset(_ rit: Float) {
        ritOffsetFreq = rit
        ritOffset = rit / hzPerPixel
        if sideband == 0 { ritOffset = -ritOffset }
    }

    override func arrowKeyTune(_ notify: Notification) {
        //  no arrow tuning
    }

    override func setOffset(_ freq: Float, sideband inSideband: Int32) {
        sideband = Int(inSideband)
        useVFOOffset(freq)
    }

    @objc(useVFOOffset:)
    func useVFOOffset(_ freq: Float) {
        vfoOffset = freq
        var nearest = (Waterfall.cTruncInt(freq) / 100) * 100
        if (freq - Float(nearest)) > 50.0 { nearest += 100 }

        let pixelOffset: Float
        //  sideband: LSB = 0, USB = 1, 2.69179 Hz/pixel
        if sideband == 1 {
            //  USB
            pixelOffset = (freq - Float(nearest)) / hzPerPixel
            if wideWaterfall {
                var fstart: Int32 = 400
                for i in 0..<22 {
                    let label = waterfallLabel.cell(atRow: 0, column: i)
                    let actual = fstart - Int32(nearest)
                    if actual % 600 == 0 && i != 0 { label?.intValue = actual } else { label?.stringValue = "" }
                    fstart += 200
                }
            } else {
                var fstart: Int32 = 400
                for i in 0..<23 {
                    let label = waterfallLabel.cell(atRow: 0, column: i)
                    let actual = fstart - Int32(nearest)
                    if actual % 500 == 0 && i != 0 { label?.intValue = actual } else { label?.stringValue = "" }
                    fstart += 100
                }
            }
        } else {
            // LSB
            pixelOffset = -(freq - Float(nearest)) / hzPerPixel - 1 + 26 /* 778-752 */ - 33 /* wider RTTY waterfall */
            if wideWaterfall {
                var fstart: Int32 = 4800
                for i in 0..<22 {
                    let label = waterfallLabel.cell(atRow: 0, column: i)
                    let actual = fstart - Int32(nearest)
                    if actual % 600 == 0 && i != 0 { label?.intValue = -actual } else { label?.stringValue = "" }
                    fstart -= 200
                }
            } else {
                var fstart: Int32 = 2600
                for i in 0..<23 {
                    let label = waterfallLabel.cell(atRow: 0, column: i)
                    let actual = fstart - Int32(nearest)
                    if actual % 500 == 0 && i != 0 { label?.intValue = -actual } else { label?.stringValue = "" }
                    fstart -= 100
                }
            }
        }
        var frame = waterfallLabel.frame
        frame.origin.x = CGFloat(pixelOffset - 15)
        waterfallLabel.frame = frame
        waterfallLabel.display()

        frame = waterfallTicks.frame
        frame.origin.x = CGFloat(pixelOffset + 1 - 37.1 + 0.5)
        frame.origin.x += (sideband == 0) ? -1.0 : 1.0
        waterfallTicks.frame = frame
        waterfallTicks.display()

        //  update memory offsets after sidebands is set
        for i in 0..<4 {
            var tonepair = CMTonePair(mark: Double(markFreq[i]), space: Double(spaceFreq[i]), baud: 0)
            setTonePairMarker(&tonepair, index: Int32(i))
        }
    }

    override func eitherMouseDown(_ event: NSEvent, secondRx option: Bool) {
        guard let modem = modem else { return }

        let location = self.convert(event.locationInWindow, from: nil)

        var f: Float
        if wideWaterfall {
            f = firstBinFreq + ((sideband == 1) ? 2 * hzPerPixel * Float(location.x)
                                                : 2 * hzPerPixel * (Float(width) - Float(location.x) - 1)) - 15.0
        } else {
            f = firstBinFreq + ((sideband == 1) ? /* USB */ hzPerPixel * Float(location.x)
                                                : /* LSB */ hzPerPixel * (Float(width) - Float(location.x) - 1))
        }
        let g = Float(location.y) * (4096.0 / Float(CMFs))     // 4096 samples per scanline

        drawLock.lock()
        click = Float(location.x)
        drawLock.unlock()

        if sideband == 0 { f += 3.5 }   // adjustment for cursor
        modem.clicked(f, secondsAgo: g, option: option, fromWaterfall: true, waterfallID: Int32(waterfallID))
    }

    //  trap mouse and mouse with control key
    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let option = flags.contains(.control)
        eitherMouseDown(event, secondRx: option)
    }

    override func rightMouseDown(with event: NSEvent) {
        eitherMouseDown(event, secondRx: true)
    }

    override func scrollWheel(with event: NSEvent) {
        if let modem = modem, modem.isActiveTab() {
            let df: Float = (event.deltaY > 0) ? -2.0 : 2.0
            let flags = event.modifierFlags
            let option = flags.contains(.control)

            //  base frequency
            var lower = markFreq[Int(waterfallID)]
            var higher = spaceFreq[Int(waterfallID)]
            if option {
                // receive
                lower += ritOffsetFreq
                higher += ritOffsetFreq
            }
            if lower > higher {
                let f = lower
                lower = higher
                higher = f
            }
            let f: Float = (sideband == 0) ? lower - df : higher + df
            modem.clicked(f, secondsAgo: 0, option: option, fromWaterfall: false, waterfallID: Int32(waterfallID))
        }
    }
}
