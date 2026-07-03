//
//  FAXConfig.swift
//  cocoaModem
//
//  Created by Kok Chen on Mar 6 2006.
//  Swift port of FAXConfig.m.  FAXConfig is the nib-loaded HF-FAX configuration
//  panel; it remains a subclass of ModemConfig (now Swift).  The FAX modem
//  (still Objective-C, in the bridging header), its FAXDisplay (Swift), the
//  sound source and the forward-declared oscilloscope / VU meter instruments
//  are reached either through their Swift types or through informal @objc
//  protocols (the AMConfig / PSKConfig pattern).
//

import Cocoa

//  --- Plist keys (defined byte-for-byte in Plist.h) ---
private let kFAXActive       = "FAX Active"
private let kFAXInputDevice  = "FAX Input Device"
private let kFAXPPM          = "FAX clock ppm"
private let kFAXFolder       = "FAX Folder"
private let kFAXDeviation    = "FAX Deviation"
private let kAutoConnect     = "Device AutoConnect"
private let kFastPlayback    = "Fast file playback"

private let LEFTCHANNEL: Int32 = 0

@objc(FAXConfig)
class FAXConfig: ModemConfig {

    @IBOutlet var sidebandMenu: NSPopUpButton!
    @IBOutlet var vfoOffset: NSTextField!
    @IBOutlet var deviationCheckbox: NSButton!

    //  sound interface
    private var soundFileRunning: Bool = false

    //  the FAX modem's (Swift) display, reached through the informal protocol
    private var faxDisplay: FAXDisplay? {
        (modemObj as? FAX)?.faxView() as? FAXDisplay
    }

    //  HF-FAX Config

    @objc(awakeFromModem:)
    func awakeFromModem(_ modem: FAX) {
        soundFileRunning = false
        vuMeter = modem.vuMeter

        super.initializeActions()

        (vuMeter as? VUMeter)?.setup()
        fastFileSpeed = 10
        setupModemSource(kFAXInputDevice, channel: LEFTCHANNEL)

        setInterface(deviationCheckbox, to: #selector(deviationChanged))

        //  delegate to trap config panel closure
        window?.delegate = self

        //  start sampling later in an NSTimer driven -checkActive
        modemSource.enableInput(true)
    }

    //  v0.73
    @objc func deviationChanged() {
        faxDisplay?.setDeviation((deviationCheckbox?.state == .on) ? 1 : 0)
    }

    //  data arrived from sound source
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        if ((isActiveButton && !isTransmit) || modemSource.fileRunning()) && interfaceVisible {
            if let src = pipe.stream() { data.pointee = src.pointee }
            exportData()
            (vuMeter as? VUMeter)?.importData(pipe)
        }
        if configOpen, let osc = oscilloscope as? Oscilloscope {
            osc.addData(pipe.stream(), isBaudot: false, timebase: 1)
        }
    }

    //  0 - LSB
    //  1 - USB
    @objc(setSideband:)
    func setSideband(_ index: Int32) {
    }

    //  preferences maintainence, called from Hellschreiber.m
    //  setup default preferences (keys are found in Plist.h)
    @objc(setupDefaultPreferences:)
    func setupDefaultPreferences(_ pref: Preferences) {
        pref.setInt(0, forKey: kFAXActive)
        pref.setInt(0, forKey: kFAXDeviation)          //  v0.73
        pref.setInt(1, forKey: kFastPlayback)
        pref.setInt(0, forKey: kFAXPPM)
        pref.setString("", forKey: kFAXFolder)

        modemSource.setupDefaultPreferences(pref)
    }

    //  called from FAX.m
    //  update all parameters from the plist (called after fetchPlist)
    @objc(updateFromPlist:)
    func updateFromPlist(_ pref: Preferences) -> Bool {
        //  set up active button states and set the button states
        //  later, a Timer would activate to obey these buttons
        activeButton?.state = (pref.intValue(forKey: kFAXActive) == 1) ? .on : .off
        let faxView = faxDisplay
        faxView?.setPPM(Float(pref.intValue(forKey: kFAXPPM)))
        faxView?.setFolder(pref.stringValue(forKey: kFAXFolder) ?? "")

        //  now reset active states if autoconnect is off
        if pref.intValue(forKey: kAutoConnect) == 0 { activeButton?.state = .off }

        if !modemSource.updateFromPlist(pref) && (activeButton?.state == .on) {
            activeButton?.state = .off
            //  toggle input attenuator
            let selStr = "HF Fax: " + NSLocalizedString("Select Sound Card", comment: "")
            _ = Messages.alert(withMessageText: selStr, informativeText: NSLocalizedString("Device removed", comment: ""))
        }

        modemSource.setDeviceLevel((modemObj as? FAX)?.inputAttenuatorOutlet as? NSSlider)

        (modemObj as? FAX)?.setWaterfallOffset(0.0, sideband: 1)   //  this updates the labels of the waterfall

        var state = pref.intValue(forKey: kFastPlayback)
        fileSpeedCheckbox?.state = (state != 0) ? .on : .off

        state = pref.intValue(forKey: kFAXDeviation)
        deviationCheckbox?.state = (state != 0) ? .on : .off
        faxView?.setDeviation(state)

        //  always fast file speed
        fileSpeedCheckbox?.state = .on
        updateFileSpeed()

        return true
    }

    //  update preference dictionary for writing back into the plist file
    @objc(retrieveForPlist:)
    func retrieveForPlist(_ pref: Preferences) {
        //  FAX input prefs
        modemSource.retrieveForPlist(pref)
        pref.setInt((fileSpeedCheckbox?.state == .on) ? 1 : 0, forKey: kFastPlayback)

        let ppmF = faxDisplay?.ppm() ?? 0
        let ppm: Int32 = ppmF.isFinite ? Int32(ppmF) : 0
        pref.setInt(ppm, forKey: kFAXPPM)
        pref.setString(faxDisplay?.folder(), forKey: kFAXFolder)

        //  active button states and local flag
        pref.setInt((activeButton?.state == .on) ? 1 : 0, forKey: kFAXActive)

        pref.setInt((deviationCheckbox?.state == .on) ? 1 : 0, forKey: kFAXDeviation)
    }

    //  called from ModemSource when file starts
    @objc(soundFileStarting:)
    override func soundFileStarting(_ filename: String!) {
        soundFileRunning = true
    }

    //  called from ModemSource when file stopped
    @objc func soundFileStopped() {
        soundFileRunning = false
    }

    //  ------------------------ Delegates -----------------------
    //  delegate for Config panel
    @objc override func windowShouldClose(_ sender: NSWindow) -> Bool {
        configOpen = false
        updateInputSamplingState()

        return true
    }
}
