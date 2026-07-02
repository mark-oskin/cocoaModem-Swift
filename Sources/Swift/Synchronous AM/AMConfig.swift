//
//  AMConfig.swift
//  cocoaModem
//
//  Created by Kok Chen on Jan 17 2007.
//  Swift port of AMConfig.m.  AMConfig remains a subclass of the Objective-C
//  class ModemConfig (ModemConfig stays Objective-C; its header is in the
//  bridging header).  This is a nib-loaded config panel.
//

import Cocoa

//  --- Plist keys (defined in Plist.h, not in the bridging header) ---
private let kSynchAMActive      = "AM Active"
private let kSynchAMInputDevice = "AM Input Device"
private let kAutoConnect        = "Device AutoConnect"
private let kFastPlayback       = "Fast file playback"

private let LEFTCHANNEL: Int32 = 0

//  Informal access to still-Objective-C collaborators that are not in the
//  bridging header (resolved dynamically through AnyObject message dispatch,
//  the QSO.swift pattern).  ModemSource's plist selectors collide with
//  AMConfig's own selectors, so they are given distinct Swift names bound to
//  the exact Objective-C selectors.
@objc private protocol AMSourceInformal {
    @objc func enableInput(_ state: DarwinBoolean)
    @objc func fileRunning() -> DarwinBoolean
    @objc func setDeviceLevel(_ slider: NSSlider?)
    @objc(updateFromPlist:) func sourceUpdateFromPlist(_ pref: Preferences?) -> DarwinBoolean
    @objc(retrieveForPlist:) func sourceRetrieveForPlist(_ pref: Preferences?)
    @objc(setupDefaultPreferences:) func sourceSetupDefaultPreferences(_ pref: Preferences?)
}
@objc private protocol AMAuralMonitorInformal {
    @objc func addLeft(_ left: UnsafeMutablePointer<Float>?, right: UnsafeMutablePointer<Float>?, samples: Int32, client: AnyObject?)
    @objc func addClient(_ client: AnyObject?)
    @objc func removeClient(_ client: AnyObject?)
    @objc func showWindow()
}
@objc private protocol AMVUMeterInformal {
    @objc func setup()
}
@objc private protocol AMOscilloscopeInformal {
    @objc func addData(_ stream: UnsafeMutablePointer<CMDataStream>?, isBaudot: DarwinBoolean, timebase: Int32)
}

@objc(AMConfig)
class AMConfig: ModemConfig, NSWindowDelegate {

    //  sound interface
    private var outputRunning = false
    private var soundFileRunning = false
    private var outbufLock: NSLock?
    private var outputBuffer = [Float](repeating: 0, count: 1024)

    //  v0.78
    private var auralMonitor: AnyObject?

    // --- KVC accessors for inherited (Objective-C) ModemConfig ivars, which
    //     are not visible to Swift subclasses directly. ---
    private var interfaceVisibleFlag: Bool {
        get { (value(forKey: "interfaceVisible") as? NSNumber)?.boolValue ?? false }
        set { setValue(newValue, forKey: "interfaceVisible") }
    }
    private var configOpenFlag: Bool {
        get { (value(forKey: "configOpen") as? NSNumber)?.boolValue ?? false }
        set { setValue(newValue, forKey: "configOpen") }
    }
    private var isActiveButtonFlag: Bool { (value(forKey: "isActiveButton") as? NSNumber)?.boolValue ?? false }
    private var isTransmitFlag: Bool { (value(forKey: "isTransmit") as? NSNumber)?.boolValue ?? false }
    private var windowObject: NSWindow? { value(forKey: "window") as? NSWindow }
    private var activeButtonObject: NSButton? { value(forKey: "activeButton") as? NSButton }
    private var fileSpeedCheckboxObject: NSButton? { value(forKey: "fileSpeedCheckbox") as? NSButton }
    private var oscilloscopeObject: AnyObject? { value(forKey: "oscilloscope") as AnyObject? }
    private var vuMeterObject: AnyObject? { value(forKey: "vuMeter") as AnyObject? }
    //  inherited ModemConfig ivar modemSource (the -inputSource accessor returns
    //  a forward-declared ModemSource* that Swift cannot represent, so use KVC).
    private var modemSourceObject: AnyObject? { value(forKey: "modemSource") as AnyObject? }
    private var synchAM: SynchAM? { modemObject() as? SynchAM }

    //  Synch-AM Config

    @objc(awakeFromModem:)
    func awakeFromModem(_ modem: SynchAM) {
        soundFileRunning = false
        outputRunning = false
        outbufLock = NSLock()
        for i in 0..<1024 { outputBuffer[i] = 0.0 }
        let vu = modem.vuMeter
        setValue(vu, forKey: "vuMeter")

        super.initializeActions()
        (vu as AnyObject?)?.setup?()
        setValue(10, forKey: "fastFileSpeed")

        setupModemSource(kSynchAMInputDevice, channel: LEFTCHANNEL)

        //  delegate to trap config panel closure
        windowObject?.delegate = self

        //  start sampling later in an NSTimer driven -checkActive
        modemSourceObject?.enableInput?(true)
    }

