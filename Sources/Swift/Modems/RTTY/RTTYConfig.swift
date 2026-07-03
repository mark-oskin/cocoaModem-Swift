//
//  RTTYConfig.swift
//  cocoaModem
//
//  Created by Kok Chen on Mon May 17 2004.
//  Swift port of RTTYConfig.m.  RTTYConfig is the base of WFRTTYConfig,
//  DualRTTYConfig and AnalyzeConfig (all in this batch); it stays a subclass of
//  ModemConfig (now also Swift).  Its instance variables become EXACT-named
//  stored properties so the subclasses reference them by name (overrun,
//  modemRxControl, configSet, txConfig, fsk, prefMatrix, ...).
//

import Cocoa

//  FSKMenu.h #define titles (that header is not bridged)
private let kRTTYConfigOOKMenuTitle          = "OOK"
private let kRTTYConfigDigiKeyerOOKMenuTitle = "OOK: digiKEYER"

//  --- informal @objc protocols for still-Objective-C collaborators not in the
//      bridging header (the AMConfig / QSO.swift pattern) ---
@objc private protocol RTTYRxControlBridge {
    @objc func vuMeter() -> AnyObject?
    @objc(setTuningIndicatorState:) func setTuningIndicatorState(_ state: DarwinBoolean)
    @objc(turnOnMarkers:) func turnOnMarkers(_ state: DarwinBoolean)
    @objc func uniqueID() -> Int32
    @objc func inputAttenuator() -> NSSlider?
    @objc(updateFromPlist:config:) func rxUpdateFromPlist(_ pref: Preferences?, config: AnyObject?)
    @objc(retrieveForPlist:config:) func rxRetrieveForPlist(_ pref: Preferences?, config: AnyObject?)
    @objc(setupDefaultPreferences:config:) func rxSetupDefaultPreferences(_ pref: Preferences?, config: AnyObject?)
}
@objc private protocol RTTYVUMeterBridge {
    @objc func setup()
    @objc(importData:) func vuImportData(_ pipe: CMPipe?)
}
@objc private protocol RTTYOscilloscopeBridge {
    @objc(setTonePairMarker:) func setTonePairMarker(_ tonepair: UnsafePointer<CMTonePair>)
    @objc(setDisplayStyle:plotColor:) func setDisplayStyle(_ style: Int32, plotColor: NSColor?)
    @objc(addData:isBaudot:timebase:) func addData(_ stream: UnsafeMutablePointer<CMDataStream>?, isBaudot: DarwinBoolean, timebase: Int32)
}
@objc private protocol RTTYModemBridge {
    @objc(afskChanged:config:) func afskChanged(_ index: Int32, config: AnyObject?)
    @objc(setRTTYPrefs:channel:) func setRTTYPrefs(_ prefs: NSMatrix?, channel: Int32)
    @objc func isASCIIModem() -> DarwinBoolean
}

//  Convert an NSString* field of the (bridged) RTTYConfigSet C struct into a String
private func cmKey(_ u: Unmanaged<NSString>?) -> String? {
    guard let u = u else { return nil }
    return u.takeUnretainedValue() as String
}

@objc(RTTYConfig)
class RTTYConfig: ModemConfig {

    @IBOutlet var prefMatrix: NSMatrix!             //  NSArray of checkboxes
    @IBOutlet var sidebandMenu: NSPopUpButton!
    @IBOutlet var afskMenu: NSPopUpButton!

    //  modemRxControl is an Objective-C RTTYRxControl* (informal-protocol access)
    var modemRxControl: AnyObject?
    @objc var txConfig: RTTYTxConfig?
    @objc var fsk: FSK?

    var preferredAFSKMenuTitle: String?
    var actualAFSKMenuTitle: String?
    var prefVersion: Int32 = 0
    var overrun: NSLock?

    //  RTTYConfigSet is a C struct; keep it in stable heap storage so the
    //  Objective-C -configSet accessor can hand back a valid pointer.
    private let configSetStorage: UnsafeMutablePointer<RTTYConfigSet> = {
        let p = UnsafeMutablePointer<RTTYConfigSet>.allocate(capacity: 1)
        p.initialize(to: RTTYConfigSet())
        return p
    }()
    var configSet: RTTYConfigSet {
        get { configSetStorage.pointee }
        set { configSetStorage.pointee = newValue }
    }

    deinit {
        configSetStorage.deallocate()
    }

    //  ---- Objective-C accessors ----
    @objc(configSet) func configSetPointer() -> UnsafeMutablePointer<RTTYConfigSet> { return configSetStorage }
    @objc(ook) func ook() -> Int32 {
        let s = afskMenu?.titleOfSelectedItem
        if s == kRTTYConfigOOKMenuTitle || s == kRTTYConfigDigiKeyerOOKMenuTitle { return 1 }     //  v0.87
        return 0
    }

