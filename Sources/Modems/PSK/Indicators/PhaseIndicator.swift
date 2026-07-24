//
//  PhaseIndicator.swift
//  cocoaModem
//
//  Created by Kok Chen on Tue Sep 07 2004.
//  Swift port of PhaseIndicator.m.
//

import Cocoa

@objc(PhaseIndicator)
class PhaseIndicator: NSView {

    //  The ObjC original cached the view bounds in an ivar named "bounds"
    //  (shadowing NSView.bounds); renamed here to avoid clobbering the
    //  inherited property.
    private var viewBounds: NSRect = .zero
    private var width: Float = 0
    private var height: Float = 0
    private var xpos: Int = -1
    private var yellow: NSColor!
    private var black: NSColor!

    override var isOpaque: Bool { return true }

    override func awakeFromNib() {
        viewBounds = self.bounds
        let bsize = viewBounds.size
        width = Float(bsize.width)
        height = Float(bsize.height)
        xpos = -1
        yellow = NSColor(deviceRed: 0.95, green: 0.95, blue: 0.0, alpha: 1.0)
        black = NSColor(deviceRed: 0.0, green: 0.0, blue: 0.1, alpha: 1.0)
    }

    override func draw(_ rect: NSRect) {
        black.set()
        var path = NSBezierPath(rect: viewBounds)
        path.fill()

        if xpos > 0 {
            yellow.set()
            path = NSBezierPath()
            path.lineWidth = 1.5
            path.move(to: NSMakePoint(CGFloat(xpos), 0))
            path.line(to: NSMakePoint(CGFloat(xpos), CGFloat(height)))
            path.stroke()
        }
        super.draw(rect)
    }

    @objc func displayInMainThread() {
        //  [ self setNeedsDisplay:YES ] ;
        self.display()                      //  v0.73
    }

    //  radian is angle between -pi/2 to +pi/2
    @objc(newPhase:)
    func newPhase(_ radian: Float) {
        //  The ObjC guard was "radian < -1.5708 || radian > 1.5708"; a NaN
        //  falls through both comparisons in C and would trap Int(NaN) here,
        //  so use the affirmative in-range test which also rejects NaN.
        if !(radian >= -1.5708 && radian <= 1.5708) { return }

        let previous = xpos
        xpos = Int((radian + 1.5708) / 3.14145926 * width + 0.5)
        if xpos != previous {
            perform(#selector(displayInMainThread), on: Thread.main, with: nil, waitUntilDone: false)
        }
    }

    @objc func clear() {
        xpos = -1
        perform(#selector(displayInMainThread), on: Thread.main, with: nil, waitUntilDone: false)
    }
}
