//
//  ModemEqualizerPlot.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/30/06.
//  Swift port of ModemEqualizerPlot.m.
//

import Cocoa

@objc(ModemEqualizerPlot)
class ModemEqualizerPlot: NSView {

    var width: Int32 = 0
    var height: Int32 = 0

    var plotColor: NSColor!
    var scaleColor: NSColor!
    var backgroundColor: NSColor!
    var plot: NSBezierPath?
    var scale: NSBezierPath!
    var background: NSBezierPath!

    @inline(__always)
    private func P(_ x: Float, _ y: Float) -> NSPoint {
        return NSPoint(x: CGFloat(x), y: CGFloat(y))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        let b = self.bounds
        width = Int32(b.size.width)
        height = Int32(b.size.height)

        plotColor = NSColor(calibratedRed: 0.9, green: 0.9, blue: 0, alpha: 1)
        plot = nil

        //  background
        backgroundColor = NSColor(deviceRed: 0, green: 0.1, blue: 0, alpha: 1)
        background = NSBezierPath(rect: b)
        //  scale
        scaleColor = NSColor(calibratedRed: 0, green: 1, blue: 0.1, alpha: 1)
        scale = NSBezierPath()
        scale.setLineDash([2.0, 1.0], count: 2, phase: 0)
        for i in 0..<4 {
            let n = Int32((0.1 + Double(i) * 0.24) * Double(width))
            let x = Float(n) + 0.5
            scale.move(to: P(x, 0))
            scale.line(to: P(x, Float(height)))
        }
        //  flat response: setResponse: reads 81 dB samples, so fill all 81
        //  (the array was previously sized 41, leaving 40 samples of
        //  uninitialized stack that could be NaN and crash NSBezierPath).
        //  0 dB == flat.
        var xp = [Float](repeating: 0.0, count: 81)
        setResponse(&xp)
    }

    //  accepts a response curve (dB) from 400 Hz to 2400 Hz inclusive
    //  (81 samples) at 25 Hz resolution
    @objc(setResponse:)
    func setResponse(_ array: UnsafeMutablePointer<Float>) {
        let newPlot = NSBezierPath()
        for i in 0..<81 {
            //  guard non-finite coordinates (a bad amplitude could make x inf)
            var x = Float((0.1 + Double(array[i]) * 0.24) * Double(width))
            var y = Float(Double(height) * (1.0 - Double(i) / 82.0) - 8.0)
            if !x.isFinite { x = 0 }
            if !y.isFinite { y = 0 }
            if i == 0 { newPlot.move(to: P(x, y)) } else { newPlot.line(to: P(x, y)) }
        }
        plot = newPlot
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.set()
        background.fill()
        //  insert scale
        scaleColor.set()
        scale.stroke()
        if let plot = plot {
            //  insert plot
            plotColor.set()
            plot.stroke()
        }
    }
}
