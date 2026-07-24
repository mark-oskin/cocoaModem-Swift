//
//  Config.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on Mon May 17 2004.
//
//  Swift port of Config.m — the nib-loaded leaf subclass of Preferences.
//
//  The many kXxx plist keys and the modem-order constants come from Plist.h
//  (bridging header) and are referenced, not redefined.  Config talks to the
//  Application (Swift), StdManager / PTTHub / QSO (Obj-C via the generated
//  header) and the still-Obj-C AuralMonitor (reached dynamically as AnyObject).
//

import Cocoa
import UniformTypeIdentifiers

@objc(Config)
class Config: Preferences, NSWindowDelegate {

    //  ---- IBOutlets (KVC nib outlets) -------------------------------------
    @objc var prefPanel: NSWindow!
    @objc var appearancePrefs: NSMatrix!            //  NSMatrix of NSButtons
    @objc var pskPrefs: NSMatrix!                   //  NSMatrix of NSButtons
    @objc var modemPrefs: NSMatrix!                 //  NSMatrix of checkboxes

    @objc var hideWindowCheckbox: NSButton!

    @objc var autoConnectCheckbox: NSButton!

    @objc var netAudioEnableCheckbox: NSButton!
    @objc var netInputServiceMatrix: NSMatrix!
    @objc var netInputAddressMatrix: NSMatrix!
    @objc var netInputPortMatrix: NSMatrix!
    @objc var netInputPasswordMatrix: NSMatrix!
    @objc var netOutputServiceMatrix: NSMatrix!
    @objc var netOutputAddressMatrix: NSMatrix!
    @objc var netOutputPortMatrix: NSMatrix!
    @objc var netOutputPasswordMatrix: NSMatrix!

    @objc var userPTTFolderField: NSTextField!
    @objc var logScriptField: NSTextField!

    @objc var microKeyerModeCheckbox: NSButton!         //  v0.68
    @objc var microKeyerQuitScriptField: NSTextField!   //  v0.66

    @objc var macroScript0: NSTextField!                //  v0.89
    @objc var macroScript1: NSTextField!
    @objc var macroScript2: NSTextField!
    @objc var macroScript3: NSTextField!
    @objc var macroScript4: NSTextField!
    @objc var macroScript5: NSTextField!

    @objc var noOpenRouter: NSButton!                   //  v0.89

    //  The Obj-C IBOutlet 'quitWithAutoRouting' shares its name with the
    //  -quitWithAutoRouting method.  Swift forbids a stored property and a
    //  method of the same name, and DigitalInterfaces (Swift) calls the method
    //  as config.quitWithAutoRouting(), so the method keeps the name and the
    //  outlet is backed by this renamed property.  The nib still connects the
    //  outlet through the KVC setter setQuitWithAutoRouting: below.
    private var quitWithAutoRoutingButton: NSButton!

    @objc(setQuitWithAutoRouting:)
    func setQuitWithAutoRoutingOutlet(_ button: NSButton!) {
        quitWithAutoRoutingButton = button
    }

    //  v0.96d speech
    @objc var mainReceiverSpeechCheckbox: NSButton!
    @objc var mainReceiverSpeechMenu: NSPopUpButton!
    @objc var mainReceiverVerbatimCheckbox: NSButton!
    @objc var subReceiverSpeechCheckbox: NSButton!
    @objc var subReceiverSpeechMenu: NSPopUpButton!
    @objc var subReceiverVerbatimCheckbox: NSButton!
    @objc var transmitterSpeechCheckbox: NSButton!
    @objc var transmitterSpeechMenu: NSPopUpButton!
    @objc var transmitterVerbatimCheckbox: NSButton!

    //  v1.02d
    @objc var voiceAssistSpeechMenu: NSPopUpButton!

    //  ---- ivars -----------------------------------------------------------
    private var application: Application!
    private var voices: [String] = []

    private var logScriptFileName: String = ""
    private var microKeyerQuitScriptName: String = ""       //  renamed to avoid clashing with the method
    private var pttScriptFolderName: String = ""
    private var macroScriptFileName: [String] = Array(repeating: "", count: 6)

    private var prefChanged: Bool = false

    //  ---- init / nib ------------------------------------------------------

    //  initialize
    @objc(initWithApp:)
    init?(app: Application!) {
        super.init()                                        //  Preferences.init() builds the default path
        if Bundle.main.loadNibNamed("Config", owner: self, topLevelObjects: nil) {
            logScriptFileName = ""
            pttScriptFolderName = ""
            logScriptField?.stringValue = logScriptFileName
            application = app
            for i in 0..<6 { macroScriptFileName[i] = "" }
            return
        }
        return nil
    }

