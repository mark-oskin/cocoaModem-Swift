//
//  ModemAudio.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 10/19/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of ModemAudio.m / ModemAudio.h.  ModemAudio remains the base of
//  ModemDest and ModemSource (both also Swift now) and a subclass of the (Swift)
//  CMTappedPipe.  Every ivar becomes an internal stored property with its exact
//  original name so the subclasses continue to reach them by name across the
//  module.  AudioManager.swift drives this class through the exact original
//  selectors (inputArrivedFrom:bufferList:, accumulateOutputFor:bufferList:accumulate:,
//  isInput, fetchSourceFromCoreAudio, fetchSamplingRateFromCoreAudio,
//  fetchDeviceLevelFromCoreAudio); those are preserved with @objc(...).
//
//  The pre-10.6 CoreAudio calls (AudioDeviceGetProperty/SetProperty,
//  AudioStreamGetProperty) are unavailable in Swift, so they are reached through
//  the cm_* static-inline shims in AudioManagerTypes.h (same pattern AudioManager
//  uses).  The three fixed float scratch buffers (resampledBuffer[1024],
//  clientBuffer[1024], pipeBuffer[512*2]) are heap UnsafeMutablePointer<Float>
//  allocated at construction and freed in deinit, so the resampling pipe and the
//  CMDataStream keep stable pointers into them.
//
//  NOTE: the original had an ivar named `isInput` *and* a method -isInput.  Swift
//  cannot have both, so the stored property is renamed `isInputFlag` (documented);
//  the -isInput selector (called by AudioManager) is preserved as a method.
//

import Foundation
import Cocoa
import CoreAudio
import AudioToolbox

let BUFLEN: Int32 = 512

//  Was the C struct SoundCardInfo (with an embedded NSString*).  Modeled as a
//  Swift reference type so that `selectedSoundCard` aliasing an `info[i]` entry
//  keeps the exact pointer semantics of the original `SoundCardInfo *selectedSoundCard`.
final class SoundCardInfo {
    var deviceID: AudioDeviceID = 0
    var streamID: AudioStreamID = 0
    var streamIndex: Int32 = 0
    var name: String = ""
}

@objc(ModemAudio)
class ModemAudio: CMTappedPipe {

    //  ---- ivars (exact original names; internal so subclasses reach them) ----
    var info: [SoundCardInfo] = (0..<Int(MAXDEVICES)).map { _ in SoundCardInfo() }
    var selectedSoundCard: SoundCardInfo?
    var soundcards: Int32 = 0                    //  input or output sound cards

    var audioManager: AudioManager?
    var previousDeviceID: AudioDeviceID = 0

    var deviceName: String = ""                  //  unique name for each ModemSource or ModemDest
    var channels: Int32 = 2
    var deviceState: Int32 = 0
    @objc var channel: Int32 = 0
    var baseChannel: Int32 = 0
    var isInputFlag: Bool = true                 //  original ivar `isInput` (renamed; see -isInput)
    var isSampling: Bool = false                 //  set when virtual AudioDeviceStart/AudioDeviceStop is called
    var restartSamplingOnWakeup: Bool = false
    var savedIOProc: AudioDeviceIOProc?
    var started: Bool = false

    //  sampling rate conversion
    var resamplingPipe: ResamplingPipe?
    var resamplingPipeChannels: Int32 = 2
    let resampledBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
    let clientBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
    var previousSamplingRate: Float = 0.0

