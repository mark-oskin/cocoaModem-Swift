//
//  ModemDest.swift
//  cocoaModem
//
//  Created by Kok Chen on Sun Aug 01 2004.
//
//  Swift port of ModemDest.m / ModemDest.h.  Subclass of the (Swift) ModemAudio;
//  reaches every inherited base ivar by its exact original name.  As an AudioPipe
//  destination, this object is accessed through the -importData: method; it feeds a
//  ResamplingPipe (already Swift) that pulls its samples from the client via
//  -needData:samples:channels:.
//
//  NOTE: the original had an ivar `outputLevel` *and* a method -outputLevel that
//  returned it, and an ivar `ptt` *and* a method -ptt that returned it.  In Swift a
//  single @objc property serves both roles, so the redundant accessor methods are
//  folded into the stored properties (the ObjC callers -[ModemDest outputLevel] /
//  -[ModemDest ptt] still resolve to the property getters).
//

import Foundation
import Cocoa

//  Device States
private let DISABLED: Int32 = 0        // caused by enableOutput:NO
private let ENABLED: Int32 = 1         // caused by enableOutput:YES
private let RUNNING: Int32 = 2         // caused by started and ENABLED

private let doNothing = 0
private let turnedOn = 1
private let turnedOff = 2

//  Plist keys (the ObjC @"..." #define macros are not imported into Swift)
private let kOutputName = " Output Name"
private let kOutputSource = " Output Source"
private let kOutputSamplingRate = " Output Sampling Rate"
private let kOutputChannel = " Output Channel"
private let kPTTMenu = " PTT"

@objc(ModemDest)
class ModemDest: ModemAudio {

    @IBOutlet var outputMenu: NSPopUpButton?
    @IBOutlet var outputDestMenu: NSPopUpButton?
    @IBOutlet var outputChannel: NSPopUpButton?
    @IBOutlet var outputSamplingRateMenu: NSPopUpButton?    // v0.53a
    @IBOutlet var outputParam: NSTextField?

    @IBOutlet var controlView: NSView?
    @IBOutlet var levelView: NSView?
    @IBOutlet var outputLevel: NSSlider?                    // also serves -[ModemDest outputLevel]
    @IBOutlet var outputAttenuator: NSTextField?

    @IBOutlet var pttMenu: NSPopUpButton?
    @objc var ptt: PTT?                                     // also serves -[ModemDest ptt]

    var client: DestClient?
    var useMenus: Bool = false

    var rateChangeBusy: Bool = false

    var outputLevelKey: String?
    var attenuatorKey: String?

    var mostRecentlyUsedDevice: String = ""                 //  v0.76

    //  initial values
    var initCh: Int32 = 0
    var initRate: Int32 = 0
    var initBits: Int32 = 0

    private func setInterface(_ object: NSControl?, to selector: Selector) {
        object?.action = selector
        object?.target = self
    }