    @objc(setOutputScale:)
    override func setOutputScale(_ v: Float) {
        synchAM?.setOutputScale(v)
    }

    //  data arrived from sound source
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        let active = isActiveButtonFlag && !isTransmitFlag
        let fileRun = (modemSourceObject?.fileRunning?())?.boolValue ?? false
        if (active || fileRun) && interfaceVisibleFlag {
            if let src = pipe.stream(), let dst = self.stream() {
                dst.pointee = src.pointee
            }
            exportData()
            (vuMeterObject as? CMPipe)?.importData(pipe)
        }
        if configOpenFlag, let osc = oscilloscopeObject {
            osc.addData?(pipe.stream(), isBaudot: false, timebase: 1)
        }
    }

    @objc(needData:samples:)
    override func needData(_ outbuf: UnsafeMutablePointer<Float>!, samples n: Int32) -> Int32 {
        NSLog("AMConfig: needData should not be called")
        return 1
    }

    @objc(setOutput:samples:)
    func setOutput(_ array: UnsafeMutablePointer<Float>?, samples n: Int32) {
        if n != 512 {
            auralMonitor?.addLeft?(nil, right: nil, samples: 512, client: self)
            return
        }

        outbufLock?.lock()
        auralMonitor?.addLeft?(array, right: array, samples: 512, client: self)
        outbufLock?.unlock()
    }

    @objc(setSideband:)
    func setSideband(_ index: Int32) {
        //  not used
    }

    @objc func updateAuralMonitorState() {
        if auralMonitor == nil {
            auralMonitor = (NSApp.delegate as? AppDelegate)?.auralMonitor()
            if auralMonitor == nil { return }
        }

        if interfaceVisibleFlag {
            if outputRunning { return }
            outputRunning = true
            auralMonitor?.addClient?(self)
        } else {
            if !outputRunning { return }
            outputRunning = false
            auralMonitor?.removeClient?(self)
        }
    }

    @objc(openAuralMonitor:)
    func openAuralMonitor(_ sender: Any?) {
        auralMonitor?.showWindow?()
    }

    @objc(updateVisibleState:)
    override func updateVisibleState(_ state: Bool) {
        interfaceVisibleFlag = state
        //  now check if we need to turn on/off actual sampling
        updateInputSamplingState()
        updateAuralMonitorState()
    }

    @objc(setupModemDest:controlView:attenuatorView:)
    override func setupModemDest(_ outputDevice: String!, controlView: NSView!, attenuatorView levelView: NSView!) {
    }

    //  preferences maintainence, called from Hellschreiber.m
    //  setup default preferences (keys are found in Plist.h)
    @objc(setupDefaultPreferences:)
    func setupDefaultPreferences(_ pref: Preferences!) {
        modemSourceObject?.sourceSetupDefaultPreferences?(pref)
    }

    //  called from SyncAM.m
    //  update all parameters from the plist (called after fetchPlist)
    @objc(updateFromPlist:)
    func updateFromPlist(_ pref: Preferences!) -> Bool {
        //  set up active button states and set the button states
        //  later, a Timer would activate to obey these buttons
        activeButtonObject?.state = (pref.intValue(forKey: kSynchAMActive) == 1) ? .on : .off

        //  now reset active states if autoconnect is off
        if pref.intValue(forKey: kAutoConnect) == 0 {
            activeButtonObject?.state = .off
        }

        let source = modemSourceObject
        let sourceOK = (source?.sourceUpdateFromPlist?(pref))?.boolValue ?? false
        if !sourceOK && (activeButtonObject?.state == .on) {
            activeButtonObject?.state = .off
            let selStr = "Synch AM: " + NSLocalizedString("Select Sound Card", comment: "")
            _ = Messages.alert(withMessageText: selStr, informativeText: NSLocalizedString("Device removed", comment: ""))
        }
        source?.setDeviceLevel?(synchAM?.inputAttenuator(self))

        synchAM?.setWaterfallOffset(0.0, sideband: 1)     //  this updates the labels of the waterfall

        let state = pref.intValue(forKey: kFastPlayback)
        fileSpeedCheckboxObject?.state = (state != 0) ? .on : .off

        //  always fast file speed
        fileSpeedCheckboxObject?.state = .on
        updateFileSpeed()

        return true
    }

    //  update preference dictionary for writing back into the plist file
    @objc(retrieveForPlist:)
    func retrieveForPlist(_ pref: Preferences!) {
        //  Sync AM input prefs
        modemSourceObject?.sourceRetrieveForPlist?(pref)
        pref.setInt((fileSpeedCheckboxObject?.state == .on) ? 1 : 0, forKey: kFastPlayback)

        //  active button states and local flag
        pref.setInt((activeButtonObject?.state == .on) ? 1 : 0, forKey: kSynchAMActive)
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

    override func applicationTerminating() {
        //  sound card termination now handled by AudioManager.m
    }

    //  ------------------------ Delegates -----------------------
    //  delegate for Config panel
    @objc func windowShouldClose(_ sender: NSWindow) -> Bool {
        configOpenFlag = false
        updateInputSamplingState()

        return true
    }
}
