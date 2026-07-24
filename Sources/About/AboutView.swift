//
//  AboutView.swift
//  cocoaModem
//
//  Created by Kok Chen on Mon May 17 2004.
//  Swift port of AboutView.m.
//

import Cocoa

@objc(AboutView)
class AboutView: NSView {

    //  outlet set by About.nib (KVC)
    @objc var versionString: NSTextField!

    override func draw(_ rect: NSRect) {
        if lockFocusIfCanDraw() {
            NSColor.white.set()
            let background = NSBezierPath(rect: bounds)
            background.fill()
            unlockFocus()
        }

        super.draw(rect)

        if lockFocusIfCanDraw() {
            //  set version string in About panel
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                versionString?.stringValue = "Version \(version)"
            }
            unlockFocus()
        }
    }
}
