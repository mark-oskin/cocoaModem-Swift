//
//  MiniSpectrum.swift
//  cocoaModem
//
//  Created by Kok Chen on 8/7/05.
//  Swift port of MiniSpectrum.m.
//

import Cocoa

@objc(MiniSpectrum)
class MiniSpectrum: Spectrum {

    //  spectrum view is 620 wide x 110 tall
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        miniConfigure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        miniConfigure()
    }

    private func miniConfigure() {
        plotWidth = 620
        scale = plotWidth / 408
        pixPerdB = 1.25

        let newScale = NSBezierPath()
        newScale.setLineDash([1.0, 2.0], count: 2, phase: 0)
        var i: Int32 = 5
        while i < 80 {
            let y = Float(Int32(Float(height) - Float(i) * pixPerdB)) + 0.5
            if y <= 0 { break }
            newScale.move(to: P(0, y))
            newScale.line(to: P(plotWidth, y))
            i += 30
        }
        i = 500
        while i < 3000 {
            let x = Float(iFromD(Double(i - 400) * Double(plotWidth) / 2200.0)) + 0.5
            newScale.move(to: P(x, 0))
            newScale.line(to: P(x, Float(height)))
            i += 500
        }
        spectrumScale = newScale
    }
}
