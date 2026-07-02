//
//  MFSKIndicatorLabel.swift
//  cocoaModem
//
//  Created by Kok Chen on Jan 30 2007.
//  Swift port of MFSKIndicatorLabel.m.
//
//  Draw fixed tick marks (16 ticks with 16 pixels separation)

import Cocoa

@objc(MFSKIndicatorLabel)
class MFSKIndicatorLabel: NSImageView {

    private var width = 0, height = 0
    private var background: NSBezierPath!
    private var offset = 0
    private var locked = false
    private var color: NSColor!
    private var bins = 16

    override func awakeFromNib() {
        super.awakeFromNib()
        offset = 5 * 16
        locked = true
        let bounds = self.bounds
        let bsize = bounds.size
        width = Int(bsize.width)
        height = Int(bsize.height)
        background = NSBezierPath()
        background.appendRect(bounds)
        color = NSColor(calibratedRed: 0.95, green: 0, blue: 0, alpha: 1)
        bins = 16
    }

    //  v0.73  for setting to DominoEX bins
    @objc(setBins:)
    func setBins(_ value: Int32) {
        bins = Int(value)
        //self.needsDisplay = true
        self.display()                  // v0.73
    }

    override var isOpaque: Bool {
        return true
    }

    //  zero if not locked
    @objc(setOffset:)
    func setOffset(_ index: Int32) {
        if index < 0 { return }

        if index == 0 && locked {
            locked = false
            self.needsDisplay = true
            return
        }
        if index != Int32(offset) && index != 0 {
            offset = Int(index)
            locked = true
            self.display()
            return
        }
    }

    //  Used by DominoEX which does not need a lock indication
    @objc(setAbsoluteOffset:)
    func setAbsoluteOffset(_ index: Int32) {
        if index < 0 { return }

        if index != Int32(offset) {
            offset = Int(index)
            locked = true
            self.display()
            return
        }
    }

    @objc func clear() {
        locked = false
        offset = 5 * 16
        self.needsDisplay = true
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.set()
        background.fill()

        let line = NSBezierPath()
        line.lineWidth = 1
        var p = CGFloat(offset) - 8.5           // tick marks between bins
        for _ in 0..<(bins + 1) {
            line.move(to: NSPoint(x: p, y: 1))
            line.line(to: NSPoint(x: p, y: CGFloat(height) - 1))
            p += 16.0
        }
        color.set()
        line.stroke()
    }
}
