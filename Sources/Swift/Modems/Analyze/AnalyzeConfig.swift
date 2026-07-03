//
//  AnalyzeConfig.swift
//  cocoaModem
//
//  Created by Kok Chen on 2/22/05.
//  Swift port of AnalyzeConfig.m.  AnalyzeConfig is a subclass of RTTYConfig
//  (now Swift).  Its instance variables become EXACT-named stored properties.
//  The error-accounting entry points (accumBits:, accumErrorBits:, frameError:,
//  setSyncState:) are called from the already-converted MultiStereoATC.swift.
//

import Cocoa

@objc(AnalyzeConfig)
class AnalyzeConfig: RTTYConfig {

    @IBOutlet var fileRepeat: AnyObject!
    @IBOutlet var fileName: NSTextField!
    @IBOutlet var bitErrorField: NSTextField!
    @IBOutlet var characterErrorField: NSTextField!
    @IBOutlet var framingErrorField: NSTextField!
    @IBOutlet var characterCountField: NSTextField!

    @IBOutlet var sync: NSTextField!

    //  plot
    @IBOutlet var scope: AnalyzeScope!
    @IBOutlet var scopePlotMode: NSMatrix!
    @IBOutlet var scopeTriggerMode: NSPopUpButton!
    @IBOutlet var scopeTriggerOnError: NSPopUpButton!

    internal var plotMode: Int32 = 0
    internal var triggerMode: Int32 = 0
    internal var triggerOnError: Bool = false
    internal var hasError: Bool = false
    internal var hasFramingError: Bool = false

    internal var bitCount: Int32 = 0
    internal var bitErrorCount: Int32 = 0
    internal var characterCount: Int32 = 0
    internal var characterErrorCount: Int32 = 0
    internal var framingErrorCount: Int32 = 0

    @objc(awakeFromModem:rttyRxControl:)
    func awakeFromModem(_ set: UnsafeMutablePointer<RTTYConfigSet>, rttyRxControl control: AnyObject?) {
        super.awakeFromModem(set, rttyRxControl: control, txConfig: nil)
        plotMode = Int32((scopePlotMode?.selectedRow ?? 0) + (scopePlotMode?.selectedColumn ?? 0) * 4)
        triggerMode = Int32(scopeTriggerMode?.indexOfSelectedItem ?? 0)
        triggerOnError = (scopeTriggerOnError?.indexOfSelectedItem ?? 0) != 0
        hasError = false
        hasFramingError = false
    }

    @objc(updateColorsFromPreferences:)
    override func updateColorsFromPreferences(_ pref: Preferences!) {
        let color = NSColor(calibratedRed: 1, green: 0.8, blue: 0, alpha: 1)
        let sent = color
        let bg = NSColor.black
        let plot = NSColor(calibratedRed: 0, green: 1.0, blue: 0, alpha: 1)
        //  set colors
        textColor?.color = color
        transmitTextColor?.color = sent
        backgroundColor?.color = bg
        plotColor?.color = plot
        modemObj.setTextColor(color, sentColor: sent, backgroundColor: bg, plotColor: plot,
                              forReceiver: (modemRxControl as? RTTYRxControl)?.uniqueID_() ?? 0)
    }

    @objc(retrieveActualColorPreferences:rttyRxControl:)
    func retrieveActualColorPreferences(_ pref: Preferences?, rttyRxControl control: AnyObject?) {
        //  do nothing since analyze has no preferences
    }

    override func soundFileStarting(_ str: String!) {
        super.soundFileStarting(str)
        fileName?.stringValue = (str as NSString?)?.lastPathComponent ?? ""
        bitCount = 0
        bitErrorCount = 0
        characterCount = 0
        characterErrorCount = 0
        framingErrorCount = 0
        bitErrorField?.stringValue = ""
        characterErrorField?.stringValue = ""
        framingErrorField?.stringValue = ""
    }

    //  new character arrived
    @objc(accumBits:)
    func accumBits(_ bits: Int32) {
        //  clear error state for this character
        hasFramingError = false
        hasError = false

        bitCount += bits
        characterCount += 1
        characterCountField?.intValue = characterCount

        bitErrorField?.stringValue = String(format: "%5.2e", Double(bitErrorCount) * 1.0 / Double(bitCount))
        characterErrorField?.stringValue = String(format: "%5.2e", Double(characterErrorCount) * 1.0 / Double(characterCount))
        framingErrorField?.stringValue = String(format: "%5.2e", Double(framingErrorCount) * 1.0 / Double(characterCount))
    }

    @objc(frameError:)
    func frameError(_ position: Int32) {
        hasFramingError = true
        framingErrorCount += 1
        characterErrorCount += 1
        characterCount += 1
        characterErrorField?.stringValue = String(format: "%5.2e", Double(characterErrorCount) * 1.0 / Double(characterCount))
        framingErrorField?.stringValue = String(format: "%5.2e", Double(framingErrorCount) * 1.0 / Double(characterCount))
    }

    @objc(accumErrorBits:)
    func accumErrorBits(_ bits: Int32) {
        hasError = (bits != 0)
        hasFramingError = false

        bitErrorCount += bits
        characterErrorCount += 1

        bitErrorField?.stringValue = String(format: "%5.2e", Double(bitErrorCount) * 1.0 / Double(bitCount))
        characterErrorField?.stringValue = String(format: "%5.2e", Double(characterErrorCount) * 1.0 / Double(characterCount))
        framingErrorField?.stringValue = String(format: "%5.2e", Double(framingErrorCount) * 1.0 / Double(characterCount))
    }

    //  data arrived from sound source (original body disabled - see AnalyzeConfig.m @@@@)
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
    }

    @objc(setSyncState:)
    func setSyncState(_ state: Int32) {
        switch state {
        case 1:
            sync?.backgroundColor = NSColor.yellow
        case 2:
            sync?.backgroundColor = NSColor.green
        default:
            sync?.backgroundColor = NSColor.red
        }
    }

    @objc func scopeModeChanged(_ sender: Any?) {
        plotMode = Int32((scopePlotMode?.selectedRow ?? 0) + (scopePlotMode?.selectedColumn ?? 0) * 4)
        if let scope = scope { scope.updatePlot(plotMode) }
    }

    @objc func scopeTriggerChanged(_ sender: Any?) {
        triggerMode = Int32(scopeTriggerMode?.indexOfSelectedItem ?? 0)
        triggerOnError = (scopeTriggerOnError?.indexOfSelectedItem ?? 0) != 0
    }

    @objc func scopeTriggered(_ sender: Any?) {
        hasError = false        // clear error conditions
        modemSource?.nextSoundFrame()
    }
}