    //  Init Modem sound destination and set the interface controls into the given view.
    //  The client must provide -needData:samples:, -enableDestinationStream:, -setOutputScale:.
    @objc(initIntoView:device:level:client:pttHub:)
    init?(intoView view: NSView?, device name: String, level: NSView?, client inClient: DestClient?, pttHub hub: PTTHub?) {
        super.init()
        initRate = 0; initCh = 0; initBits = 0
        deviceState = DISABLED
        isInputFlag = false
        mostRecentlyUsedDevice = ""
        rateChangeBusy = false
        client = inClient
        outputLevelKey = nil

        resamplingPipeChannels = 1
        resamplingPipe = ResamplingPipe(unbufferedPipeWithSamplingRate: 11025.0, channels: resamplingPipeChannels, target: self)
        resamplingPipe?.setInputSamplingRate(11025.0)
        resamplingPipe?.setOutputSamplingRate(11025.0)

        deviceName = name
        if Bundle.main.loadNibNamed((hub != nil) ? "ModemDest" : "SimpleModemDest", owner: self, topLevelObjects: nil) {
            // loadNib should have set up controlView connections
            if controlView != nil, let view = view {

                //  set up connections for super class
                soundCardMenu = outputMenu
                sourceMenu = outputDestMenu
                samplingRateMenu = outputSamplingRateMenu
                channelMenu = outputChannel
                paramString = outputParam

                if let controlView = controlView { view.addSubview(controlView) }
                if let level = level, let levelView = levelView { level.addSubview(levelView) }
                // PTT menu
                ptt = (hub != nil && pttMenu != nil) ? PTT(hub: hub!, menu: pttMenu!) : nil
                //  actions
                setInterface(outputMenu, to: #selector(outputMenuChanged))
                setInterface(outputLevel, to: #selector(outputLevelChanged))
                setInterface(outputAttenuator, to: #selector(updateAttenuator))
                setInterface(outputDestMenu, to: #selector(sourceMenuChanged))
                setInterface(outputChannel, to: #selector(channelChanged))
                setInterface(outputSamplingRateMenu, to: #selector(samplingRateChanged))

                return
            }
        }
        return nil
    }

    @objc(initIntoView:device:level:client:channels:)
    init?(intoView view: NSView?, device name: String, level: NSView?, client inClient: DestClient?, channels ch: Int32) {
        super.init()
        initRate = 0; initCh = 0; initBits = 0
        deviceState = DISABLED
        isInputFlag = false; outputMuted = false
        mostRecentlyUsedDevice = ""
        rateChangeBusy = false
        client = inClient
        outputLevelKey = nil

        resamplingPipeChannels = ch
        resamplingPipe = ResamplingPipe(unbufferedPipeWithSamplingRate: 11025.0, channels: resamplingPipeChannels, target: self)
        resamplingPipe?.setInputSamplingRate(11025.0)
        resamplingPipe?.setOutputSamplingRate(11025.0)

        deviceName = name

        if Bundle.main.loadNibNamed("SimpleModemDest", owner: self, topLevelObjects: nil) {
            if controlView != nil, let view = view {

                //  set up connections for super class
                soundCardMenu = outputMenu
                sourceMenu = outputDestMenu
                samplingRateMenu = outputSamplingRateMenu
                channelMenu = outputChannel
                paramString = outputParam

                if let controlView = controlView { view.addSubview(controlView) }
                if let level = level, let levelView = levelView { level.addSubview(levelView) }
                // PTT menu
                ptt = nil
                //  actions
                setInterface(outputMenu, to: #selector(outputMenuChanged))
                setInterface(outputLevel, to: #selector(outputLevelChanged))
                setInterface(outputAttenuator, to: #selector(updateAttenuator))
                setInterface(outputDestMenu, to: #selector(sourceMenuChanged))
                setInterface(outputChannel, to: #selector(channelChanged))
                setInterface(outputSamplingRateMenu, to: #selector(samplingRateChanged))

                return
            }
        }
        return nil
    }

    @objc(setMute:)
    func setMute(_ state: Bool) {
        outputMuted = state
    }

    //  start output sound card
    override func startSoundCard() -> Bool {
        guard let card = selectedSoundCard else { return false }    //  sanity check
        if isSampling == true { return true }                       //  already running

        if audioManager == nil {
            audioManager = (NSApp.delegate as? AppDelegate)?.audioManager()
            if audioManager == nil { return false }
        }
        startStopLock.lock()                                        //  wait for any previous start/stop to complete
        resamplingPipe?.makeNewRateConverter()
        isSampling = (audioManager?.audioDeviceStart(card.deviceID, modemAudio: self) == 0)
        startStopLock.unlock()

        return (isSampling == true)
    }

    //  stop output sound card
    override func stopSoundCard() -> Bool {
        guard let card = selectedSoundCard else { return false }    //  sanity check
        if isSampling == false { return true }

        if audioManager == nil {
            audioManager = (NSApp.delegate as? AppDelegate)?.audioManager()
            if audioManager == nil { return false }
        }
        startStopLock.lock()
        isSampling = (audioManager?.audioDeviceStop(card.deviceID, modemAudio: self) != 0)
        startStopLock.unlock()

        return (isSampling == false)
    }

    override func actualSamplingRateSet(to rate: Float) {
        //  Switch the resampling pipe.  Input (from modem) stays at 11025 s/s.
        resamplingPipe?.setOutputSamplingRate(rate)
    }

    //  (Private API)
    private func turnSamplingOn(_ state: Bool) {
        if state == true {
            if isSampling == false {
                //  first set sampling rate and source, in case we came here from a different modem interface
                _ = samplingRateChanged()
                _ = sourceMenuChanged()
                _ = startSoundCard()
            }
        } else {
            if isSampling == true { _ = stopSoundCard() }           //  stop sound card only if it is running
        }
    }

    private func changeDeviceState(to newState: Int32) {
        var action = doNothing

        switch deviceState {
        case DISABLED:
            if newState == ENABLED {
                deviceState = ENABLED
                if started {
                    turnSamplingOn(true)
                    action = turnedOn
                }
            }
        case ENABLED:
            if newState == ENABLED {
                if started == true {
                    turnSamplingOn(true)
                    action = turnedOn
                } else {
                    turnSamplingOn(false)
                    action = turnedOff
                }
            } else {
                deviceState = newState
            }
        case RUNNING:
            if newState == DISABLED {
                turnSamplingOn(false)
                action = turnedOff
                deviceState = DISABLED
                break
            }
            if started == false {
                turnSamplingOn(false)
                action = turnedOff
                deviceState = ENABLED
                break
            }
        default:
            break
        }
        if deviceState == ENABLED && started == true {
            if action != turnedOn { turnSamplingOn(true) }
            return
        }
    }

    @objc(startSampling)
    func startSampling() {
        started = true
        changeDeviceState(to: deviceState)  // update state
    }

    @objc(enableOutput:)
    func enableOutput(_ enable: Bool) {
        var newState = deviceState
        if enable {
            if deviceState == DISABLED { newState = ENABLED }
        } else {
            newState = DISABLED
        }
        changeDeviceState(to: newState)
    }

    @objc(stopSampling)
    func stopSampling() {
        started = false
        changeDeviceState(to: deviceState)  // update state
    }

    //  set output sound level key for preference
    @objc(setSoundLevelKey:attenuatorKey:)
    func setSoundLevelKey(_ key: String, attenuatorKey attenuator: String) {
        outputLevelKey = key
        attenuatorKey = attenuator
    }

    @objc(updateAttenuator)
    func updateAttenuator() {
        let dB = outputAttenuator?.floatValue ?? 0.0
        //  v0.88 -1.5 dB FS peak instead of -3 dB (note: RTTY filter needs 6% headroom)
        let value = Float(0.8913 * pow(10.0, Double(dB) / 20.0))
        client?.setOutputScale(value)
    }

    //  v0.76 -- toggle device's sampling state if the output device changes while active
    @objc(changeToNewOutputDevice:destination:refreshSamplingRateMenu:)
    func changeToNewOutputDevice(_ index: Int32, destination dest: Int32, refreshSamplingRateMenu: Bool) {
        let wasRunning = isSampling
        let newDeviceName = outputMenu?.selectedItem?.title ?? ""

        if wasRunning == true {
            //  stop sampling before switching devices
            stopSampling()
        }
        if mostRecentlyUsedDevice != newDeviceName {
            mostRecentlyUsedDevice = newDeviceName
        }
        if wasRunning == true {
            //  resume sampling
            startSampling()
        }
    }

    //  new audio output device selected
    @objc(outputMenuChanged)
    func outputMenuChanged() {
        var wasSampling = false

        //  if the device is running, turn sampling off first
        if isSampling {
            wasSampling = true
            stopSampling()
        }
        changeDeviceState(to: DISABLED)
        _ = super.soundCardChanged()
        changeDeviceState(to: ENABLED)

        //  resume sampling if we switch while sampling.
        if wasSampling { startSampling() }
    }

    //  output level control changed (slider is a scalar between 0.1 and 1.0)
    @objc(outputLevelChanged)
    func outputLevelChanged() {
        scalarSlider = outputLevel
        setDeviceLevelFromSlider()
    }

    @objc(setupDefaultPreferences:)
    func setupDefaultPreferences(_ pref: Preferences) {
        pref.setString("*", forKey: deviceName + kOutputName)
        pref.setString("*", forKey: deviceName + kOutputSource)
        pref.setString("11025", forKey: deviceName + kOutputSamplingRate)
        pref.setString("VOX", forKey: deviceName + kPTTMenu)
        pref.setInt(0, forKey: deviceName + kOutputChannel)
        var level: Float = 0.0
        if let outputLevel = outputLevel { level = outputLevel.floatValue }
        if let outputLevelKey = outputLevelKey { pref.setFloat(level, forKey: outputLevelKey) }

        var attenuator: Float = 0.0
        if let outputAttenuator = outputAttenuator { attenuator = outputAttenuator.floatValue }
        if let attenuatorKey = attenuatorKey { pref.setFloat(attenuator, forKey: attenuatorKey) }
    }

    @objc(updateFromPlist:updateAudioLevel:)
    func updateFromPlist(_ pref: Preferences, updateAudioLevel updateLevel: Bool) -> Bool {
        //  make sure there is at least one usable item
        if (outputMenu?.numberOfItems ?? 0) < 1 { return false }

        var ok = true
        var sourceIndex: Int32 = 0
        //  choose output device from Plist and set up other menus
        var name = pref.stringValue(forKey: deviceName + kOutputName)

        //  try to select it from the sound card menu
        let selectedDeviceIndex = selectSoundCard(name ?? "")
        if selectedDeviceIndex < 0 {
            //  name in Plist no longer found
            ok = false
            channel = 0
            if (outputMenu?.numberOfItems ?? 0) > 0 { outputMenu?.selectItem(at: 0) }
            if (outputDestMenu?.numberOfItems ?? 0) > 0 { outputDestMenu?.selectItem(at: 0) }
        } else {
            //  sound card chosen; -selectSoundCard should also have set up the source menu.
            //  now try to select the input source if there is more than one
            if (outputDestMenu?.numberOfItems ?? 0) > 1 {
                name = pref.stringValue(forKey: deviceName + kOutputSource)
                sourceIndex = selectSource(name ?? "")
                if sourceIndex < 0 {
                    ok = false
                    //  could not find source?  Find alternate mappings
                    //  "Internal speakers" and "Headphones" are interchangeable for built-in audio
                    let destItems = outputDestMenu?.numberOfItems ?? 0
                    var i = 0
                    while i < destItems {
                        let menuName = outputDestMenu?.item(at: i)?.title ?? ""
                        if name == "Internal speakers" && menuName == "Headphones" { break }
                        if name == "Headphones" && menuName == "Internal speakers" { break }
                        i += 1
                    }
                    if i < destItems { ok = true } else { i = 0 }
                    outputDestMenu?.selectItem(at: i)
                }
            }
            //  select channel
            channel = pref.intValue(forKey: deviceName + kOutputChannel)
            _ = selectChannel(channel)
        }

        if updateLevel == true {
            if let outputLevel = outputLevel, let outputLevelKey = outputLevelKey {
                let level = pref.floatValue(forKey: outputLevelKey)
                outputLevel.floatValue = level
                outputLevelChanged()
                let s = "\(outputLevelKey) set to \(String(format: "%.3f", level))"
                s.withCString { Messages.logMessage($0) }
            }
        } else {
            fetchDeviceLevelFromCoreAudio()
        }
        if let outputAttenuator = outputAttenuator, let attenuatorKey = attenuatorKey {
            let level = pref.floatValue(forKey: attenuatorKey)
            outputAttenuator.floatValue = level
            let s = "\(attenuatorKey) set to \(String(format: "%.0f", level)) dB"
            s.withCString { Messages.logMessage($0) }
            updateAttenuator()
        }
        if let ptt = ptt {
            let key = deviceName + kPTTMenu
            ptt.selectItem(pref.stringValue(forKey: key) ?? "")
        }
        if let card = selectedSoundCard {
            // 0.53a sampling rate option
            if audioManager == nil || audioManager?.audioDevice(forID: card.deviceID) == nil {
                let key = deviceName + kOutputSamplingRate
                if let rateName = pref.stringValue(forKey: key) {
                    outputSamplingRateMenu?.selectItem(withTitle: rateName)
                    let s = "Updating output sampling rate \(rateName) from plist"      //  v0.62
                    s.withCString { Messages.logMessage($0) }
                    _ = samplingRateChanged()                                            //  v0.53b get the rate into the modem
                }
            }
            fetchSamplingRateFromCoreAudio()    //  v0.78 forces the AudioConverter rates to be set
        }
        mostRecentlyUsedDevice = outputMenu?.titleOfSelectedItem ?? ""
        return ok
    }

    //  set up this SoundHub from settings in the Plist
    @objc(updateFromPlist:)
    func updateFromPlist(_ pref: Preferences) -> Bool {
        return updateFromPlist(pref, updateAudioLevel: true)
    }

    //  v0.86
    @objc(retrieveForPlist:updateAudioLevel:)
    func retrieveForPlist(_ pref: Preferences, updateAudioLevel updateLevel: Bool) {
        var scalarLevel: Float = 0

        //  v0.85 reset audio level just in case it was set to OOK; v0.86 don't update aural channel
        if updateLevel { scalarLevel = validateDeviceLevel() }

        if let ptt = ptt { pref.setString(ptt.selectedItem(), forKey: deviceName + kPTTMenu) }
        pref.setString(outputMenu?.titleOfSelectedItem, forKey: deviceName + kOutputName)
        pref.setString(outputDestMenu?.titleOfSelectedItem, forKey: deviceName + kOutputSource)
        pref.setInt(channel, forKey: deviceName + kOutputChannel)

        if let selectedTitle = outputSamplingRateMenu?.titleOfSelectedItem {
            pref.setString(selectedTitle, forKey: deviceName + kOutputSamplingRate)
        }

        if outputLevel != nil, let outputLevelKey = outputLevelKey {
            pref.setFloat(scalarLevel, forKey: outputLevelKey)      //  v0.85
        }
        if let outputAttenuator = outputAttenuator, let attenuatorKey = attenuatorKey {
            pref.setFloat(outputAttenuator.floatValue, forKey: attenuatorKey)
        }
    }

    @objc(retrieveForPlist:)
    func retrieveForPlist(_ pref: Preferences) {
        retrieveForPlist(pref, updateAudioLevel: true)
    }

    //  AudioOutputPort callbacks -- ask client for data.
    //  needData should return 1 for mono buffer, 2 for stereo buffer.
    override func needData(_ outbuf: UnsafeMutablePointer<Float>, samples n: Int32, channels ch: Int32) -> Int32 {
        return client?.needData(outbuf, samples: n) ?? 0
    }

    //  delegate for destination panel
    @objc(windowShouldClose:)
    func windowShouldClose(_ sender: Any) -> Bool {
        return true
    }
}
