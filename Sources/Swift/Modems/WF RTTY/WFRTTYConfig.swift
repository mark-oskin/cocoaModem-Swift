//
//  WFRTTYConfig.swift
//  cocoaModem
//
//  Created by Kok Chen on Jan 11 06.
//  Swift port of WFRTTYConfig.m.  WFRTTYConfig is a subclass of RTTYConfig (now
//  Swift) and is itself the base of CWConfig and SITORConfig (both in this
//  batch).  Its instance variables become EXACT-named stored properties so the
//  subclasses reference them by name (vfoOffsetField, channel).
//

import Cocoa

//  Convert an NSString* field of the (bridged) RTTYConfigSet C struct into a String
private func cmKey(_ u: Unmanaged<NSString>?) -> String? {
    guard let u = u else { return nil }
    return u.takeUnretainedValue() as String
}

//  guarded Float -> Int32 (mirror DisplayColor.cInt)
private func cmClampInt(_ x: Float) -> Int32 {
    if !x.isFinite { return 0 }
    let c = min(max(x, -2.0e9), 2.0e9)
    return Int32(c)
}

@objc(WFRTTYConfig)
class WFRTTYConfig: RTTYConfig {

    @IBOutlet var vfoOffsetField: NSTextField!
    internal var channel: Int32 = 0

    @objc(awakeFromModem:rttyRxControl:txConfig:)
    override func awakeFromModem(_ set: UnsafeMutablePointer<RTTYConfigSet>, rttyRxControl control: AnyObject?, txConfig inTxConfig: RTTYTxConfig?) {
        super.awakeFromModem(set, rttyRxControl: control, txConfig: inTxConfig)
        setInterface(vfoOffsetField, to: #selector(vfoOffsetChanged))
    }

    //  data arrived from sound source
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        if overrun?.`try`() == true {
            if interfaceVisible {
                if (isActiveButton && !isTransmit) || (modemSource?.fileRunning() ?? false) {
                    if let src = pipe.stream(), let dst = self.stream() { dst.pointee = src.pointee }
                    exportData()
                    (vuMeter as? VUMeter)?.importData(pipe)
                }
                if configOpen, oscilloscope != nil {
                    (oscilloscope as? Oscilloscope)?.addData(pipe.stream(), isBaudot: false, timebase: 1)
                }
            }
            overrun?.unlock()
        }
    }

    @objc(setChannel:)
    func setChannel(_ n: Int32) {
        channel = n
    }

    @objc func vfoOffsetChanged() {
        (modemRxControl as? RTTYRxControl)?.setWaterfallOffset(vfoOffsetField?.floatValue ?? 0)
    }

    @objc(setupDefaultPreferences:rttyRxControl:)
    override func setupDefaultPreferences(_ pref: Preferences, rttyRxControl control: AnyObject?) {
        super.setupDefaultPreferences(pref, rttyRxControl: control)
        if let k = cmKey(configSet.vfoOffset) { pref.setFloat(0.0, forKey: k) }
    }

    @objc(updateFromPlist:rttyRxControl:)
    @discardableResult
    override func updateFromPlist(_ pref: Preferences, rttyRxControl control: AnyObject?) -> Bool {
        _ = super.updateFromPlist(pref, rttyRxControl: control)
        if let k = cmKey(configSet.vfoOffset) {
            vfoOffsetField?.intValue = cmClampInt(pref.floatValue(forKey: k))
        }
        vfoOffsetChanged()
        return true
    }

    @objc(retrieveForPlist:rttyRxControl:)
    override func retrieveForPlist(_ pref: Preferences, rttyRxControl control: AnyObject?) {
        super.retrieveForPlist(pref, rttyRxControl: control)
        if let k = cmKey(configSet.vfoOffset) { pref.setFloat(vfoOffsetField?.floatValue ?? 0, forKey: k) }
    }
}
