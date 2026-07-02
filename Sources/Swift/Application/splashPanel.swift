//
//  splashPanel.swift
//  cocoaModem 2.0
//
//  Swift port of splashPanel.m (Kok Chen, 11/5/07).
//

import Cocoa

@objc(splashPanel)
class splashPanel: NSWindow {

    //  instantiated by name from Splash.nib (NSWindowTemplate); always creates a
    //  borderless, buffered, deferred window with a white background and a shadow
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing bufferingType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: .borderless, backing: .buffered, defer: true)
        backgroundColor = .white
        level = .normal
        hasShadow = true
    }
}
