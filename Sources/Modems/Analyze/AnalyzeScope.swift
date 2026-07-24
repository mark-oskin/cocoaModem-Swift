//
//  AnalyzeScope.swift
//  cocoaModem
//
//  Created by Kok Chen on 3/4/05.
//  Swift port of AnalyzeScope.m.
//
//  NSView drawing.  Every value handed to NSBezierPath / NSMakePoint is
//  finite-guarded so a bad (NaN/inf) sample can never trap the drawing code.
//

import Cocoa

@objc(AnalyzeScope)
class AnalyzeScope: NSView {

    private var width: Int32 = 0
    private var height: Int32 = 0
    private var plotWidth: Int32 = 0
    private var plotOffset: Int32 = 0

    private var scaleColor: NSColor!
    private var waveformColor: NSColor!
    private var backgroundColor: NSColor!
    private var baudotColor: NSColor!

    private var background: NSBezierPath!
    private var waveformScale: NSBezierPath!
    private var baudot: NSBezierPath!
    private var plotPath: NSBezierPath?

    private var index = [Int32](repeating: 0, count: 8)

    //  C inline float arrays kept as explicit heap buffers (freed in deinit).
    private let refData = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let dutData = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let syncData = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let markData = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let spaceData = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let compensatedData = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let markProjection = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let spaceProjection = UnsafeMutablePointer<Float>.allocate(capacity: 256)

    @inline(__always)
    private func P(_ x: Float, _ y: Float) -> NSPoint {
        return NSPoint(x: CGFloat(x), y: CGFloat(y))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    //  Modern keyed nibs instantiate NSView subclasses through initWithCoder:.
    //  The ObjC original only overrode initWithFrame:, so run identical setup here.
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        let bounds = self.bounds
        let size = bounds.size
        width = Int32(size.width)
        height = Int32(size.height)
        plotWidth = 512
        plotOffset = 4

        for i in 0..<256 {
            refData[i] = 0; dutData[i] = 0; syncData[i] = 0
            markData[i] = 0; spaceData[i] = 0; compensatedData[i] = 0
            markProjection[i] = 0; spaceProjection[i] = 0
        }

        background = NSBezierPath()
        background.appendRect(bounds)
        backgroundColor = NSColor(deviceRed: 0, green: 0.1, blue: 0, alpha: 1)

        //  set up waveform scale
        waveformColor = NSColor(calibratedRed: 0, green: 1, blue: 0.1, alpha: 1)
        scaleColor = NSColor(calibratedRed: 0.9, green: 0.9, blue: 0, alpha: 1)
        baudotColor = NSColor(calibratedRed: 0.7, green: 0, blue: 0, alpha: 1)

        let h = Float(height)
        waveformScale = NSBezierPath()
        waveformScale.setLineDash([1.0, 1.0], count: 2, phase: 0)
        var y = Float(height / 2) + 0.5
        waveformScale.move(to: P(Float(plotOffset), y))
        waveformScale.line(to: P(Float(plotWidth + plotOffset), y))
        y = Float(Int32(h * 0.125)) + 0.5
        waveformScale.move(to: P(Float(plotOffset), y))
        waveformScale.line(to: P(Float(plotWidth + plotOffset), y))
        y = Float(Int32(h * 0.875)) + 0.5
        waveformScale.move(to: P(Float(plotOffset), y))
        waveformScale.line(to: P(Float(plotWidth + plotOffset), y))

        baudot = NSBezierPath()
        for i in 1..<8 {
            let x = Float(plotOffset) + Float(Int32(Double(i) * 30.32 * 2)) + 0.5
            baudot.move(to: P(x, 10))
            baudot.line(to: P(x, h - 10))
        }
        plotPath = nil

        for i in 0..<8 {
            index[i] = Int32(Double(i) * 30.32 + 30.32 * 0.5 + 0.5)
        }
    }

    deinit {
        refData.deallocate()
        dutData.deallocate()
        syncData.deallocate()
        markData.deallocate()
        spaceData.deallocate()
        compensatedData.deallocate()
        markProjection.deallocate()
        spaceProjection.deallocate()
    }

