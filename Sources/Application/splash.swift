//
//  splash.swift
//  cocoaModem
//
//  Swift port of splash.m (Kok Chen, Thu Jun 24 2004).
//

import Cocoa

@objc(splash)
class splash: NSObject {

    //  outlets set by Splash.nib (KVC)
    @objc var splashScreen: NSWindow!
    @objc var splashMsg: NSTextField!

    private var active = false
    //  keeps the nib top level objects alive (the old +loadNibNamed:owner: retained them)
    private var nibTopLevelObjects: NSArray?

    override init() {
        super.init()
        var topLevelObjects: NSArray?
        active = Bundle.main.loadNibNamed("Splash", owner: self, topLevelObjects: &topLevelObjects)
        nibTopLevelObjects = topLevelObjects
    }

    @objc func positionWindow() {
        if active {
            splashScreen.center()
            splashScreen.orderFront(self)
            splashScreen.level = .floating
        }
    }

    @objc(showMessage:) func showMessage(_ msg: String?) {
        if active {
            splashMsg.stringValue = msg ?? ""
            splashScreen.display()
        }
    }

    @objc func remove() {
        if active {
            //  the original orderBack: was called while the window was still at
            //  .floating level, so it only reordered among other floating-level
            //  windows and never actually dropped behind the (.normal-level) main
            //  window; orderOut: hides it outright regardless of level.
            splashScreen.orderOut(self)
            splashScreen.level = .normal
            //  the MRC code released the window here; drop our strong references instead
            splashScreen = nil
            splashMsg = nil
            nibTopLevelObjects = nil
        }
        active = false
    }
}
