//
//  About.swift
//  cocoaModem
//
//  Created by Kok Chen on Wed May 12 2004.
//  Swift port of About.m.
//

import Cocoa

@objc(About)
class About: NSObject {

    //  outlet set by About.nib (KVC)
    @objc var window: NSWindow!

    //  keeps the nib top level objects alive (the old +loadNibNamed:owner: retained them)
    private var nibTopLevelObjects: NSArray?

    @objc func initFromNib() -> About {
        var topLevelObjects: NSArray?
        Bundle.main.loadNibNamed("About", owner: self, topLevelObjects: &topLevelObjects)
        nibTopLevelObjects = topLevelObjects
        return self
    }

    @objc func showPanel() {
        if let window = window {
            window.center()
            window.orderFront(nil)
        }
    }
}
