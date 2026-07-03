//
//  ModemSource.swift
//  cocoaModem
//
//  Adapted from PrototypeSource on Thu July 29 2004
//  Created by Kok Chen on Wed May 26 2004.
//
//  Swift port of ModemSource.m / ModemSource.h.  Subclass of the (Swift) ModemAudio;
//  reaches every inherited base ivar (channel, channels, baseChannel, clientBuffer,
//  resampledBuffer, data, tapClient, outputClient, selectedSoundCard, ...) by its
//  exact original name.  ModemSource is a CMPipe source: it gets waveform data from
//  either a CoreAudio sound card (via the ResamplingPipe read thread) or an AIFF/WAV
//  file (via AIFFSource), and pushes 11025 s/s frames downstream through importData:.
//
//  NOTE: the original ivar `delegate` plus -delegate/-setDelegate: are folded into a
//  single @objc property.  The dead `#ifdef NODRAIN` autorelease-drain block in
//  -readThread: (NODRAIN is never defined) is omitted.
//

import Foundation
import Cocoa
import CoreAudio

//  Device States
private let DISABLED: Int32 = 0
private let ENABLED: Int32 = 1
private let RUNNING: Int32 = 2

private let doNothing = 0
private let turnedOn = 1
private let turnedOff = 2

private let LEFTCHANNEL: Int32 = 0
private let RIGHTCHANNEL: Int32 = 1
private let BOTHCHANNEL: Int32 = 2

//  Plist keys (the ObjC @"..." #define macros are not imported into Swift)
private let kInputName = " Input Name"
private let kInputSource = " Input Source"
private let kInputChannel = " Input Channel"
private let kInputSamplingRate = " Input Sampling Rate"
private let kInputPad = " Input Pad"
private let kInputSlider = " Input Slider"

@objc(ModemSource)
class ModemSource: ModemAudio {

    @IBOutlet var inputMenu: NSPopUpButton?
    @IBOutlet var inputSourceMenu: NSPopUpButton?
    @IBOutlet var inputChannel: NSPopUpButton?
    @IBOutlet var inputSamplingRateMenu: NSPopUpButton?
    @IBOutlet var inputParam: NSTextField?

    @IBOutlet var controlView: NSView?
    @IBOutlet var fileView: NSView?

    @objc weak var delegate: NSObjectProtocol?          //  serves -delegate / -setDelegate:

    var hasReadThread: Bool = false

    //  file input
    var sourcePipe: AIFFSource?
    var periodic: Bool = true
    var soundFileTimer: Timer?
    var playbackSpeed: Int32 = 0

    private func setInterface(_ object: NSControl?, to selector: Selector) {
        object?.action = selector
        object?.target = self
    }