    private func setInterface(_ object: NSControl?, to selector: Selector) {
        object?.action = selector
        object?.target = self
    }

    override func awakeFromNib() {
        setInterface(microKeyerQuitScriptField, to: #selector(setupMicroKeyerQuit))

        //  v0.96d
        let avail = NSSpeechSynthesizer.availableVoices
        var all: [NSSpeechSynthesizer.VoiceName] = []
        all.append(NSSpeechSynthesizer.defaultVoice)
        all.append(contentsOf: avail)
        voices = all.map { $0.rawValue }

        if voices.isEmpty { return }

        let size = voices.count
        var simple: [String] = []
        simple.append(String(format: "Default Voice (%@)", (voices[0] as NSString).pathExtension))
        for i in 1..<size {
            simple.append((voices[i] as NSString).pathExtension)
        }

        mainReceiverSpeechMenu.removeAllItems()
        mainReceiverSpeechMenu.addItems(withTitles: simple)
        setInterface(mainReceiverSpeechMenu, to: #selector(mainSpeechMenuChanged(_:)))
        setInterface(mainReceiverSpeechCheckbox, to: #selector(mainSpeechCheckboxChanged(_:)))
        setInterface(mainReceiverVerbatimCheckbox, to: #selector(mainSpeechVerbatimChanged(_:)))

        subReceiverSpeechMenu.removeAllItems()
        subReceiverSpeechMenu.addItems(withTitles: simple)
        setInterface(subReceiverSpeechMenu, to: #selector(subSpeechMenuChanged(_:)))
        setInterface(subReceiverSpeechCheckbox, to: #selector(subSpeechCheckboxChanged(_:)))
        setInterface(subReceiverVerbatimCheckbox, to: #selector(subSpeechVerbatimChanged(_:)))

        transmitterSpeechMenu.removeAllItems()
        transmitterSpeechMenu.addItems(withTitles: simple)
        setInterface(transmitterSpeechMenu, to: #selector(transmitSpeechMenuChanged(_:)))
        setInterface(transmitterSpeechCheckbox, to: #selector(transmitSpeechCheckboxChanged(_:)))
        setInterface(transmitterVerbatimCheckbox, to: #selector(transmitterVerbatimChanged(_:)))

        //  v1.02d
        voiceAssistSpeechMenu.removeAllItems()
        voiceAssistSpeechMenu.addItems(withTitles: simple)
        setInterface(voiceAssistSpeechMenu, to: #selector(voiceAssistMenuChanged(_:)))
    }

    @objc func awakeFromApplication() {
        //  delegate to trap pref panel closure
        prefPanel?.delegate = self
    }

    @objc func logScriptFile() -> String? {
        return logScriptFileName
    }

    @objc func pttScriptFolder() -> String? {
        return pttScriptFolderName
    }

    @objc(prefPanelChanged:)
    func prefPanelChanged(_ sender: Any?) {
        prefChanged = true
    }

    //  ---- browsing helpers ------------------------------------------------

    //  browse for AppleScript filename.  Modernized NSOpenPanel:
    //  runModalForTypes:/filename/NSOKButton -> allowedContentTypes/url.path/.OK
    private func browseForField(_ textField: NSTextField, into filename: inout String, isFolder: Bool) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = isFolder
        panel.canChooseFiles = !isFolder

        //  only allow scripts to be selected
        panel.allowedContentTypes = [UTType.appleScript]
        if panel.runModal() == .OK, let url = panel.url {
            filename = url.path
            if isFolder {
                //  complete path
                textField.stringValue = url.path
            } else {
                //  filename only
                textField.stringValue = (filename as NSString).lastPathComponent
            }
            return true
        }
        filename = textField.stringValue
        return false
    }

    @objc(browseForLogScript:)
    func browseForLogScript(_ sender: Any?) {
        if browseForField(logScriptField, into: &logScriptFileName, isFolder: false) {
            if let qso = application?.stdManagerObject()?.qsoObject() {
                qso.logScriptChanged(logScriptFileName)
            }
        }
    }

    //  v0.89
    @objc(browseForMacroScript:)
    func browseForMacroScript(_ sender: Any?) {
        let index = (sender as? NSControl)?.tag ?? 0
        let field: NSTextField
        switch index {
        case 1:  field = macroScript1
        case 2:  field = macroScript2
        case 3:  field = macroScript3
        case 4:  field = macroScript4
        case 5:  field = macroScript5
        default: field = macroScript0
        }
        if browseForField(field, into: &macroScriptFileName[index], isFolder: false) {
            application?.macroScripts()?.setScriptFile(macroScriptFileName[index], index: Int32(index))
        }
    }

    @objc(macroScriptFieldChanged:)
    func macroScriptFieldChanged(_ sender: Any?) {
        let index = (sender as? NSControl)?.tag ?? 0
        application?.macroScripts()?.setScriptFile((sender as? NSControl)?.stringValue, index: Int32(index))
    }

    @objc(browseForMicroHamQuitScript:)
    func browseForMicroHamQuitScript(_ sender: Any?) {
        _ = browseForField(microKeyerQuitScriptField, into: &microKeyerQuitScriptName, isFolder: false)
    }

    @objc(scriptFieldChanged:)
    func scriptFieldChanged(_ sender: Any?) {
        logScriptFileName = logScriptField.stringValue
        if let qso = application?.stdManagerObject()?.qsoObject() {
            qso.logScriptChanged(logScriptFileName)
        }
    }

    @objc(browseForPTTFolder:)
    func browseForPTTFolder(_ sender: Any?) {
        if browseForField(userPTTFolderField, into: &pttScriptFolderName, isFolder: true) {
            application?.stdManagerObject()?.pttHub()?.updateUserPTTScripts(pttScriptFolderName)
        }
    }

    @objc(pttFolderChanged:)
    func pttFolderChanged(_ sender: Any?) {
        pttScriptFolderName = userPTTFolderField.stringValue
        application?.stdManagerObject()?.pttHub()?.updateUserPTTScripts(pttScriptFolderName)
    }

    private func defaultGeneralPref(_ index: Int, to state: Bool) {
        appearancePrefs.cell(atRow: index, column: 0)?.state = state ? .on : .off
    }

    /* local */
    private func createEmptyArrayOfStrings(_ size: Int) -> [String] {
        return Array(repeating: "", count: size)
    }

    //  ---- default preferences (keys are found in Plist.h) -----------------
    @objc func setupDefaultPreferences() {
        if application == nil {
            fatalError("config has no pointer to application")
        }
        //  default application prefs (plist version, window position, tab item)
        setString(application.mainWindow()?.frameDescriptor, forKey: kWindowPosition)
        setString("DefaultTabItem", forKey: kTabName)

        //  Unicode preferences v0.70
        setInt(0, forKey: kUseUnicodeForPSK)

        //  General preferences
        setInt(0, forKey: kAutoConnect)
        setInt(0, forKey: kEnableNetAudio)          //  v0.64d
        setInt(0, forKey: kHideWindow)              //  Lite window v0.64e
        setInt(0, forKey: kToolTips)
        setInt(0, forKey: kSlashZeros)
        setInt(0, forKey: kNoOpenRouter)
        setInt(0, forKey: kQuitWithAutoRouting)     //  v0.93b

        defaultGeneralPref(0, to: true)
        defaultGeneralPref(1, to: true)
        defaultGeneralPref(2, to: false)
        defaultGeneralPref(3, to: true)
        defaultGeneralPref(4, to: false)
        defaultGeneralPref(5, to: true)
        defaultGeneralPref(6, to: true)
        defaultGeneralPref(7, to: true)
        defaultGeneralPref(8, to: false)            //  Lite interface

        var empty = createEmptyArrayOfStrings(6)
        setArray(empty, forKey: kMacroScripts)

        //  Initialize default NetAudio dictionary items to be empty v0.47
        empty = createEmptyArrayOfStrings(4)
        setArray(empty, forKey: kNetInputServices)
        setArray(empty, forKey: kNetInputAddresses)
        setArray(empty, forKey: kNetInputPorts)
        setArray(empty, forKey: kNetInputPasswords)
        setArray(empty, forKey: kNetOutputServices)
        setArray(empty, forKey: kNetOutputPorts)
        setArray(empty, forKey: kNetOutputPasswords)

        //  QSO preferences
        setInt(0, forKey: kQSOInterface)
        setString("", forKey: kQSOScript)           //  v0.34

        //  PSK Preferences
        setString("", forKey: kPSKPrefs)

        //  Modem Prefs
        setString("1111111111", forKey: kModemList) //  enable all modems as default

        //  User Defined PTT
        setString("", forKey: kUserPTTFolder)

        //  uH Router
        setString("", forKey: kMicroKeyerSetup3)
        setString("", forKey: kMicroKeyerQuitScript)    //  v0.66
        microKeyerQuitScriptName = ""
        setInt(0, forKey: kMicroKeyerInvert)
        setInt(0, forKey: kMicroKeyerMode)              //  v0.68

        if application.userInfoObject() == nil {
            fatalError("config has no pointer to UserInfo object")
        }
        application.userInfoObject().setupDefaultPreferences(self)

        if application.stdManagerObject() == nil {
            fatalError("config has no pointer to stdManager")
        }
        application.stdManagerObject().setupDefaultPreferences(self)

        //  AuralMonitor is still Obj-C and reached as AnyObject
        _ = (application.auralMonitor() as? NSObject)?.perform(Selector(("setupDefaultPreferences:")), with: self)
    }

    //  v0.66
    @objc func microKeyerQuitScriptFileName() -> String? {
        return microKeyerQuitScriptName
    }

    @objc func setupMicroKeyer() {
        if application != nil {
            let digitalInterfaces = application.digitalInterfaces()
            digitalInterfaces?.useDigitalModeOnlyForFSK(microKeyerModeCheckbox.state == .on)
        }
    }

    //  v0.66
    @objc func setupMicroKeyerQuit() {
        microKeyerQuitScriptName = microKeyerQuitScriptField.stringValue
    }

    /* local */
    private func setMatrix(_ matrix: NSMatrix, fromKey key: String) {
        guard let array = array(forKey: key) else { return }
        var count = array.count
        if count > 4 { count = 4 }
        for i in 0..<count {
            matrix.cell(atRow: i, column: 0)?.stringValue = array[i] as? String ?? ""
        }
    }

    /* local */
    private func setMatrix(_ matrix: NSMatrix, fromString string: String) {
        for i in 0..<4 {
            matrix.cell(atRow: i, column: 0)?.stringValue = string
        }
    }

    private func setKey(_ key: String, fromMatrix matrix: NSMatrix) {
        var array: [String] = []
        for i in 0..<4 {
            array.append(matrix.cell(atRow: i, column: 0)?.stringValue ?? "")
        }
        setArray(array, forKey: key)
    }

    private func addMacroScript(_ array: [Any]?, index: Int) {
        guard let macroScripts = application?.macroScripts() else { return }

        guard let array = array, index < array.count else { return }
        guard let apath = array[index] as? String, !apath.isEmpty else { return }

        let field: NSTextField
        switch index {
        case 1:  field = macroScript1
        case 2:  field = macroScript2
        case 3:  field = macroScript3
        case 4:  field = macroScript4
        case 5:  field = macroScript5
        default: field = macroScript0
        }
        if macroScripts.setScriptFile(apath, index: Int32(index)) != nil {
            macroScriptFileName[index] = apath
            field.stringValue = (apath as NSString).lastPathComponent
        } else {
            macroScriptFileName[index] = ""
            field.stringValue = ""
        }
    }

    //  ---- speech (v0.96d / v1.02d) ----------------------------------------
    private func speechMenuChanged(_ sender: Any?, channel: Int32) {
        let index = (sender as? NSPopUpButton)?.indexOfSelectedItem ?? -1
        if index <= 0 {
            application?.setVoice(nil, channel: channel)
            return
        }
        application?.setVoice(voices[index], channel: channel)
    }

    //  v1.02d
    @objc func voiceAssistMenuChanged(_ sender: Any?) {
        speechMenuChanged(sender, channel: 3)
    }

    @objc func mainSpeechMenuChanged(_ sender: Any?) {
        speechMenuChanged(sender, channel: 1)
    }

    @objc func subSpeechMenuChanged(_ sender: Any?) {
        speechMenuChanged(sender, channel: 2)
    }

    @objc func transmitSpeechMenuChanged(_ sender: Any?) {
        speechMenuChanged(sender, channel: 0)
    }

    private func speechCheckboxChanged(_ sender: Any?, channel: Int32) {
        application?.setVoiceEnable((sender as? NSButton)?.state == .on, channel: channel)
    }

    @objc func mainSpeechCheckboxChanged(_ sender: Any?) {
        speechCheckboxChanged(sender, channel: 1)
    }

    @objc func subSpeechCheckboxChanged(_ sender: Any?) {
        speechCheckboxChanged(sender, channel: 2)
    }

    @objc func transmitSpeechCheckboxChanged(_ sender: Any?) {
        speechCheckboxChanged(sender, channel: 0)
    }

    private func verbatimChanged(_ sender: Any?, channel: Int32) {
        application?.setVerbatimSpeech((sender as? NSButton)?.state == .on, channel: channel)
    }

    @objc func mainSpeechVerbatimChanged(_ sender: Any?) {
        verbatimChanged(sender, channel: 1)
    }

    @objc func subSpeechVerbatimChanged(_ sender: Any?) {
        verbatimChanged(sender, channel: 2)
    }

    //  NOTE: the original passes channel:1 here (as in Config.m) — preserved verbatim
    @objc func transmitterVerbatimChanged(_ sender: Any?) {
        verbatimChanged(sender, channel: 1)
    }

    //  ---- update all parameters from the plist (called after fetchPlist) --
    @objc @discardableResult
    func updatePreferences() -> Bool {
        //  window position
        let stdManager = application?.stdManagerObject()
        application?.mainWindow()?.setFrame(from: stringValue(forKey: kWindowPosition) ?? "")

        //  Unicode preferences v0.70
        application?.setUseUnicodeForPSK(intValue(forKey: kUseUnicodeForPSK) != 0)

        //  User Defined PTT (v0.60 set up before modem setup)
        if let s = stringValue(forKey: kUserPTTFolder) {
            userPTTFolderField.stringValue = s
            if let pttHub = application?.stdManagerObject()?.pttHub() {
                if s.count > 0 { pttHub.updateUserPTTScripts(s) }
            }
        }
        //  set up Aural Monitor (before setting up modems when StdManager selects the tab view)
        _ = (application?.auralMonitor() as? NSObject)?.perform(Selector(("updateFromPlist:")), with: self)

        let tabName = stringValue(forKey: kTabName)
        stdManager?.selectTabView(tabName)

        //  connections preference
        autoConnectCheckbox.state = (intValue(forKey: kAutoConnect) != 0) ? .on : .off

        //  set the NetAudio text fields v0.47
        setMatrix(netInputServiceMatrix, fromKey: kNetInputServices)
        setMatrix(netInputAddressMatrix, fromKey: kNetInputAddresses)
        setMatrix(netInputPortMatrix, fromKey: kNetInputPorts)
        setMatrix(netInputPasswordMatrix, fromKey: kNetInputPasswords)
        setMatrix(netOutputServiceMatrix, fromKey: kNetOutputServices)
        setMatrix(netOutputPortMatrix, fromKey: kNetOutputPorts)
        setMatrix(netOutputPasswordMatrix, fromKey: kNetOutputPasswords)

        var ip = "127.0.0.1"
        if hasKey(kEnableNetAudio) {
            if intValue(forKey: kEnableNetAudio) != 0 { ip = String(cString: application.localHostIP()) }
        }
        setMatrix(netOutputAddressMatrix, fromString: ip)

        //  update enable netaudio v0.64d
        netAudioEnableCheckbox.state = .off
        if hasKey(kEnableNetAudio) {
            if intValue(forKey: kEnableNetAudio) != 0 {
                ip = String(cString: application.localHostIP())
                netAudioEnableCheckbox.state = .on
            }
        } else {
            setInt(0, forKey: kEnableNetAudio)
        }
        hideWindowCheckbox.state = .off
        if hasKey(kHideWindow) {
            if intValue(forKey: kHideWindow) != 0 { hideWindowCheckbox.state = .on }
        } else {
            setInt(0, forKey: kHideWindow)
        }

        noOpenRouter.state = (intValue(forKey: kNoOpenRouter) == 1) ? .on : .off                    //  v0.89
        quitWithAutoRoutingButton.state = (intValue(forKey: kQuitWithAutoRouting) == 1) ? .on : .off //  v0.93b

        //  v0.89 MacroScripts
        let scriptArray = prefs.object(forKey: kMacroScripts) as? [Any]
        for i in 0..<6 {
            addMacroScript(scriptArray, index: i)
        }

        //  appearance preferences
        if let s = stringValue(forKey: kAppearancePrefs) {
            //  clear Lite as default
            appearancePrefs.cell(atRow: 8, column: 0)?.state = .off

            let appearanceString = Array(s.utf8)
            let count = appearanceString.count
            for i in 0..<count {
                let state = appearanceString[i]
                if i == 6 { setInt(state == UInt8(ascii: "1") ? 1 : 0, forKey: kSlashZeros) }  //  set kSlashZero from kAppearancePrefs
                if state == 0 { break }
                appearancePrefs.cell(atRow: i, column: 0)?.state = (state == UInt8(ascii: "1")) ? .on : .off
            }
        }
        //  PSK preferences
        if let s = stringValue(forKey: kPSKPrefs) {
            let pskString = Array(s.utf8)
            let count = pskPrefs.numberOfRows
            for i in 0..<count {
                if i >= pskString.count { break }
                let state = pskString[i]
                if state == 0 { break }
                pskPrefs.cell(atRow: i, column: 0)?.state = (state == UInt8(ascii: "1")) ? .on : .off
            }
        }
        //  Modem preferences - set number of items and position
        var rows = modemPrefs.numberOfRows
        while rows < 7 { modemPrefs.addRow(); rows += 1 }
        modemPrefs.sizeToCells()
        var matrixFrame = modemPrefs.frame
        let viewFrame = modemPrefs.superview?.frame ?? .zero
        matrixFrame.origin.y = (viewFrame.size.height - matrixFrame.size.height) * 0.5
        modemPrefs.frame = matrixFrame
        //  first, clear all titles
        for i in 0..<7 {
            modemPrefs.cell(atRow: i, column: 0)?.title = ""
            modemPrefs.cell(atRow: i, column: 1)?.title = ""
        }
        modemPrefs.cell(atRow: Int(kRTTYModemOrder), column: 0)?.title = "RTTY"
        modemPrefs.cell(atRow: Int(kWidebandRTTYModemOrder), column: 0)?.title = "Wideband RTTY"
        modemPrefs.cell(atRow: Int(kDualRTTYModemOrder), column: 0)?.title = "Dual RTTY"
        modemPrefs.cell(atRow: Int(kPSKModemOrder), column: 0)?.title = "PSK"
        modemPrefs.cell(atRow: Int(kMFSKModemOrder), column: 0)?.title = "MFSK"
        modemPrefs.cell(atRow: Int(kHellModemOrder), column: 0)?.title = "Hellschreiber"
        modemPrefs.cell(atRow: Int(kSitorModemOrder), column: 0)?.title = "SITOR-B"

        modemPrefs.cell(atRow: Int(kFAXModemOrder) % 7, column: Int(kFAXModemOrder) / 7)?.title = "HF-FAX"
        modemPrefs.cell(atRow: Int(kCWModemOrder) % 7, column: Int(kCWModemOrder) / 7)?.title = "CW"
        modemPrefs.cell(atRow: Int(kAMModemOrder) % 7, column: Int(kAMModemOrder) / 7)?.title = "Synchronous AM"
        modemPrefs.cell(atRow: Int(kASCIIModemOrder) % 7, column: Int(kASCIIModemOrder) / 7)?.title = "ASCII"

        if let s = stringValue(forKey: kModemList) {
            let modemString = Array(s.utf8)
            let count = Int(kModemsImplemented)
            for i in 0..<count {
                let state = (i < modemString.count) ? modemString[i] : 0
                modemPrefs.cell(atRow: i % 7, column: i / 7)?.state = (state == UInt8(ascii: "1")) ? .on : .off
            }
        }

        //  microKeyer (remains here v0.60, user ptt has moved)
        if application?.stdManagerObject()?.pttHub() != nil {
            setupMicroKeyer()
            microKeyerQuitScriptName = stringValue(forKey: kMicroKeyerQuitScript) ?? ""
            microKeyerQuitScriptField.stringValue = (microKeyerQuitScriptName as NSString).lastPathComponent
        }

        //  QSO interface
        application?.stdManagerObject()?.setEnableQSOInterface(intValue(forKey: kQSOInterface) != 0)
        logScriptFileName = stringValue(forKey: kQSOScript) ?? ""
        logScriptField.stringValue = (logScriptFileName as NSString).lastPathComponent
        if let qso = application?.stdManagerObject()?.qsoObject() {
            qso.logScriptChanged(logScriptFileName)
        }

        //  update preferences of each component
        application?.userInfoObject()?.updateFromPlist(self)

        _ = stdManager?.update(fromPlist: self)

        //  v0.96d voices
        if let s = stringValue(forKey: kMainReceiverVoice) {
            mainReceiverSpeechMenu.selectItem(withTitle: s)
            if mainReceiverSpeechMenu.indexOfSelectedItem < 0 { mainReceiverSpeechMenu.selectItem(at: 0) }
        }
        mainSpeechMenuChanged(mainReceiverSpeechMenu)
        mainReceiverSpeechCheckbox.state = (intValue(forKey: kMainReceiverVoiceEnable) != 0) ? .on : .off
        mainSpeechCheckboxChanged(mainReceiverSpeechCheckbox)
        mainReceiverVerbatimCheckbox.state = (intValue(forKey: kMainReceiverVoiceVerbatim) != 0) ? .on : .off
        mainSpeechVerbatimChanged(mainReceiverVerbatimCheckbox)

        if let s = stringValue(forKey: kSubReceiverVoice) {
            subReceiverSpeechMenu.selectItem(withTitle: s)
            if subReceiverSpeechMenu.indexOfSelectedItem < 0 { subReceiverSpeechMenu.selectItem(at: 0) }
        }
        subSpeechMenuChanged(subReceiverSpeechMenu)
        subReceiverSpeechCheckbox.state = (intValue(forKey: kSubReceiverVoiceEnable) != 0) ? .on : .off
        subSpeechCheckboxChanged(subReceiverSpeechCheckbox)
        subReceiverVerbatimCheckbox.state = (intValue(forKey: kSubReceiverVoiceVerbatim) != 0) ? .on : .off
        subSpeechVerbatimChanged(subReceiverVerbatimCheckbox)

        if let s = stringValue(forKey: kTransmitterVoice) {
            transmitterSpeechMenu.selectItem(withTitle: s)
            if transmitterSpeechMenu.indexOfSelectedItem < 0 { transmitterSpeechMenu.selectItem(at: 0) }
        }
        transmitSpeechMenuChanged(transmitterSpeechMenu)
        transmitterSpeechCheckbox.state = (intValue(forKey: kTransmitterVoiceEnable) != 0) ? .on : .off
        transmitSpeechCheckboxChanged(transmitterSpeechCheckbox)
        transmitterVerbatimCheckbox.state = (intValue(forKey: kTransmitterVoiceVerbatim) != 0) ? .on : .off
        transmitterVerbatimChanged(transmitterVerbatimCheckbox)

        //  v1.02d more voices
        if let s = stringValue(forKey: kSpeechAssistVoice) {
            voiceAssistSpeechMenu.selectItem(withTitle: s)
            //  NOTE: original selects mainReceiverSpeechMenu here — preserved verbatim
            if voiceAssistSpeechMenu.indexOfSelectedItem < 0 { mainReceiverSpeechMenu.selectItem(at: 0) }
        }
        voiceAssistMenuChanged(voiceAssistSpeechMenu)

        //  set up appearance preferences
        application?.setAppearancePrefs(appearancePrefs)
        stdManager?.setAppearancePrefs(appearancePrefs)
        stdManager?.setPSKPrefs(pskPrefs)

        return true
    }

    //  ---- save the user preferences back into the plist file --------------
    override func savePlist() {
        //  version 4 - force BELL off
        setInt(4, forKey: kPrefVersion)

        //  remove deprecated keys
        removeKey(kUseCocoaPTT)
        removeKey(kUseMLDXPTT)
        removeKey(kKeyScript)
        removeKey(kUnkeyScript)

        //  v0.89 MacroScripts
        var array: [String] = []
        for i in 0..<6 { array.append(macroScriptFileName[i]) }
        setArray(array, forKey: kMacroScripts)

        //  window position, tab view item selected
        let stdManager = application?.stdManagerObject()
        setString(application?.mainWindow()?.frameDescriptor, forKey: kWindowPosition)
        setString(stdManager?.nameOfSelectedTabView(), forKey: kTabName)
        //  QSO interface
        setInt((application?.stdManagerObject()?.qsoInterfaceShowing() ?? false) ? 1 : 0, forKey: kQSOInterface)
        setString(logScriptFileName, forKey: kQSOScript)

        //  Unicode preferences v0.70
        setInt((application?.useUnicodeForPSK() ?? false) ? 1 : 0, forKey: kUseUnicodeForPSK)

        //  v0.96d
        var voice = (mainReceiverSpeechMenu.indexOfSelectedItem <= 0) ? "Default Voice" : (mainReceiverSpeechMenu.titleOfSelectedItem ?? "Default Voice")
        setString(voice, forKey: kMainReceiverVoice)
        setInt((mainReceiverSpeechCheckbox.state == .on) ? 1 : 0, forKey: kMainReceiverVoiceEnable)

        voice = (subReceiverSpeechMenu.indexOfSelectedItem <= 0) ? "Default Voice" : (subReceiverSpeechMenu.titleOfSelectedItem ?? "Default Voice")
        setString(voice, forKey: kSubReceiverVoice)
        setInt((subReceiverSpeechCheckbox.state == .on) ? 1 : 0, forKey: kSubReceiverVoiceEnable)

        voice = (transmitterSpeechMenu.indexOfSelectedItem <= 0) ? "Default Voice" : (transmitterSpeechMenu.titleOfSelectedItem ?? "Default Voice")
        setString(voice, forKey: kTransmitterVoice)
        setInt((transmitterSpeechCheckbox.state == .on) ? 1 : 0, forKey: kTransmitterVoiceEnable)

        //  v1.02d
        voice = (voiceAssistSpeechMenu.indexOfSelectedItem <= 0) ? "Default Voice" : (voiceAssistSpeechMenu.titleOfSelectedItem ?? "Default Voice")
        setString(voice, forKey: kSpeechAssistVoice)

        //  appearance prefs string (ascii '1's and '0's)
        var str = ""
        var count = appearancePrefs.numberOfRows
        for i in 0..<count {
            str += (appearancePrefs.cell(atRow: i, column: 0)?.state == .on) ? "1" : "0"
        }
        setString(str, forKey: kAppearancePrefs)

        //  PSK prefs string (ascii '1's and '0's)
        str = ""
        count = pskPrefs.numberOfRows
        for i in 0..<count {
            str += (pskPrefs.cell(atRow: i, column: 0)?.state == .on) ? "1" : "0"
        }
        setString(str, forKey: kPSKPrefs)

        //  Modem prefs string (ascii '1's and '0's)
        str = ""
        count = Int(kModemsImplemented)
        var i = 0
        while i < count {
            str += (modemPrefs.cell(atRow: i % 7, column: i / 7)?.state == .on) ? "1" : "0"
            i += 1
        }
        while i < 15 { str += "1"; i += 1 }
        setString(str, forKey: kModemList)

        //  User Defined PTT
        setString(userPTTFolderField.stringValue, forKey: kUserPTTFolder)

        //  microkeyer (mH Router)
        setString(microKeyerQuitScriptName, forKey: kMicroKeyerQuitScript)
        setInt((microKeyerModeCheckbox.state == .on) ? 1 : 0, forKey: kMicroKeyerMode)

        //  connection preferences
        setInt((autoConnectCheckbox.state == .on) ? 1 : 0, forKey: kAutoConnect)

        //  get the NetAudio text fields v0.47
        setKey(kNetInputServices, fromMatrix: netInputServiceMatrix)
        setKey(kNetInputAddresses, fromMatrix: netInputAddressMatrix)
        setKey(kNetInputPorts, fromMatrix: netInputPortMatrix)
        setKey(kNetInputPasswords, fromMatrix: netInputPasswordMatrix)
        setKey(kNetOutputServices, fromMatrix: netOutputServiceMatrix)
        setKey(kNetOutputPorts, fromMatrix: netOutputPortMatrix)
        setKey(kNetOutputPasswords, fromMatrix: netOutputPasswordMatrix)

        //  get enable netaudio v0.64d
        setInt((netAudioEnableCheckbox.state == .on) ? 1 : 0, forKey: kEnableNetAudio)
        //  get hide window checkbox
        setInt((hideWindowCheckbox.state == .on) ? 1 : 0, forKey: kHideWindow)
        //  v0.89 keep uH Router closed
        setInt((noOpenRouter.state == .on) ? 1 : 0, forKey: kNoOpenRouter)
        //  v0.93b set uH Router to auto routing when cocoaModem quits
        setInt((quitWithAutoRoutingButton.state == .on) ? 1 : 0, forKey: kQuitWithAutoRouting)

        //  retrieve info of each component
        application?.userInfoObject()?.retrieveForPlist(self)
        stdManager?.retrieve(forPlist: self)

        _ = (application?.auralMonitor() as? NSObject)?.perform(Selector(("retrieveForPlist:")), with: self)

        super.savePlist()
    }

    //  v0.93b set microHAM to auto routing when cocoaModem quits
    @objc func quitWithAutoRouting() -> Bool {
        return quitWithAutoRoutingButton.state == .on
    }

    //  preference panel
    @objc(showPreferencePanel:)
    func showPreferencePanel(_ sender: Any?) {
        prefChanged = false
        prefPanel?.center()
        prefPanel?.orderFront(nil)
    }

    //  delegate for Pref panel
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        //  pref panel closes... set up everything else
        if prefChanged {
            let stdManager = application?.stdManagerObject()
            application?.setAppearancePrefs(appearancePrefs)
            stdManager?.setAppearancePrefs(appearancePrefs)
            stdManager?.setPSKPrefs(pskPrefs)
        }
        return true
    }
}
