//
//  AMWaterfall.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/18/07.
//  Swift port of AMWaterfall.m.
//

import Cocoa

@objc(AMWaterfall)
class AMWaterfall: Waterfall {

    var fc: Float = 200.0
    var fl: Float = 100.0
    var fh: Float = 300.0

    override func awakeFromModem() {
        super.awakeFromModem()
        noiseReduction = false
        startingBin = Int(100.0 / 2.69179 - 8.0)
        fc = 200.0
        fl = 100.0
        fh = 300.0
    }

    private func drawShortMarker(_ p: Float, width lineWidth: Float, color: NSColor) {
        guard p.isFinite else { return }
        let line = NSBezierPath()
        line.lineWidth = CGFloat(lineWidth)
        line.move(to: NSPoint(x: CGFloat(p), y: 0))
        line.line(to: NSPoint(x: CGFloat(p), y: 4))
        color.set()
        line.stroke()
    }

    override func drawMarkers() {
        var p = Float(Waterfall.cTruncInt(fh / 5.38 - 15)) + 0.5
        drawMarker(p, width: 2, color: black)
        drawMarker(p, width: 1, color: green)
        p = Float(Waterfall.cTruncInt(fl / 5.38 - 14)) - 0.5
        drawMarker(p, width: 2, color: black)
        drawMarker(p, width: 1, color: green)
        p = Float(Waterfall.cTruncInt(fc / 5.38 - 14))
        drawShortMarker(p, width: 5, color: green)
    }

    @objc(setTrack:low:high:)
    func setTrack(_ center: Float, low: Float, high: Float) {
        fc = center
        fl = low
        fh = high
    }

    @objc(setTrack:)
    func setTrack(_ center: Float) {
        fc = center
    }

    private func importAndDisplayInMainThread(_ pipe: CMPipe) {
        //  ignore data overruns
        if drawLock.try() {
            let stream = pipe.stream()!
            let data = stream.pointee.array
            let samples = Int(stream.pointee.samples)

            //  copy new buffer (512) into fft buffer (4096)
            let limit = 4096 - samples
            if mux > limit { mux = limit }
            memcpy(timeSample + mux, data, samples * MemoryLayout<Float>.size)
            mux += samples

            if mux >= 4096 {
                mux = 0
                CMPerformFFT(spectrum, timeSample, freqBin)

                //  scroll waterfall up
                let base = UnsafeMutableRawPointer(pixel!)
                memcpy(base, base + rowBytes, rowBytes * (height - 5))
                //  5.38 Hz per pixel
                let startBin = freqBin + startingBin
                if depth >= 24 {
                    let line = (base + rowBytes * (height - 5)).assumingMemoryBound(to: UInt32.self)
                    for i in 0..<width { line[i] = plotIntensity((startBin[i * 2] + startBin[i * 2 + 1]) * 0.5) }
                } else {
                    let sline = (base + rowBytes * (height - 5)).assumingMemoryBound(to: UInt16.self)
                    for i in 0..<width {
                        sline[i] = UInt16(truncatingIfNeeded: plotIntensity((startBin[i * 2] + startBin[i * 2 + 1]) * 0.5))
                    }
                }
                self.performSelector(onMainThread: #selector(displayInMainThread), with: pipe, waitUntilDone: false)
            }
            drawLock.unlock()
        }
    }

    //  v0.76 added simple importData back here
    override func importData(_ pipe: CMPipe) {
        if modem == nil { return }
        importAndDisplayInMainThread(pipe)
    }

    override func setOffset(_ freq: Float, sideband inSideband: Int32) {
        //  Left edge is 100 Hz and right edge 4145 Hz (752 pixels at 5.38 Hz per pixel)

        vfoOffset = freq
        var nearest = (Waterfall.cTruncInt(freq) / 100) * 100
        if (freq - Float(nearest)) > 50.0 { nearest += 100 }

        let pixelOffset = (freq - Float(nearest)) / (hzPerPixel * 2)
        var fstart: Int32 = 100
        for i in 0..<21 {
            let label = waterfallLabel.cell(atRow: 0, column: i)
            let actual = fstart - Int32(nearest)
            if (actual - 100) % 400 == 0 && actual > 100 { label?.intValue = actual } else { label?.stringValue = "" }
            fstart += 200
        }

        var frame = waterfallLabel.frame
        frame.origin.x = CGFloat(pixelOffset - 15)
        waterfallLabel.frame = frame
        waterfallLabel.display()

        frame = waterfallTicks.frame
        frame.origin.x = CGFloat(pixelOffset + 1 - 37.1 + 0.5)
        waterfallTicks.frame = frame
        waterfallTicks.display()
    }
}