    //  init ModemSource and set the interface controls into the given view.
    @objc(initIntoView:device:fileExtra:playbackSpeed:channel:client:)
    init?(intoView view: NSView?, device name: String, fileExtra extra: NSView?, playbackSpeed speed: Int32, channel ch: Int32, client: CMPipe?) {
        super.init()
        channel = ch
        isInputFlag = true
        delegate = nil
        started = false; hasReadThread = false

        resamplingPipe = ResamplingPipe(samplingRate: 11025.0, channels: 2)  // v0.90 set to 2 channels always
        resamplingPipe?.setInputSamplingRate(11025.0)
        resamplingPipe?.setOutputSamplingRate(11025.0)

        //  insert an AIFFSource between us and the client so AIFF files can be inserted
        //  ( [[AIFFSource alloc] pipeWithClient:client] -> construct then -pipe(withClient:) )
        sourcePipe = AIFFSource()
        sourcePipe?.pipe(withClient: client)
        sourcePipe?.setSamplingRate(Float(CMFs))
        setClient(sourcePipe)

        playbackSpeed = speed
        periodic = true
        soundFileTimer = nil
        deviceState = DISABLED
        dbSlider = nil
        deviceName = name
        if Bundle.main.loadNibNamed("ModemSource", owner: self, topLevelObjects: nil) {

            //  set up connections for super class
            soundCardMenu = inputMenu
            sourceMenu = inputSourceMenu
            samplingRateMenu = inputSamplingRateMenu
            channelMenu = inputChannel
            paramString = inputParam

            // loadNib should have set up controlView connections
            if let view = view, let controlView = controlView { view.addSubview(controlView) }
            if let extra = extra, let fileView = fileView { extra.addSubview(fileView) }
            // actions
            setInterface(inputMenu, to: #selector(inputMenuChanged))
            setInterface(inputSourceMenu, to: #selector(sourceMenuChanged))
            setInterface(inputChannel, to: #selector(channelChanged))
            setInterface(inputSamplingRateMenu, to: #selector(samplingRateChanged))
            if ch > 1 {
                //  stereo, don't show channel selection
                inputChannel?.isHidden = true
            }
            return
        }
        return nil
    }

    @objc(setPeriodic:)
    func setPeriodic(_ state: Bool) {
        periodic = state
        if state == false, let t = soundFileTimer {
            t.invalidate()
            soundFileTimer = nil
        }
    }

    @objc(setFileRepeat:)
    func setFileRepeat(_ doRepeat: Bool) {
        sourcePipe?.setFileRepeat(doRepeat)
    }

    @objc(registerInputPad:)
    func registerInputPad(_ pad: NSTextField?) {
        dbPad = pad
    }

    //  (Private API) called periodically by NSTimer, simulating importData from AudioHubChannel.
    //  submits the next 512 sound samples to the appropriate AudioPipe.
    @objc(nextMonoSoundFileFrame:)
    func nextMonoSoundFileFrame(_ timer: Timer) {
        if outputClient == nil {
            timer.invalidate()
            NSLog("mono output client missing for ModemSource\n")
            return
        }
        let p = timer.userInfo as! ModemSource
        p.data.pointee.samples = 512

        let stride = sourcePipe?.soundFileStride() ?? 0
        //  if file is mono, fetch left (mono) channel even if right channel is requested
        let offset: Int32 = (p.channel != RIGHTCHANNEL /* LEFTCHANNEL or BOTHCHANNEL */ || stride <= 1) ? 0 : 1

        //  the following causes the sourcePipe to export data to this object (importData:)
        if sourcePipe?.insertNextFileFrame(withOffset: offset) == true { timer.invalidate() }
    }

    //  (Private API) submits the next 512 stereo sound samples to the client AudioPipes.
    @objc(nextStereoSoundFileFrame:)
    func nextStereoSoundFileFrame(_ timer: Timer) {
        if outputClient == nil {
            timer.invalidate()
            return
        }
        let p = timer.userInfo as! ModemSource
        p.data.pointee.samples = 512

        if sourcePipe?.insertNextStereoFileFrame() == true { timer.invalidate() }
    }

    //  hasNewData for 11025 samples/second.  Assume samples are BUFLEN (512) in size.
    //  Also change the LRLRLR stream to a LLLL...RRRR stream for stereo channel.
    private func hasNew11025Data(_ inbuf: UnsafeMutablePointer<Float>) {
        //  check if device returns only a single channel
        if channels == 1 {
            //  v0.93 mono channel from ResamplingPipe is copied into split stereo channels
            for i in 0..<512 {
                clientBuffer[i] = inbuf[i]
                clientBuffer[i + 512] = inbuf[i]
            }
        } else {
            //  the base channel is the even channel of a stereo pair of channels.
            //  for a stereo device, baseChannel is 0.
            var p = inbuf + Int(baseChannel)
            //  copy the two channels of data
            for i in 0..<512 {
                clientBuffer[i] = p[0]
                clientBuffer[i + 512] = p[1]
                p += Int(channels)
            }
        }
        //  update our (CMTappedPipe) data source info
        data.pointee.samplingRate = 11025.0
        data.pointee.array = clientBuffer + Int(channel) * 512
        data.pointee.samples = 512
        data.pointee.components = 1
        data.pointee.channels = 1

        sourcePipe?.importData(self, offset: 0)
        tapClient?.importData(self)
    }

    //  used to feed hasNewData of the AudioInput port; blocked waiting for data from
    //  the AudioConverter.
    @objc(readThread:)
    func readThread(_ clientObj: Any?) {
        guard let resamplingPipe = resamplingPipe else {
            hasReadThread = false
            Thread.exit()
            return
        }
        autoreleasepool {
            while resamplingPipe.eof() == false {
                //  NOTE: uses decimation even when input sampling rate is 11025 s/s.
                //  This gives the system more sound card buffering.
                _ = resamplingPipe.readResampledData(resampledBuffer, samples: 512)
                hasNew11025Data(resampledBuffer)
            }
        }
        //  mark so that next time we need a ReadThread, it is recreated
        hasReadThread = false
        Thread.exit()
    }

    //  start input sound card
    override func startSoundCard() -> Bool {
        guard let card = selectedSoundCard else { return false }

        var datasize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = AudioStreamBasicDescription()
        asbd.mChannelsPerFrame = 2
        _ = cm_AudioStreamGetProperty(card.streamID, 0, kAudioDevicePropertyStreamFormat, &datasize, &asbd)
        resamplingPipe?.setNumberOfChannels(Int32(asbd.mChannelsPerFrame))

        datasize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var psbd = AudioStreamBasicDescription()
        psbd.mChannelsPerFrame = 2
        _ = cm_AudioStreamGetProperty(card.streamID, 0, kAudioStreamPropertyPhysicalFormat, &datasize, &psbd)

        //  0.93d don't change channels/bits, but just report it
        paramString?.stringValue = "\(Int32(asbd.mChannelsPerFrame)) ch/\(Int32(psbd.mBitsPerChannel))"

        if isSampling == true { return true }               //  already running

        if audioManager == nil {
            audioManager = (NSApp.delegate as? AppDelegate)?.audioManager()
            if audioManager == nil { return false }
        }
        startStopLock.lock()                                //  wait for any previous start/stop to complete
        if hasReadThread == false {
            //  create read thread only when needed
            Thread.detachNewThreadSelector(#selector(readThread(_:)), toTarget: self, with: self)
            hasReadThread = true
        }
        isSampling = (audioManager?.audioDeviceStart(card.deviceID, modemAudio: self) == 0)
        startStopLock.unlock()
        return (isSampling == true)
    }

    //  stop input sound card
    override func stopSoundCard() -> Bool {
        guard let card = selectedSoundCard else { return false }
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
        //  Switch the resampling pipe to convert data into.
        //  Output (to modem) of ResamplingPipe stays at 11025 s/s.
        resamplingPipe?.setInputSamplingRate(rate)
    }

    //  (Private API)
    private func turnSamplingOn(_ state: Bool) {
        if selectedSoundCard == nil { return }

        if state == true {
            if isSampling == false {
                //  first set sampling rate and source, in case we came here from a different modem interface
                _ = samplingRateChanged()
                _ = sourceMenuChanged()
                _ = startSoundCard()
            }
        } else {
            if isSampling == true { _ = stopSoundCard() }
        }
    }

    private func changeDeviceState(to newState: Int32) {
        var action = doNothing

        switch deviceState {
        case DISABLED:
            if newState == ENABLED {
                deviceState = ENABLED
                if sourcePipe?.soundFileActive() == false && started == true {
                    turnSamplingOn(true)
                    action = turnedOn
                }
            }
        case ENABLED:
            if newState == ENABLED {
                //  normal start/stop sampling (while device is enabled)
                if sourcePipe?.soundFileActive() == false && started == true {
                    turnSamplingOn(true)
                    action = turnedOn
                }
                if started == false {
                    turnSamplingOn(false)
                    action = turnedOff
                }
            } else {
                deviceState = newState
            }
        case RUNNING:
            if sourcePipe?.soundFileActive() == true {
                turnSamplingOn(false)
                action = turnedOff
                break
            }
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
        if deviceState == ENABLED && started == true && sourcePipe?.soundFileActive() == false {
            if action != turnedOn { turnSamplingOn(true) }
            return
        }
        //  added v0.21
        if deviceState == DISABLED && sourcePipe?.soundFileActive() == false {
            if action != turnedOff { turnSamplingOn(false) }
            return
        }
        if deviceState == RUNNING && sourcePipe?.soundFileActive() == true {
            if action != turnedOff { turnSamplingOn(false) }
            return
        }
    }

    @objc(fileSpeedChanged:)
    func fileSpeedChanged(_ newSpeed: Int32) {
        playbackSpeed = newSpeed
    }

    @objc(registerDeviceSlider:)
    func registerDeviceSlider(_ slider: NSSlider?) {
        dbSlider = slider
    }

    //  Note: source level is in dB
    @objc(setDeviceLevel:)
    func setDeviceLevel(_ slider: NSSlider?) {
        dbSlider = slider
        setDeviceLevelFromSlider()
    }

    @objc(setPadLevel:)
    func setPadLevel(_ pad: NSTextField?) {
        dbPad = pad
        setDeviceLevelFromSlider()
    }

    //  (Private API)
    private func startSoundFile(_ filename: String) {
        if sourcePipe?.soundFileActive() == true {
            soundFileStarting(filename)
            data.pointee.array = nil
            data.pointee.samplingRate = sourcePipe?.samplingRate() ?? 0
            data.pointee.components = sourcePipe?.soundFileStride() ?? 0
            data.pointee.channels = 2
            //  assume 512 samples at ( 11025 samples per second * playbackSpeed )
            let t = 512.0 / (Double(data.pointee.samplingRate) * Double(playbackSpeed))

            switch channel {
            case 2:
                soundFileTimer = Timer.scheduledTimer(timeInterval: t, target: self, selector: #selector(nextStereoSoundFileFrame(_:)), userInfo: self, repeats: periodic)
            case LEFTCHANNEL, RIGHTCHANNEL:
                soundFileTimer = Timer.scheduledTimer(timeInterval: t, target: self, selector: #selector(nextMonoSoundFileFrame(_:)), userInfo: self, repeats: periodic)
            default:
                soundFileTimer = Timer.scheduledTimer(timeInterval: t, target: self, selector: #selector(nextMonoSoundFileFrame(_:)), userInfo: self, repeats: periodic)
            }
            if !periodic { soundFileTimer = nil }
        }
    }

    //  get the next sound file frame in 1 ms
    @objc(nextSoundFrame)
    func nextSoundFrame() {
        if !periodic && sourcePipe?.soundFileActive() == true {
            switch channel {
            case 2:
                _ = Timer.scheduledTimer(timeInterval: 0.001, target: self, selector: #selector(nextStereoSoundFileFrame(_:)), userInfo: self, repeats: periodic)
            case LEFTCHANNEL, RIGHTCHANNEL:
                _ = Timer.scheduledTimer(timeInterval: 0.001, target: self, selector: #selector(nextMonoSoundFileFrame(_:)), userInfo: self, repeats: periodic)
            default:
                _ = Timer.scheduledTimer(timeInterval: 0.001, target: self, selector: #selector(nextMonoSoundFileFrame(_:)), userInfo: self, repeats: periodic)
            }
        }
    }

    //  pass pipe to destinations
    @objc(importData:)
    override func importData(_ inPipe: CMPipe!) {
        sourcePipe?.importData(inPipe, offset: channel & 0x1)    // v0.50 multichannel -- map channel to 0 or 1
        tapClient?.importData(inPipe)
    }

    /* local */
    private func stopSoundFile() {
        if let t = soundFileTimer {
            t.invalidate()
            soundFileTimer = nil
        }
        sourcePipe?.stopSoundFile()
        changeDeviceState(to: deviceState)  // update state
        soundFileStopped()
    }

    @objc(startSampling)
    func startSampling() {
        started = true
        changeDeviceState(to: deviceState)  // update state
    }

    @objc(enableInput:)
    func enableInput(_ enable: Bool) {
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

    //  new audio input device selected
    @objc(inputMenuChanged)
    func inputMenuChanged() {
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

    @objc(openFile:)
    func openFile(_ sender: Any?) {
        if soundFileTimer != nil {
            NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
            return
        }
        stopSampling()
        let fileTypes = ["aif", "aiff", "wav"]

        if let path = sourcePipe?.openSoundFile(withTypes: fileTypes) {
            //  if soundFile.active, start the timer-fired sound file data; if not, restart the A/D converter
            if sourcePipe?.soundFileActive() == true {
                startSoundFile(path)
            }
        }
        startSampling()
    }

    @objc(fileRunning)
    func fileRunning() -> Bool {
        return sourcePipe?.soundFileActive() ?? false
    }

    @objc(stopFile:)
    func stopFile(_ sender: Any?) {
        stopSoundFile()
        if soundFileTimer == nil {
            NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
            return
        }
        changeDeviceState(to: deviceState)
    }

    @objc(setupDefaultPreferences:)
    func setupDefaultPreferences(_ pref: Preferences) {
        pref.setString("*", forKey: deviceName + kInputName)
        pref.setString("*", forKey: deviceName + kInputSource)
        pref.setString("11025", forKey: deviceName + kInputSamplingRate)
        pref.setInt(channel, forKey: deviceName + kInputChannel)
        pref.setFloat(0.0, forKey: deviceName + kInputPad)
        pref.setFloat(0.0, forKey: deviceName + kInputSlider)
    }

    //  set up this ModemSource from settings in the Plist
    @objc(updateFromPlist:)
    func updateFromPlist(_ pref: Preferences) -> Bool {
        //  make sure there is at least one usable item
        if (inputMenu?.numberOfItems ?? 0) < 1 { return false }

        var ok = true
        var sourceIndex: Int32 = 0
        //  get input sound card name from Plist
        var name = pref.stringValue(forKey: deviceName + kInputName)

        //  try to select it from the sound card menu
        let selectedDeviceIndex = selectSoundCard(name ?? "")
        if selectedDeviceIndex < 0 {
            //  name in Plist no longer found
            ok = false
            channel = 0
            if (inputMenu?.numberOfItems ?? 0) > 0 { inputMenu?.selectItem(at: 0) }
            if (inputSourceMenu?.numberOfItems ?? 0) > 0 { inputSourceMenu?.selectItem(at: 0) }    // v0.52
        } else {
            //  sound card chosen; -selectSoundCard should also have set up the source menu.
            //  now try to select the input source if there is more than one
            if (inputSourceMenu?.numberOfItems ?? 0) > 1 {
                name = pref.stringValue(forKey: deviceName + kInputSource)
                sourceIndex = selectSource(name ?? "")
                if sourceIndex < 0 {
                    ok = false
                    inputSourceMenu?.selectItem(at: 0)
                }
            }
            //  select channel
            channel = pref.intValue(forKey: deviceName + kInputChannel)
            _ = selectChannel(channel)
        }

        // v0.52 sanity check channel
        let menuItems = inputChannel?.numberOfItems ?? 0
        if channel >= 0 && Int(channel) < menuItems {   // 0.52
            inputChannel?.selectItem(at: Int(channel))  // v0.50 allow multi-channel
        }

        //  setup input pad
        let pad = pref.floatValue(forKey: deviceName + kInputPad)
        if let dbPad = dbPad {
            dbPad.stringValue = "\(Int32(pad))"
            let s = "Updating input pad to \(Int32(pad)) from plist"
            s.withCString { Messages.logMessage($0) }
        }

        let key = deviceName + kInputSlider
        let slider = pref.floatValue(forKey: key)

        if let dbSlider = dbSlider {
            dbSlider.floatValue = slider
            let s = "Updating input attenuator to \(String(format: "%.1f", slider)) from plist"
            s.withCString { Messages.logMessage($0) }
        }
        setDeviceLevelFromSlider()

        if let card = selectedSoundCard {
            if audioManager == nil || audioManager?.audioDevice(forID: card.deviceID) == nil {
                // 0.53a sampling rate option
                if let rateString = pref.stringValue(forKey: deviceName + kInputSamplingRate) {
                    let s = "Updating input sampling rate \(rateString) from plist"     //  v0.62
                    s.withCString { Messages.logMessage($0) }
                    inputSamplingRateMenu?.selectItem(withTitle: rateString)
                }
                _ = samplingRateChanged()           //  v0.62
            }
            fetchSamplingRateFromCoreAudio()        //  v0.78 forces the AudioConverter rates to be set
        }
        return ok
    }

    @objc(retrieveForPlist:)
    func retrieveForPlist(_ pref: Preferences) {
        pref.setString(inputMenu?.titleOfSelectedItem, forKey: deviceName + kInputName)
        pref.setString(inputSourceMenu?.titleOfSelectedItem, forKey: deviceName + kInputSource)
        pref.setInt(channel, forKey: deviceName + kInputChannel)

        if let selectedTitle = inputSamplingRateMenu?.titleOfSelectedItem {
            pref.setString(selectedTitle, forKey: deviceName + kInputSamplingRate)
        }

        //  retrieve pad value from device (AudioInputPort, AudioSoundChannel)
        if let dbPad = dbPad { pref.setFloat(dbPad.floatValue, forKey: deviceName + kInputPad) }
        if let dbSlider = dbSlider { pref.setFloat(dbSlider.floatValue, forKey: deviceName + kInputSlider) }
    }

    //  -delegate / -setDelegate: are the auto-generated accessors of the @objc
    //  `delegate` property declared above.

    // delegate method
    @objc(soundFileStarting:)
    func soundFileStarting(_ filename: String) {
        if let d = delegate, d.responds(to: #selector(soundFileStarting(_:))) {
            _ = d.perform(#selector(soundFileStarting(_:)), with: filename)
        }
    }

    //  delegate method
    @objc(soundFileStopped)
    func soundFileStopped() {
        if let d = delegate, d.responds(to: #selector(soundFileStopped)) {
            _ = d.perform(#selector(soundFileStopped))
        }
    }
}