    //  (used only by ModemDest)  max of 512 x stereo samples
    let pipeBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 512 * 2)

    var startStopLock: NSLock = NSLock()
    var outputMuted: Bool = false

    var deviceBitPair = ChannelBitPair()

    var dbPad: NSTextField?
    var dbSlider: NSSlider?
    var scalarSlider: NSSlider?
    var soundCardMenu: NSPopUpButton?            //  maps to inputMenu or outputMenu
    var sourceMenu: NSPopUpButton?               //  maps to inputSourceMenu or outputDestMenu
    var samplingRateMenu: NSPopUpButton?         //  maps to inputSamplingRateMenu or outputSamplingRateMenu
    var channelMenu: NSPopUpButton?              //  maps to inputChannel or outputChannel
    var paramString: NSTextField?                //  maps to inputParam or outputParam

    var nonOOKLevel: Float = 0.95                //  v0.85
    var currentLevel: Float = 0.0                //  v0.85
    var currentDB: Float = 0.0                   //  v0.88d
    var dBmin: Float = 0.0
    var dBmax: Float = 0.0                        //  c0.88d

    private let kLeftChannel: UInt32 = 1
    private let kRightChannel: UInt32 = 2
    private let ookLevel: Float = 0.9

    override init() {
        super.init()
        audioManager = (NSApp.delegate as? AppDelegate)?.audioManager()
        isInputFlag = true
        channels = 2                                    // 1 for mono devices
        channel = 0                                     // left
        isSampling = false; restartSamplingOnWakeup = false; started = false
        savedIOProc = nil
        selectedSoundCard = nil
        previousDeviceID = 0
        previousSamplingRate = 0.0
        dbSlider = nil; scalarSlider = nil
        nonOOKLevel = 0.95
        dbPad = nil
        currentDB = 0; dBmin = 0; dBmax = 0             //  v0.88d
        for s in info {
            s.streamID = 0
            s.deviceID = 0
        }
        resamplingPipeChannels = 2
        startStopLock = NSLock()
    }

    deinit {
        resampledBuffer.deallocate()
        clientBuffer.deallocate()
        pipeBuffer.deallocate()
    }


    @objc(isInput) func isInput() -> Bool {
        return isInputFlag
    }

    //  subclass (ModemSource or ModemDest) should override this
    @objc(deviceHasChanged:deviceID:)
    func deviceHasChanged(_ code: Int16, deviceID inDeviceID: AudioDeviceID) {
    }

    //  return number of devices found (limited by maxdev), filling `info`
    private func discoverSoundCards(maxdev: Int32) -> Int32 {
        var count = 0
        var list = [AudioDeviceID](repeating: 0, count: Int(MAXDEVICES))
        let devices = Int(enumerateAudioDevices(&list, Int32(MAXDEVICES)))
        var stream = [AudioStreamID](repeating: 0, count: 16)

        for i in 0..<devices {
            let device = list[i]
            //  check if device responds to a CFName call
            var datasize: UInt32 = 0
            var status = cm_AudioDeviceGetPropertyInfo(device, 0, false, kAudioObjectPropertyName, &datasize)
            var name = ""
            if status == 0 && datasize != 0 {
                var cfname: Unmanaged<CFString>?
                datasize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                status = cm_AudioDeviceGetProperty(device, 0, false, kAudioObjectPropertyName, &datasize, &cfname)
                if let cf = cfname { name = cf.takeRetainedValue() as String }
            } else {
                //  use old Cstring call (RME FireFace 400), convert to NSString (ISO Latin-1)
                var cname = [CChar](repeating: 0, count: 129)
                datasize = 128
                status = cm_AudioDeviceGetProperty(device, 0, false, kAudioDevicePropertyDeviceName, &datasize, &cname)
                name = String(cString: cname)
            }

            //  check for number of streams for device
            datasize = 0
            _ = cm_AudioDeviceGetPropertyInfo(device, 0, isInputFlag, kAudioDevicePropertyStreams, &datasize)
            _ = cm_AudioDeviceGetProperty(device, 0, isInputFlag, kAudioDevicePropertyStreams, &datasize, &stream)
            let streams = Int(datasize) / MemoryLayout<AudioStreamID>.size
            if streams > 0 {
                for j in 0..<streams {
                    if count < Int(maxdev) {
                        let s = info[count]
                        s.streamIndex = Int32(j)
                        s.deviceID = device
                        s.streamID = stream[j]
                        s.name = name
                        count += 1
                    }
                }
            }
        }
        //  now modify names for devices with the same name and device with multiple streams
        if count > 1 {
            for i in 0..<(count - 1) {
                let d = info[i]
                //  modify devices that have the same name
                for j in (i + 1)..<count {
                    let e = info[j]
                    if d.name == e.name {
                        var n = 1
                        let refname = d.name
                        //  shorten name if possible
                        var newName = d.name
                        if let r = newName.range(of: "(") {
                            newName = String(newName[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                        }
                        //  change duplicate names to "name (1)", "name (2)" etc.
                        for k in i..<count {
                            let e2 = info[k]
                            if refname == e2.name {
                                e2.name = "\(newName) (\(n))"
                                n += 1
                            }
                        }
                        break
                    }
                }
            }
        }
        return Int32(count)
    }

    //  (Private API) set menu with names in deviceList
    private func setMenu(to deviceList: [SoundCardInfo], menu: NSPopUpButton?) {
        menu?.removeAllItems()
        if soundcards == 0 {
            menu?.addItem(withTitle: "")
            menu?.isEnabled = false
            return
        }
        menu?.isEnabled = true
        var j = 0
        for i in 0..<Int(soundcards) {
            menu?.addItem(withTitle: deviceList[i].name)
            let n = menu?.numberOfItems ?? 0
            if n > j {
                //  ignore repeated names (NSPopUpButton cannot handle it)
                if let item = menu?.item(at: j) {
                    item.tag = i                        // set tag to menu index
                }
                j += 1
            }
        }
    }

    //  return index of source menu if successful, -1 if not successful
    @objc(sourceMenuChanged)
    func sourceMenuChanged() -> Int32 {
        let index = Int32(sourceMenu?.indexOfSelectedItem ?? -1)
        if index < 0 || selectedSoundCard == nil { return -1 }

        //  don't set source if there is only one (tag would not exist)
        if (sourceMenu?.numberOfItems ?? 0) <= 1 { return 0 }

        //  NOTE: datasource was saved in the source menu by -updateSourceMenu
        guard let item = sourceMenu?.item(at: Int(index)) else { return -1 }
        var dataSource = UInt32(item.tag)
        let datasize = UInt32(MemoryLayout<UInt32>.size)
        let status = cm_AudioDeviceSetProperty(selectedSoundCard!.deviceID, 0, isInputFlag, kAudioDevicePropertyDataSource, datasize, &dataSource)
        if status != 0 {
            NSLog("cannot set sound card source/destination? %d", Int32(dataSource))
            return -1
        }
        return index
    }

    //  switch source to the one with the name passed in
    @objc(selectSource:)
    func selectSource(_ name: String) -> Int32 {
        sourceMenu?.selectItem(withTitle: name)
        return sourceMenuChanged()                      //  try switching Core Audio to it
    }

    //  update source menu from CoreAudio, select the default source
    @objc(updateSourceMenu)
    func updateSourceMenu() -> Int32 {
        let index = soundCardMenu?.indexOfSelectedItem ?? -1
        sourceMenu?.removeAllItems()

        if index < 0 {
            sourceMenu?.addItem(withTitle: "Default")
            sourceMenu?.isEnabled = false
            return 0
        }
        sourceMenu?.isEnabled = true
        let devID = info[Int(index)].deviceID

        // get sources (up to 16)
        var dataSource = [UInt32](repeating: 0, count: 16)
        var datasize = UInt32(16 * MemoryLayout<UInt32>.size)
        var status = cm_AudioDeviceGetProperty(devID, 0, isInputFlag, kAudioDevicePropertyDataSources, &datasize, &dataSource)
        let sources = Int(datasize) / MemoryLayout<UInt32>.size

        if status != 0 || sources < 0 {
            sourceMenu?.addItem(withTitle: "Default")
            sourceMenu?.isEnabled = false
            return 0
        }
        //  set up default sourceID
        var defaultIndex = 0
        var defaultSourceID: UInt32 = 0
        datasize = UInt32(MemoryLayout<UInt32>.size)
        status = cm_AudioDeviceGetProperty(devID, 0, isInputFlag, kAudioDevicePropertyDataSource, &datasize, &defaultSourceID)

        if status != 0 {
            sourceMenu?.addItem(withTitle: "Default")
            sourceMenu?.isEnabled = false
            return 0
        }

        for i in 0..<sources {
            //  find the source with the name that is passed in
            var srcID = dataSource[i]
            var cfname: Unmanaged<CFString>?
            withUnsafeMutablePointer(to: &srcID) { inPtr in
                withUnsafeMutablePointer(to: &cfname) { outPtr in
                    //  AudioValueTranslation's members are non-optional raw
                    //  pointers, so build it in-place with the live pointers.
                    var transl = AudioValueTranslation(
                        mInputData: UnsafeMutableRawPointer(inPtr),
                        mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                        mOutputData: UnsafeMutableRawPointer(outPtr),
                        mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                    var ds = UInt32(MemoryLayout<AudioValueTranslation>.size)
                    let st = cm_AudioDeviceGetProperty(devID, 0, isInputFlag, kAudioDevicePropertyDataSourceNameForIDCFString, &ds, &transl)  //  v0.70 Kanji name
                    if st == 0 && ds == UInt32(MemoryLayout<AudioValueTranslation>.size) {
                        //  read through outPtr, not `cfname`, which is exclusively
                        //  borrowed by this withUnsafeMutablePointer(to:&cfname).
                        if let cf = outPtr.pointee {
                            sourceMenu?.addItem(withTitle: cf.takeRetainedValue() as String)
                            if let item = sourceMenu?.item(at: i) { item.tag = Int(dataSource[i]) }
                            if dataSource[i] == defaultSourceID { defaultIndex = i }
                        }
                    }
                }
            }
        }

        //  default microKEYER II to external line input
        if soundCardMenu?.titleOfSelectedItem == "microHAM CODEC" { defaultIndex = 1 }

        //  select menu item corresponding to the default sourceID
        sourceMenu?.selectItem(at: defaultIndex)
        _ = sourceMenuChanged()

        return Int32(defaultIndex)
    }

    //  possibly some other app has changed the source -- track it with our source menu
    @objc(fetchSourceFromCoreAudio)
    func fetchSourceFromCoreAudio() {
        guard let card = selectedSoundCard else { return }

        var sourceID: UInt32 = 0
        var datasize = UInt32(MemoryLayout<UInt32>.size)
        let status = cm_AudioDeviceGetProperty(card.deviceID, 0, isInputFlag, kAudioDevicePropertyDataSource, &datasize, &sourceID)
        if status != 0 { return }

        //  check if sourceMenu is already correct
        if let item = sourceMenu?.selectedItem, UInt32(item.tag) == sourceID { return }

        let sources = sourceMenu?.numberOfItems ?? 0
        for i in 0..<sources {
            if let item = sourceMenu?.item(at: i), sourceID == UInt32(item.tag) {
                sourceMenu?.selectItem(at: i)
                return
            }
        }
    }

    @objc(samplingRateChanged)
    func samplingRateChanged() -> Bool {
        guard let card = selectedSoundCard else { return false }

        let rateIndex = samplingRateMenu?.indexOfSelectedItem ?? -1
        if rateIndex < 0 { return false }

        var datasize = UInt32(MemoryLayout<Float64>.size)
        var rate = Float64((samplingRateMenu?.titleOfSelectedItem as NSString?)?.intValue ?? 0)

        //  v0.78b setting sampling rate is slow, so getProperty first to see if we really need to change it.
        var currentRate: Float64 = 0
        var status = cm_AudioDeviceGetProperty(card.deviceID, 0, isInputFlag, kAudioDevicePropertyNominalSampleRate, &datasize, &currentRate)
        if status == 0 && rate == currentRate { return true }

        datasize = UInt32(MemoryLayout<Float64>.size)
        status = cm_AudioDeviceSetProperty(card.deviceID, 0, isInputFlag, kAudioDevicePropertyNominalSampleRate, datasize, &rate)

        return (status == 0)
    }

    //  (Private API) Find available sampling rate ranges and check against the 6 rates we allow.
    private func updateSamplingRateMenu() {
        samplingRateMenu?.removeAllItems()
        guard let card = selectedSoundCard else { return }

        var datasize: UInt32 = 0
        var status = cm_AudioDeviceGetPropertyInfo(card.deviceID, 0, isInputFlag, kAudioDevicePropertyAvailableNominalSampleRates, &datasize)
        if status == 0 && datasize != 0 {
            if Int(datasize) > MemoryLayout<AudioValueRange>.size * 64 { datasize = UInt32(MemoryLayout<AudioValueRange>.size * 64) }
            var range = [AudioValueRange](repeating: AudioValueRange(), count: 64)
            status = cm_AudioDeviceGetProperty(card.deviceID, 0, isInputFlag, kAudioDevicePropertyAvailableNominalSampleRates, &datasize, &range)
            if status == 0 {
                let sampleRanges = Int(datasize) / MemoryLayout<AudioValueRange>.size
                if sampleRanges > 0 {
                    var usable = [Bool](repeating: false, count: 6)
                    for i in 0..<sampleRanges {
                        let low = Float(range[i].mMinimum), high = Float(range[i].mMaximum)
                        for j in 0..<6 {
                            if low <= Float(selectableSampleRate[j]) && high >= Float(selectableSampleRate[j]) { usable[j] = true }
                        }
                    }
                    var defaultIndex = 0
                    var currentIndex = 0
                    for j in 0..<6 {
                        if usable[j] {
                            if j == 1 { defaultIndex = currentIndex }
                            samplingRateMenu?.addItem(withTitle: "\(selectableSampleRate[j])")
                            currentIndex += 1
                        }
                    }
                    samplingRateMenu?.selectItem(at: defaultIndex)
                    return
                }
            }
        }
        //  add a single 44100 s/s rate if there are errors
        samplingRateMenu?.addItem(withTitle: "44100")
        samplingRateMenu?.selectItem(at: 0)
    }

    //  override this to accept sample rate changes
    @objc(actualSamplingRateSetTo:)
    func actualSamplingRateSet(to rate: Float) {
        NSLog("subclass need to implement -actualSamplingRateSetTo")
    }

    @objc(updateChannelMenu)
    func updateChannelMenu() {
        channelMenu?.removeAllItems()

        let index = soundCardMenu?.indexOfSelectedItem ?? -1
        if index < 0 || Int32(bitPattern: info[Int(index)].streamID) <= 0 {
            channelMenu?.addItem(withTitle: "")
            channelMenu?.selectItem(at: 0)
            channelMenu?.isHidden = true
            paramString?.stringValue = ""
            return
        }
        var devParams = DevParams()
        getDeviceParams(Int32(bitPattern: info[Int(index)].streamID), isInputFlag, &devParams)

        //  find best channels/depth (more channels are better)
        deviceBitPair.channels = 0; deviceBitPair.bits = 0
        withUnsafePointer(to: &devParams.channelBitPair) { tuplePtr in
            let cbp = UnsafeRawPointer(tuplePtr).assumingMemoryBound(to: ChannelBitPair.self)
            for i in 0..<Int(devParams.bitPairs) {
                let bitpair = cbp[i]
                if bitpair.channels > deviceBitPair.channels {
                    //  bitpair with more channels found
                    deviceBitPair = bitpair
                } else if bitpair.channels == deviceBitPair.channels {
                    //  equal number of channels, chose the one with more bits
                    if bitpair.bits > deviceBitPair.bits {
                        deviceBitPair = bitpair
                    }
                }
            }
        }
        paramString?.stringValue = "\(deviceBitPair.channels) ch/\(deviceBitPair.bits)"

        if deviceBitPair.channels <= 1 {
            channelMenu?.addItem(withTitle: "")
            channelMenu?.isEnabled = false
        } else {
            channelMenu?.isEnabled = true
            if deviceBitPair.channels == 2 {
                //  stereo
                channelMenu?.addItem(withTitle: "L")
                channelMenu?.addItem(withTitle: "R")
            } else {
                //  multichannel
                for i in 0..<Int(deviceBitPair.channels) {
                    channelMenu?.addItem(withTitle: "\(i + 1)")
                }
            }
            channel = 0; baseChannel = 0
            channelMenu?.selectItem(at: Int(channel))
        }
    }

    //  Note: for stereo 0 = left, 1 = right; multichannel 0 = first channel, etc.
    @objc(channelChanged)
    func channelChanged() -> Int32 {
        var index = Int32(channelMenu?.indexOfSelectedItem ?? -1)
        if index < 0 { index = 0 }
        channel = index

        //  assume channel 2 of a 3-channel menu to be a stereo channel (not currently used)
        if channel == 2 && (channelMenu?.numberOfItems ?? 0) == 3 { channel = 0; index = 0 }

        //  baseChannel is the lower of the two channels being received.
        baseChannel = channel & 0xfffe

        //  now adjust level
        setDeviceLevelFromSlider()

        return index
    }

    @objc(selectChannel:)
    func selectChannel(_ channelIndex: Int32) -> Int32 {
        channelMenu?.selectItem(at: Int(channelIndex))
        return channelChanged()
    }

    private func samplingRate(forDeviceID devID: AudioDeviceID) -> Float {
        guard let card = selectedSoundCard else { return 0.0 }
        var rate: Float64 = 0
        var datasize = UInt32(MemoryLayout<Float64>.size)
        let status = cm_AudioDeviceGetProperty(card.deviceID, 0, isInputFlag, kAudioDevicePropertyNominalSampleRate, &datasize, &rate)
        if status != 0 { return 0.0 }
        return Float(rate)
    }

    //  possibly some other app has changed the sampling rate -- track it
    @objc(fetchSamplingRateFromCoreAudio)
    func fetchSamplingRateFromCoreAudio() {
        guard let card = selectedSoundCard else { return }

        let rate = samplingRate(forDeviceID: card.deviceID)
        if rate < 7990.0 { return }

        //  check if we already agree with system (system sends two 'nsrt')
        if abs(previousSamplingRate - rate) < 10.0 { return }

        let nRate = Int32(rate)
        previousSamplingRate = Float(nRate)

        samplingRateMenu?.selectItem(withTitle: "\(nRate)")
        actualSamplingRateSet(to: rate)
    }

    @objc(getDBRange:)
    func getDBRange(_ dbRange: UnsafeMutablePointer<AudioValueRange>) -> Bool {
        guard let card = selectedSoundCard else { return false }

        var datasize = UInt32(MemoryLayout<AudioValueRange>.size)
        var status = cm_AudioDeviceGetProperty(card.deviceID, UInt32(channel) + kLeftChannel, isInputFlag, kAudioDevicePropertyVolumeRangeDecibels, &datasize, dbRange)

        if status != noErr {
            //  check master channel if stereo channel did not work
            datasize = UInt32(MemoryLayout<AudioValueRange>.size)
            status = cm_AudioDeviceGetProperty(card.deviceID, 0, isInputFlag, kAudioDevicePropertyVolumeRangeDecibels, &datasize, dbRange)
        }
        dBmin = Float(dbRange.pointee.mMinimum)
        dBmax = Float(dbRange.pointee.mMaximum)
        return (status == noErr)
    }

    //  fetch dB value and dB range to set slider
    @objc(fetchDeviceLevelFromCoreAudio)
    func fetchDeviceLevelFromCoreAudio() {
        guard let card = selectedSoundCard else { return }
        var db: Float32 = 0
        var status: OSStatus

        if dbSlider != nil {
            var datasize = UInt32(MemoryLayout<Float32>.size)
            status = cm_AudioDeviceGetProperty(card.deviceID, UInt32(channel) + kLeftChannel, isInputFlag, kAudioDevicePropertyVolumeDecibels, &datasize, &db)
            if status != noErr {
                datasize = UInt32(MemoryLayout<Float32>.size)
                status = cm_AudioDeviceGetProperty(card.deviceID, 0, isInputFlag, kAudioDevicePropertyVolumeDecibels, &datasize, &db)
            }
            var range = AudioValueRange()
            if status == noErr && getDBRange(&range) == true {
                db = db - Float32(range.mMaximum)
                if let dbPad = dbPad {
                    db += dbPad.floatValue
                    if db > 0 { db = 0 }
                }
                dbSlider?.floatValue = db
            }
        }
        if scalarSlider != nil {
            var datasize = UInt32(MemoryLayout<Float32>.size)
            status = cm_AudioDeviceGetProperty(card.deviceID, UInt32(channel) + kLeftChannel, isInputFlag, kAudioDevicePropertyVolumeScalar, &datasize, &db)
            if status != noErr {
                datasize = UInt32(MemoryLayout<Float32>.size)
                status = cm_AudioDeviceGetProperty(card.deviceID, 0, isInputFlag, kAudioDevicePropertyVolumeScalar, &datasize, &db)
            }
            if status == noErr {
                scalarSlider?.floatValue = db
            }
        }
    }

    //  (Private API)
    private func setScalarAudioLevel(_ value: Float) -> OSStatus {
        let scalar: Float32 = value
        currentLevel = value
        guard let card = selectedSoundCard else { return noErr }

        var s = scalar
        let datasize = UInt32(MemoryLayout<Float32>.size)
        var status: OSStatus = noErr
        //  try setting individual channel(s) first
        if channels == 2 {
            status = cm_AudioDeviceSetProperty(card.deviceID, kLeftChannel, isInputFlag, kAudioDevicePropertyVolumeScalar, datasize, &s)
            status = cm_AudioDeviceSetProperty(card.deviceID, kRightChannel, isInputFlag, kAudioDevicePropertyVolumeScalar, datasize, &s)
        } else {
            status = cm_AudioDeviceSetProperty(card.deviceID, UInt32(channel) + kLeftChannel, isInputFlag, kAudioDevicePropertyVolumeScalar, datasize, &s)
        }
        if status != noErr {
            //  try master control if individual channel does not work
            status = cm_AudioDeviceSetProperty(card.deviceID, 0, isInputFlag, kAudioDevicePropertyVolumeScalar, datasize, &s)
        }
        return status
    }

    //  v0.85
    @objc(setOOKDeviceLevel)
    func setOOKDeviceLevel() {
        if abs(currentLevel - ookLevel) < 0.0001 { return }
        _ = setScalarAudioLevel(ookLevel)
    }

    @objc(validateDeviceLevel)
    func validateDeviceLevel() -> Float {
        if abs(currentLevel - nonOOKLevel) < 0.0001 { return nonOOKLevel }
        _ = setScalarAudioLevel(nonOOKLevel)
        return nonOOKLevel
    }

    // v0.88d
    @objc(changeDeviceGain:)
    func changeDeviceGain(_ direction: Int32) {
        // direction +ve -> increase gain
        guard let card = selectedSoundCard else { return }
        if dBmin == dBmax { return }

        var dB: Float32 = currentDB + (Float(direction) * 0.5)
        if dB >= dBmax || dB <= dBmin { return }
        currentDB = dB

        let datasize = UInt32(MemoryLayout<Float32>.size)
        var status: OSStatus
        //  try setting individual channel(s) first
        if channels == 2 {
            status = cm_AudioDeviceSetProperty(card.deviceID, kLeftChannel, isInputFlag, kAudioDevicePropertyVolumeDecibels, datasize, &dB)
            if status == noErr { status = cm_AudioDeviceSetProperty(card.deviceID, kRightChannel, isInputFlag, kAudioDevicePropertyVolumeDecibels, datasize, &dB) }
        } else {
            status = cm_AudioDeviceSetProperty(card.deviceID, UInt32(channel) + kLeftChannel, isInputFlag, kAudioDevicePropertyVolumeDecibels, datasize, &dB)
        }
        if status != noErr {
            status = cm_AudioDeviceSetProperty(card.deviceID, 0, isInputFlag, kAudioDevicePropertyVolumeDecibels, datasize, &dB)
        }
    }

    //  Set level from either the dBSlider or the scalarSlider (scalar: 0 = min, 1 = max)
    @objc(setDeviceLevelFromSlider)
    func setDeviceLevelFromSlider() {
        guard let card = selectedSoundCard, (dbSlider != nil || scalarSlider != nil) else { return }

        //  first check range
        var range = AudioValueRange()
        if getDBRange(&range) == false || (range.mMaximum - range.mMinimum) < 0.1 {
            if let dbSlider = dbSlider {
                dbSlider.isEnabled = false
                dbSlider.floatValue = 0.0
            }
            if let scalarSlider = scalarSlider {
                scalarSlider.isEnabled = false
                scalarSlider.floatValue = 1.0
            }
        }
        //  round pad to an int
        if let dbPad = dbPad {
            var idb = Int32(dbPad.floatValue + 0.1)
            if idb < 0 { idb = 0 }
            dbPad.intValue = idb
        }

        if let dbSlider = dbSlider {
            var db: Float32 = Float32(range.mMaximum) + dbSlider.floatValue
            if let dbPad = dbPad { db -= Float32(dbPad.intValue) }
            if db < Float32(range.mMinimum) { db = Float32(range.mMinimum) }

            currentDB = db
            dBmin = Float(range.mMinimum)
            dBmax = Float(range.mMaximum)

            let datasize = UInt32(MemoryLayout<Float32>.size)
            var status: OSStatus
            //  try setting individual channel(s) first
            if channels == 2 {
                status = cm_AudioDeviceSetProperty(card.deviceID, kLeftChannel, isInputFlag, kAudioDevicePropertyVolumeDecibels, datasize, &db)
                if status == noErr { status = cm_AudioDeviceSetProperty(card.deviceID, kRightChannel, isInputFlag, kAudioDevicePropertyVolumeDecibels, datasize, &db) }
            } else {
                status = cm_AudioDeviceSetProperty(card.deviceID, UInt32(channel) + kLeftChannel, isInputFlag, kAudioDevicePropertyVolumeDecibels, datasize, &db)
            }
            if status != noErr {
                status = cm_AudioDeviceSetProperty(card.deviceID, 0, isInputFlag, kAudioDevicePropertyVolumeDecibels, datasize, &db)
            }
            //  if already minimum, Core Audio will not call us back if set again to minimum
            if db <= Float32(range.mMinimum) { fetchDeviceLevelFromCoreAudio() }

            dbSlider.isEnabled = (status == noErr)
        }

        if let scalarSlider = scalarSlider {
            var scalar = scalarSlider.floatValue
            if scalar < 0 { scalar = 0 } else if scalar > 1 { scalar = 1 }

            nonOOKLevel = scalar                                    //  v0.85
            let status = setScalarAudioLevel(nonOOKLevel)           //  v0.85
            scalarSlider.isEnabled = (status == noErr)
        }
    }

    @objc(registerLevelSlider:isScalar:)
    func registerLevelSlider(_ slider: NSSlider?, isScalar useScalar: Bool) {
        if useScalar { scalarSlider = slider } else { dbSlider = slider }
    }

    //  update sound card menu from CoreAudio (returns menu index (0 always))
    @objc(updateSoundCardMenu)
    func updateSoundCardMenu() -> Int32 {
        soundcards = discoverSoundCards(maxdev: Int32(MAXDEVICES))
        soundCardMenu?.removeAllItems()
        if soundcards <= 0 {
            soundCardMenu?.addItem(withTitle: "Default")
            soundCardMenu?.isEnabled = false
            return 0
        }
        setMenu(to: info, menu: soundCardMenu)
        soundCardMenu?.isEnabled = true
        soundCardMenu?.selectItem(at: 0)
        return 0
    }

    //  select sound card pointed to by sound card menu
    @objc(soundCardChanged)
    func soundCardChanged() -> Int32 {
        let selectedDevice = soundCardMenu?.indexOfSelectedItem ?? -1
        if selectedDevice < 0 {
            selectedSoundCard = nil
            return -1
        }

        //  refresh source menu, sampling rate menu and ask audioManager to act as listener
        selectedSoundCard = info[Int(selectedDevice)]

        //  v0.78b
        if let card = selectedSoundCard, previousDeviceID != card.deviceID {
            if previousDeviceID != 0 {
                //  unregister old self...
                audioManager?.audioDeviceUnregister(previousDeviceID, modemAudio: self)
            }
            //  ...and replace with new DeviceID
            audioManager?.audioDeviceRegister(card.deviceID, modemAudio: self)
            previousDeviceID = card.deviceID
        }

        //  update source menu with this selected sound card
        _ = updateSourceMenu()
        //  ...update sampling rate menu
        updateSamplingRateMenu()
        //  ...L/R channel and bit depth
        updateChannelMenu()
        //  ... set dB slider
        setDeviceLevelFromSlider()
        //  ... clear dB pad value
        dbPad?.intValue = 0

        //  switch to actual sampling rate
        fetchSamplingRateFromCoreAudio()

        return Int32(selectedDevice)
    }

    //  return index of selected sound card menu item, or -1 if not found
    @objc(selectSoundCard:)
    func selectSoundCard(_ name: String) -> Int32 {
        if soundCardMenu == nil || (soundCardMenu?.numberOfItems ?? 0) < 1 { return -1 }
        soundCardMenu?.selectItem(withTitle: name)
        return soundCardChanged()
    }

    @objc(setupSoundCards)
    func setupSoundCards() {
        _ = updateSoundCardMenu()
        _ = updateSourceMenu()
        updateSamplingRateMenu()
        updateChannelMenu()
    }

    //  start data sampling -- override by ModemSource or ModemDest
    @objc(startSoundCard)
    func startSoundCard() -> Bool {
        return false
    }

    //  stop data sampling -- override by ModemSource or ModemDest
    @objc(stopSoundCard)
    func stopSoundCard() -> Bool {
        return false
    }

    @objc(applicationTerminating)
    func applicationTerminating() {
    }

    @objc(needData:samples:channels:)
    func needData(_ outbuf: UnsafeMutablePointer<Float>, samples n: Int32, channels ch: Int32) -> Int32 {
        NSLog("ModemAudio: needData called?? should be handled by ModemDest")
        return 0
    }

    @objc(inputArrivedFrom:bufferList:)
    func inputArrived(from device: AudioDeviceID, bufferList input: UnsafePointer<AudioBufferList>) {
        guard resamplingPipe != nil, let card = selectedSoundCard else { return }

        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var streamIndex = Int(card.streamIndex)
        if streamIndex >= abl.count { streamIndex = 0 }
        let audiobuffer = abl[streamIndex]
        //  setup number of channels
        channels = Int32(audiobuffer.mNumberChannels)
        //  write bytes into data pipe (note: 512 stereo samples is 4096 bytes)
        let samples = Int32(audiobuffer.mDataByteSize) / (Int32(MemoryLayout<Float>.size) * Int32(audiobuffer.mNumberChannels))
        if (samples % 256) != 0 {
            let s = "Device input received \(samples) samples; should be a multiple of 256"
            s.withCString { Messages.logMessage($0) }
        }
        if let mData = audiobuffer.mData {
            _ = resamplingPipe?.write(mData.assumingMemoryBound(to: Float.self), samples: samples)
        }
    }

    @objc(accumulateOutputFor:bufferList:accumulate:)
    func accumulateOutput(for device: AudioDeviceID, bufferList output: UnsafePointer<AudioBufferList>, accumulate: Bool) {
        if outputMuted { return }
        guard let card = selectedSoundCard else { return }

        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: output))
        var streamIndex = Int(card.streamIndex)
        if streamIndex >= abl.count { streamIndex = 0 }             // sanity check
        let audiobuffer = abl[streamIndex]

        //  setup number of channels
        let deviceChannels = Int32(audiobuffer.mNumberChannels)
        channels = deviceChannels
        let pipeChannels = resamplingPipeChannels

        guard let rawData = audiobuffer.mData else { return }
        var mdata = rawData.assumingMemoryBound(to: Float.self)
        let samples = Int32(audiobuffer.mDataByteSize) / deviceChannels / Int32(MemoryLayout<Float>.size)

        if deviceChannels != pipeChannels {
            _ = resamplingPipe?.readResampledData(pipeBuffer, samples: samples)

            memset(rawData, 0, Int(audiobuffer.mDataByteSize))      //  first clear all of destination buffer
            mdata = mdata + Int(baseChannel + channel)

            var pbuf = pipeBuffer
            if accumulate {
                if pipeChannels == 1 {
                    //  mono pipe in multichannel device
                    for i in 0..<Int(samples) {
                        let v = pbuf[i]
                        mdata[0] += v                               //  v0.85 write into only one channel
                        mdata += Int(deviceChannels)
                    }
                } else {
                    if deviceChannels >= 2 {
                        //  stereo pipe in multichannel device
                        for _ in 0..<Int(samples) {
                            mdata[0] += pbuf[0]
                            mdata[1] += pbuf[1]
                            mdata += Int(deviceChannels)
                            pbuf += 2
                        }
                    } else {
                        //  stereo pipe in single channel device, mix to output
                        for _ in 0..<Int(samples) {
                            mdata[0] += (pbuf[0] + pbuf[1]) * 0.5
                            mdata += 1
                            pbuf += 2
                        }
                    }
                }
            } else {
                if pipeChannels == 1 {
                    //  mono pipe in multichannel device
                    for i in 0..<Int(samples) {
                        let v = pbuf[i]
                        mdata[0] = v                                //  v0.85 write into only one channel
                        mdata += Int(deviceChannels)
                    }
                } else {
                    if deviceChannels >= 2 {
                        //  stereo pipe in multichannel device
                        for _ in 0..<Int(samples) {
                            mdata[0] = pbuf[0]
                            mdata[1] = pbuf[1]
                            mdata += Int(deviceChannels)
                            pbuf += 2
                        }
                    } else {
                        //  stereo pipe in single channel device, mix to output
                        for _ in 0..<Int(samples) {
                            mdata[0] = (pbuf[0] + pbuf[1]) * 0.5
                            mdata += 1
                            pbuf += 2
                        }
                    }
                }
            }
        } else {
            //  pipe and device has the same number of channels
            _ = resamplingPipe?.readResampledData(mdata, samples: samples)
        }
    }
}

private let selectableSampleRate: [Int32] = [11025, 16000, 32000, 44100, 48000, 96000]