    override func draw(_ frame: NSRect) {
        if lockFocusIfCanDraw() {
            //  clear background
            backgroundColor.set()
            background.fill()
            //  insert scale
            scaleColor.set()
            waveformScale.stroke()
            //  baudot bit markers (30.32*2 pixels apart)
            baudotColor.set()
            baudot.stroke()
            //  insert graph
            if let plotPath = plotPath {
                waveformColor.set()
                plotPath.stroke()
            }
            unlockFocus()
        }
    }

    //  local
    @objc func displayInMainThread() {
        needsDisplay = true
    }

    @objc(updatePlot:)
    func updatePlot(_ which: Int32) {
        let data: UnsafeMutablePointer<Float>

        //  check which mode
        switch which {
        case 1:  data = dutData
        case 2:  data = markData
        case 3:  data = spaceData
        case 4:  data = syncData
        case 5:  data = compensatedData
        case 6:  data = markProjection
        case 7:  data = spaceProjection
        default: data = refData
        }

        //  create new plot
        let yoffset = Float(height / 2)
        let ygain = -yoffset * 0.75
        let xgain: Float = 2
        let h = Float(height)

        let newPath = NSBezierPath()
        for i in 0..<256 {
            let x = Float(plotOffset) + Float(i) * xgain
            var y = yoffset - data[i] * ygain
            if !y.isFinite { y = yoffset }
            if y >= h { y = h - 1 } else if y < 0 { y = 0 }
            if i == 0 { newPath.move(to: P(x, y)) } else { newPath.line(to: P(x, y)) }
        }
        plotPath = newPath
        perform(#selector(displayInMainThread), on: Thread.main, with: nil, waitUntilDone: false)
    }

    @objc(addReference:)
    func addReference(_ data: UnsafeMutablePointer<CMATCPair>) {
        var scale = abs(data[0].mark - data[0].space) + 0.001
        for i in 0..<256 {
            let t = data[i].mark - data[i].space
            let a = abs(t)
            if a > scale { scale = a }
            refData[i] = t
        }
        scale = 1.0 / scale
        for i in 0..<256 { refData[i] *= scale }
    }

    @objc(addDUT:)
    func addDUT(_ data: UnsafeMutablePointer<CMATCPair>) {
        var scale = abs(data[0].mark - data[0].space) + 0.001
        for i in 0..<256 {
            let t = data[i].mark - data[i].space
            let a = abs(t)
            if a > scale { scale = a }
            dutData[i] = t
        }
        scale = 1.0 / scale
        for i in 0..<256 {
            dutData[i] *= scale
            markData[i] = data[i].mark * scale * 2 - 1.0
            spaceData[i] = data[i].space * scale * 2 - 1.0
        }
    }

    @objc(addCompensated:)
    func addCompensated(_ data: UnsafeMutablePointer<CMATCPair>) {
        var scale = abs(data[0].mark - data[0].space) + 0.001
        for i in 0..<256 {
            let t = data[i].mark - data[i].space
            let a = abs(t)
            if a > scale { scale = a }
        }
        scale = 1.0 / scale

        for i in 0..<256 {
            if (data[i].mark * scale * 2 - 1.0) * (data[i].space * scale * 2 - 1.0) < 0 {
                compensatedData[i] = ((data[i].mark * scale * 2 - 1.0) > 0) ? 1.0 : -1.0
            } else {
                compensatedData[i] = 0
            }

            //  index[2] is bit 0
            for j in 2..<7 {
                let cj = Int(index[j])
                if compensatedData[cj] == 0 {
                    //  indeterminate bit
                    if compensatedData[Int(index[j - 1])] * compensatedData[Int(index[j + 1])] < 1 {
                        let v = compensatedData[Int(index[j + 1])] * 0.5
                        compensatedData[cj] = v
                        compensatedData[cj - 1] = v
                        compensatedData[cj + 1] = v
                    }
                }
            }

            markProjection[i] = (data[i].mark * scale * 2 - 1.0)
            spaceProjection[i] = (data[i].space * scale * 2 - 1.0)
        }
    }

    @objc(addSync:)
    func addSync(_ data: UnsafeMutablePointer<Float>) {
        for i in 0..<256 { syncData[i] = data[i] }
    }
}