    //  set tone pair for instrumentation
    @objc(setTonePairMarker:)
    func setTonePairMarker(_ tonepair: UnsafePointer<CMTonePair>) {
        (oscilloscope as? Oscilloscope)?.setTonePairMarker(tonepair)
    }

    @objc(txTonePairChanged:)
    func txTonePairChanged(_ control: AnyObject?) {
        txConfig?.setupTones(from: control, lockTone: false)
    }

    @objc(awakeFromModem:rttyRxControl:txConfig:)
    func awakeFromModem(_ set: UnsafeMutablePointer<RTTYConfigSet>, rttyRxControl control: AnyObject?, txConfig inTxConfig: RTTYTxConfig?) {
        modemRxControl = control
        configSet = set.pointee
        txConfig = inTxConfig

        toneMatrix = nil
        transmitButton = nil
        timeout = nil
        vuMeter = (control as? RTTYRxControl)?.vuMeter

        overrun = NSLock()
        initializeActions()

        (vuMeter as? VUMeter)?.setup()
        fastFileSpeed = 4
        setupModemSource(cmKey(configSet.inputDevice), channel: configSet.channel)

        //  delegate to trap config panel closure
        window?.delegate = self
        //  start sampling later in an NSTimer driven -checkActive
        modemSource?.enableInput(true)

        //  v0.48 -- set up FSK interface (v0.83 not for ASCII)
        let isASCII = (modemObj as? RTTYInterface)?.isASCIIModem ?? false
        if !isASCII {
            if let hub = modemObj.application()?.fskHub(), let rtty = modemObj as? RTTY {
                fsk = FSK(hub: hub, menu: afskMenu, modem: rtty)
            }
        }
        //  capture menu changes
        if let afskMenu = afskMenu {
            afskMenu.action = #selector(afskMenuChanged)
            afskMenu.target = self
        }
        setInterface(prefMatrix, to: #selector(prefMatrixChanged))
    }

    //  v0.87
    override func setKeyerMode() {
        if let afskMenu = afskMenu {
            let menuTitle = afskMenu.titleOfSelectedItem
            //  if OOK in digiKeyer, force to FSK Mode, otherwise force keyer to Digital mode if a microKeyer
            if let fsk = fsk, let menuTitle = menuTitle {
                let controlPort = fsk.controlPortForName(menuTitle)
                if controlPort > 0 {
                    let mode = (menuTitle == kRTTYConfigDigiKeyerOOKMenuTitle) ? kMicrohamFSKRouting : kMicrohamDigitalRouting   //  v0.93b
                    fsk.setKeyerMode(mode, controlPort: controlPort)
                    return
                }
            }
        }
        if let txConfig = txConfig {
            //  fsk port not found, use PTT menu instead
            if let ptt = txConfig.pttObject() {
                ptt.setKeyerMode(kMicrohamDigitalRouting)       //  v0.93b
            }
        }
    }

    @objc func afskMenuChanged() {
        //  in case it was not set, set to AFSK
        if (afskMenu?.indexOfSelectedItem ?? -1) < 0 { afskMenu?.selectItem(at: 0) }

        preferredAFSKMenuTitle = afskMenu?.titleOfSelectedItem
        actualAFSKMenuTitle = preferredAFSKMenuTitle
        (modemObj as? RTTYInterface)?.afskChanged(Int32(afskMenu?.indexOfSelectedItem ?? 0), config: self)

        setKeyerMode()
    }

    //  delegate of NSMenu (afskMenu)
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let fsk = fsk { return fsk.validateAfskMenuItem(item) }
        return false
    }

