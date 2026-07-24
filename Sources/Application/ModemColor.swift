//
//  ModemColor.swift
//  cocoaModem 2.0
//
//  Swift port of ModemColor.m (Kok Chen, 11/27/05).
//

import Cocoa

@objc(ModemColor)
class ModemColor: NSColorWell {

    //  the original ivar was a non-retained (MRC assign) id
    @objc weak var delegate: AnyObject?

    override func awakeFromNib() {
        super.awakeFromNib()
        delegate = nil
    }

    //  prototype for delegate
    @objc(colorChanged:) func colorChanged(_ client: NSColorWell?) {
    }

    override var color: NSColor {
        get {
            return super.color
        }
        set {
            super.color = newValue.usingColorSpace(.deviceRGB) ?? newValue
            if let delegate = delegate, delegate.responds(to: #selector(colorChanged(_:))) {
                _ = delegate.perform(#selector(colorChanged(_:)), with: self)
            }
        }
    }
}