    //  data arrived from sound source
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        if overrun?.`try`() == true {
            //  discard overruns
            if ((isActiveButton && !isTransmit) || (modemSource?.fileRunning() ?? false)) && interfaceVisible {
                if let src = pipe.stream(), let dst = self.stream() { dst.pointee = src.pointee }
                exportData()
                (vuMeter as? VUMeter)?.importData(pipe)
            }
            if configOpen, oscilloscope != nil {
                (oscilloscope as? Oscilloscope)?.addData(pipe.stream(), isBaudot: false, timebase: 1)
            }
            overrun?.unlock()
        }
    }

    //  check active button
    override func updateActiveButtonState() -> Bool {
        _ = super.updateActiveButtonState()
        if let control = modemRxControl as? RTTYRxControl {
            control.setTuningIndicatorState(isActiveButton)
            control.turnOnMarkers(isActiveButton)
        }
        return isActiveButton
    }

    /* local */
    private func setupDefaultColorPreferences(_ pref: Preferences) {
        if let k = cmKey(configSet.textColor) { set(k, fromRed: 1.0, green: 0.8, blue: 0.0, into: pref) }
        if let k = cmKey(configSet.backgroundColor) { set(k, fromRed: 0.0, green: 0.0, blue: 0.0, into: pref) }
        if let k = cmKey(configSet.plotColor) { set(k, fromRed: 0.0, green: 1.0, blue: 0.0, into: pref) }
    }

    //  preferences maintainence, called from RTTY.m
    @objc(setupDefaultPreferences:rttyRxControl:)
    func setupDefaultPreferences(_ pref: Preferences, rttyRxControl control: AnyObject?) {
        modemRxControl = control

        pref.setInt(1, forKey: kFastPlayback)
        if let k = cmKey(configSet.active) { pref.setInt(0, forKey: k) }

        preferredAFSKMenuTitle = "AFSK"
        actualAFSKMenuTitle = "AFSK"
        if let k = cmKey(configSet.fskSelection) { pref.setString(preferredAFSKMenuTitle, forKey: k) }

        setupDefaultColorPreferences(pref)
        (control as? RTTYRxControl)?.setupBasicDefaultPreferences(pref, config: self)
        modemSource?.setupDefaultPreferences(pref)

        if let txConfig = txConfig { txConfig.setupDefaultPreferences(pref, rttyRxControl: control) }
    }

    @objc(updateColorsFromPreferences:configSet:)
    func updateColorsFromPreferences(_ pref: Preferences, configSet set: UnsafeMutablePointer<RTTYConfigSet>) {
        let color = getColor(cmKey(set.pointee.textColor) ?? "", from: pref)
        let sent = getColor(cmKey(set.pointee.sentColor) ?? "", from: pref)
        let bg = getColor(cmKey(set.pointee.backgroundColor) ?? "", from: pref)
        let plot = getColor(cmKey(set.pointee.plotColor) ?? "", from: pref)
        //  set colors
        if let color = color { textColor?.color = color }
        if let bg = bg { backgroundColor?.color = bg }
        if let plot = plot { plotColor?.color = plot }
        (oscilloscope as? Oscilloscope)?.setDisplayStyle(0, plotColor: plot)   //  initially spectrum
        modemObj.setTextColor(color, sentColor: sent, backgroundColor: bg, plotColor: plot,
                              forReceiver: (modemRxControl as? RTTYRxControl)?.uniqueID_() ?? 0)
    }

    //  called from RTTY.m
    @objc(updateFromPlist:rttyRxControl:)
    @discardableResult
    func updateFromPlist(_ pref: Preferences, rttyRxControl control: AnyObject?) -> Bool {
        modemRxControl = control

        updateColorsFromPreferences(pref, configSet: configSetStorage)

        if !(modemSource?.updateFromPlist(pref) ?? false) && (activeButton?.state == .on) {
            activeButton?.state = .off
            //  toggle input attenuator
            _ = Messages.alert(withMessageText: NSLocalizedString("RTTY settings needs to be reselected", comment: ""),
                               informativeText: NSLocalizedString("Device removed", comment: ""))
        }

        //  set up active button state
        activeButton?.state = (pref.intValue(forKey: cmKey(configSet.active) ?? "") == 1) ? .on : .off
        //  now reset active states if autoconnect is off
        if pref.intValue(forKey: kAutoConnect) == 0 { activeButton?.state = .off }

        modemSource?.setDeviceLevel((modemRxControl as? RTTYRxControl)?.inputAttenuator)

        //  rtty NSMatrix checkboxes
        if let prefMatrix = prefMatrix {
            let s = pref.stringValue(forKey: cmKey(configSet.prefs) ?? "")
            let count = prefMatrix.numberOfRows
            if let s = s {
                let rttyBytes = [UInt8](s.data(using: .isoLatin1) ?? Data())
                for i in 0..<count {
                    if i >= rttyBytes.count { break }
                    let state = rttyBytes[i]
                    if state == 0 { break }
                    if let b = prefMatrix.cell(atRow: i, column: 0) as? NSButtonCell {
                        b.state = (state == UInt8(ascii: "1")) ? .on : .off
                    }
                }
            }
            (modemObj as? RTTYInterface)?.setRTTYPrefs(prefMatrix, channel: configSet.channel)
        }
        (modemRxControl as? RTTYRxControl)?.updateBasicFromPlist(pref, config: self)
        if let txConfig = txConfig { _ = txConfig.updateFromPlist(pref, rttyRxControl: control) }
        if let fileSpeedCheckbox = fileSpeedCheckbox {
            let state = pref.intValue(forKey: kFastPlayback)
            fileSpeedCheckbox.state = (state != 0) ? .on : .off
            updateFileSpeed()
        }

        if let fskSelection = cmKey(configSet.fskSelection) {
            preferredAFSKMenuTitle = pref.stringValue(forKey: fskSelection)

            if let preferred = preferredAFSKMenuTitle, let fsk = fsk {
                if fsk.checkAvailability(preferred) {
                    actualAFSKMenuTitle = preferred
                } else {
                    actualAFSKMenuTitle = "AFSK"
                    let hdr = String(format: "FSK device '%@' that is use in the %@ Interface is unavailable.",
                                     preferred, modemObj.ident ?? "")
                    _ = Messages.alert(withMessageText: hdr, informativeText: NSLocalizedString("Reselect FSK", comment: ""))
                }
            } else {
                //  should not happen, but just in case...
                preferredAFSKMenuTitle = "AFSK"
                actualAFSKMenuTitle = "AFSK"
            }
            afskMenu?.selectItem(withTitle: actualAFSKMenuTitle ?? "AFSK")
            afskMenuChanged()
        }
        return true
    }

    @objc(retrieveActualColorPreferences:)
    override func retrieveActualColorPreferences(_ pref: Preferences!) {
        if let tc = textColor?.color, let k = cmKey(configSet.textColor) { set(k, fromColor: tc, into: pref) }
        if let bc = backgroundColor?.color, let k = cmKey(configSet.backgroundColor) { set(k, fromColor: bc, into: pref) }
        if let pc = plotColor?.color, let k = cmKey(configSet.plotColor) { set(k, fromColor: pc, into: pref) }
    }

    //  update preference dictionary for writing back into the plist file
    @objc(retrieveForPlist:rttyRxControl:)
    func retrieveForPlist(_ pref: Preferences, rttyRxControl control: AnyObject?) {
        modemRxControl = control
        prefVersion = pref.intValue(forKey: kPrefVersion)

        retrieveActualColorPreferences(pref)
        //  rtty input prefs
        modemSource?.retrieveForPlist(pref)
        if let fileSpeedCheckbox = fileSpeedCheckbox {
            pref.setInt((fileSpeedCheckbox.state == .on) ? 1 : 0, forKey: kFastPlayback)
        }

        if let prefMatrix = prefMatrix {
            let count = prefMatrix.numberOfRows
            var str = [UInt8]()
            for i in 0..<count {
                let b = prefMatrix.cell(atRow: i, column: 0) as? NSButtonCell
                //  for version 3 and earlier Plist, force BELL off
                if prefVersion <= 3 && i == 1 { str.append(UInt8(ascii: "1")) }
                else { str.append((b?.state == .on) ? UInt8(ascii: "1") : UInt8(ascii: "0")) }
            }
            let string = String(bytes: str, encoding: .isoLatin1) ?? ""
            if let k = cmKey(configSet.prefs) {
                pref.setString(string.isEmpty ? "" : string, forKey: k)
            }
        }

        //  active button states and local flag
        if let k = cmKey(configSet.active) {
            pref.setInt((activeButton?.state == .on) ? 1 : 0, forKey: k)
        }
        (modemRxControl as? RTTYRxControl)?.retrieveBasicForPlist(pref, config: self)
        if let txConfig = txConfig { txConfig.retrieveForPlist(pref, rttyRxControl: control) }

        if let k = cmKey(configSet.fskSelection) { pref.setString(preferredAFSKMenuTitle, forKey: k) }
    }

    // -------------------------------------------------------------------

    override func colorChanged(_ sender: Any?) {
        let txColor = (transmitTextColor != nil) ? transmitTextColor?.color : textColor?.color

        (oscilloscope as? Oscilloscope)?.setDisplayStyle(Int32(waveformMatrix?.selectedRow ?? 0), plotColor: plotColor?.color)
        modemObj.setTextColor(textColor?.color, sentColor: txColor, backgroundColor: backgroundColor?.color, plotColor: plotColor?.color,
                              forReceiver: (modemRxControl as? RTTYRxControl)?.uniqueID_() ?? 0)
    }

    @objc func prefMatrixChanged() {
        (modemObj as? RTTYInterface)?.setRTTYPrefs(prefMatrix, channel: configSet.channel)
    }

    //  ------------------------ Delegates -----------------------
    //  delegate for Config panel
    override func windowShouldClose(_ sender: NSWindow) -> Bool {
        configOpen = false
        updateInputSamplingState()
        txConfig?.stopSampling()
        //  turn tone matrix selection to OFF
        toneMatrix?.deselectAllCells()
        toneMatrix?.selectCell(atRow: 0, column: 0)
        toneIndex = 0

        return true
    }
}
