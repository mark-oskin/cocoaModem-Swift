//  Swift port of audioutils.c
//
//  audioutils.c
//  Sound
//
//  Created by kchen on Thu Jun 20 2002.
//  Copyright (c) 2002, 2003, 2004 W7AY. All rights reserved.
//
//  This file uses the (Carbon-era) CoreAudio HAL property API.  Those symbols
//  were deprecated before macOS 10.6 and Apple marks them *unavailable* to
//  Swift, so they cannot be called through the normal CoreAudio import.
//
//  Where the project already provides a `cm_*` static-inline C shim
//  (AudioManagerTypes.h) it is reused here — that is the codebase's chosen way to
//  reach the pre-10.6 HAL from Swift.  Three functions this file needs have no
//  shim yet — AudioHardwareGetProperty, AudioStreamGetPropertyInfo and
//  AudioStreamSetProperty — so they are reached through @_silgen_name thunks that
//  reproduce the exact C prototypes.  (If preferred, add matching cm_* shims to
//  AudioManagerTypes.h and swap the three thunks for them.)  Behaviour is
//  identical to the original C either way.
//
//  The struct/typedef types used below (DevParams, ChannelBitPair, MinMax,
//  AudioStreamExtendedDescription, AudioStreamInfo, AudioDeviceInfo) live in the
//  staying header AudioDeviceTypes.h and are referenced as-is.

import Foundation
import CoreAudio

//  MARK: - Pre-10.6 HAL entry points with no cm_* shim (unavailable in Swift; reached by symbol)

@discardableResult
@_silgen_name("AudioHardwareGetProperty")
private func _AudioHardwareGetProperty(_ inPropertyID: AudioHardwarePropertyID,
                                       _ ioPropertyDataSize: UnsafeMutablePointer<UInt32>?,
                                       _ outPropertyData: UnsafeMutableRawPointer?) -> OSStatus

@discardableResult
@_silgen_name("AudioStreamGetPropertyInfo")
private func _AudioStreamGetPropertyInfo(_ inStream: AudioStreamID,
                                         _ inChannel: UInt32,
                                         _ inPropertyID: AudioDevicePropertyID,
                                         _ outSize: UnsafeMutablePointer<UInt32>?,
                                         _ outWritable: UnsafeMutablePointer<UInt8>?) -> OSStatus

@discardableResult
@_silgen_name("AudioStreamSetProperty")
private func _AudioStreamSetProperty(_ inStream: AudioStreamID,
                                     _ inWhen: UnsafeRawPointer?,
                                     _ inChannel: UInt32,
                                     _ inPropertyID: AudioDevicePropertyID,
                                     _ inPropertyDataSize: UInt32,
                                     _ inPropertyData: UnsafeRawPointer?) -> OSStatus

//  MARK: - File-static storage (v0.78)

private let streamInfo: UnsafeMutablePointer<AudioStreamInfo> = {
    let p = UnsafeMutablePointer<AudioStreamInfo>.allocate(capacity: 4096)
    p.initialize(repeating: AudioStreamInfo(), count: 4096)
    return p
}()

private let deviceInfo: UnsafeMutablePointer<AudioDeviceInfo> = {
    let p = UnsafeMutablePointer<AudioDeviceInfo>.allocate(capacity: 4096)
    p.initialize(repeating: AudioDeviceInfo(), count: 4096)
    return p
}()

//  v0.78
func initAudioUtils() {
    for i in 0..<4096 {
        streamInfo[i].streamID = 0
        deviceInfo[i].inputProc = nil
        deviceInfo[i].outputProc = nil
        deviceInfo[i].inputClient = nil
        deviceInfo[i].outputClient = nil
    }
}

//  enumerate AudioDeviceID's and return number of devices found in machine
func enumerateAudioDevices(_ list: UnsafeMutablePointer<AudioDeviceID>!, _ n: Int32) -> Int32 {
    var size: UInt32
    var status: OSStatus

    size = UInt32(n) &* UInt32(MemoryLayout<AudioDeviceID>.size)
    status = _AudioHardwareGetProperty(kAudioHardwarePropertyDevices, &size, list)
    for _ in 0..<8 {
        //  check a few times in case we need did not get a response from CoreAudio
        if status == 0 { break }
        usleep(100000)
        size = UInt32(n) &* UInt32(MemoryLayout<AudioDeviceID>.size)
        status = _AudioHardwareGetProperty(kAudioHardwarePropertyDevices, &size, list)
    }
    if status != 0 { return 0 }

    let devices = Int32(size / UInt32(MemoryLayout<AudioDeviceID>.size))
    return devices
}

func getPhysicalFormatCount(_ streamID: Int32) -> Int32 {
    var datasize: UInt32 = 0

    _AudioStreamGetPropertyInfo(UInt32(bitPattern: streamID), 0, kAudioStreamPropertyPhysicalFormats, &datasize, nil)

    return Int32(datasize / UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
}

func getActualFormatCount(_ streamID: Int32) -> Int32 {
    var datasize: UInt32 = 0
    var dummy: UInt8 = 0

    _AudioStreamGetPropertyInfo(UInt32(bitPattern: streamID), 0, kAudioDevicePropertyStreamFormats, &datasize, &dummy)

    return Int32(datasize / UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
}

func getDeviceParams(_ streamID: Int32, _ isInput: Bool, _ devParams: UnsafeMutablePointer<DevParams>!) {
    var datasize: UInt32

    devParams.pointee.bitPairs = 0

    //  fetch all formats, first find the number of formats
    let formats = getPhysicalFormatCount(streamID)

    datasize = UInt32(formats) &* UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let formatsAvailable = malloc(Int(datasize))!.assumingMemoryBound(to: AudioStreamBasicDescription.self)
    //  now fetch the formats
    _ = cm_AudioStreamGetProperty(UInt32(bitPattern: streamID), 0, kAudioStreamPropertyPhysicalFormats, &datasize, formatsAvailable)

    if datasize > 0 {
        withUnsafeMutablePointer(to: &devParams.pointee.channelBitPair) { tuplePtr in
            let pairs = UnsafeMutableRawPointer(tuplePtr).assumingMemoryBound(to: ChannelBitPair.self)
            for i in 0..<Int(formats) {
                let s = formatsAvailable + i
                //  find unique channel/bit pairs
                var j = 0
                while j < Int(devParams.pointee.bitPairs) {
                    if UInt32(bitPattern: pairs[j].bits) == s.pointee.mBitsPerChannel
                        && UInt32(bitPattern: pairs[j].channels) == s.pointee.mChannelsPerFrame { break }
                    j += 1
                }
                if j >= Int(devParams.pointee.bitPairs) {
                    j = Int(devParams.pointee.bitPairs)
                    pairs[j].bits = Int32(bitPattern: s.pointee.mBitsPerChannel)
                    pairs[j].channels = Int32(bitPattern: s.pointee.mChannelsPerFrame)
                    devParams.pointee.bitPairs += 1
                }
            }
        }
    }
    free(formatsAvailable)
}

//  Stream (floating point samples bits) format of the stream containing the requested channel
func getFormatForStream(_ streamID: Int32, _ channel: Int32, _ streamDesc: UnsafeMutablePointer<AudioStreamExtendedDescription>!) -> Int32 {
    var datasize: UInt32
    var rates = [AudioValueRange](repeating: AudioValueRange(), count: 64)

    datasize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    _ = cm_AudioStreamGetProperty(UInt32(bitPattern: streamID), UInt32(bitPattern: channel), kAudioDevicePropertyStreamFormat, &datasize, &streamDesc.pointee.basic)

    //  get sampling rates
    datasize = UInt32(MemoryLayout<AudioValueRange>.size) &* 64
    _ = cm_AudioStreamGetProperty(UInt32(bitPattern: streamID), UInt32(bitPattern: channel), kAudioDevicePropertyAvailableNominalSampleRates, &datasize, &rates)
    streamDesc.pointee.sampleRanges = Int32(datasize / UInt32(MemoryLayout<AudioValueRange>.size))

    let n = Int(streamDesc.pointee.sampleRanges)
    withUnsafeMutablePointer(to: &streamDesc.pointee.sampleRange) { tuplePtr in
        let ranges = UnsafeMutableRawPointer(tuplePtr).assumingMemoryBound(to: MinMax.self)
        for i in 0..<n {
            ranges[i].min = Float(rates[i].mMinimum)
            ranges[i].max = Float(rates[i].mMaximum)
        }
    }
    return Int32(bitPattern: datasize)
}

//  Physical device (raw device bits) format of the stream containing the requested channel
func getPhysicalFormatForStream(_ streamID: Int32, _ channel: Int32, _ streamDesc: UnsafeMutablePointer<AudioStreamExtendedDescription>!) -> Int32 {
    var datasize: UInt32
    var status: OSStatus
    var rates = [AudioValueRange](repeating: AudioValueRange(), count: 64)

    //  v0.76 do GetPropertyInfo first
    datasize = 0
    status = _AudioStreamGetPropertyInfo(UInt32(bitPattern: streamID), 0, kAudioStreamPropertyPhysicalFormat, &datasize, nil)
    //  v0.78  bypass check if device actually returns stream PropertyInfo
    // assert( datasize == sizeof( AudioStreamBasicDescription ) ) ;

    datasize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

    status = cm_AudioStreamGetProperty(UInt32(bitPattern: streamID), 0, kAudioStreamPropertyPhysicalFormat, &datasize, &streamDesc.pointee.basic)

    //  get sampling rates
    streamDesc.pointee.sampleRanges = 0
    datasize = 0

    status = _AudioStreamGetPropertyInfo(UInt32(bitPattern: streamID), 0, kAudioDevicePropertyAvailableNominalSampleRates, &datasize, nil)
    if status == 0 && datasize != 0 {
        status = cm_AudioStreamGetProperty(UInt32(bitPattern: streamID), UInt32(bitPattern: channel), kAudioDevicePropertyAvailableNominalSampleRates, &datasize, &rates)
        if status == 0 && datasize != 0 {
            streamDesc.pointee.sampleRanges = Int32(datasize / UInt32(MemoryLayout<AudioValueRange>.size))
            let n = Int(streamDesc.pointee.sampleRanges)
            withUnsafeMutablePointer(to: &streamDesc.pointee.sampleRange) { tuplePtr in
                let ranges = UnsafeMutableRawPointer(tuplePtr).assumingMemoryBound(to: MinMax.self)
                for i in 0..<n {
                    ranges[i].min = Float(rates[i].mMinimum)
                    ranges[i].max = Float(rates[i].mMaximum)
                }
            }
            if streamDesc.pointee.sampleRanges != 0 { return streamDesc.pointee.sampleRanges }
        }
    }
    _ = status
    return 0
}

//  Set Stream (floating point) format of the stream containing the requested channel
func setFormatForStream(_ streamID: Int32, _ channel: Int32, _ streamDesc: UnsafeMutablePointer<AudioStreamExtendedDescription>!) {
    var err: OSStatus

    err = _AudioStreamSetProperty(UInt32(bitPattern: streamID), nil, UInt32(bitPattern: channel), kAudioDevicePropertyStreamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &streamDesc.pointee.basic)
    usleep(100000)
    if err != 0 {
        //  printf( "setFormatForStream, error code : %4.4s\n", (char*)&err ) ;
        withUnsafeBytes(of: err) { raw in
            var s = ""
            for k in 0..<4 {
                let b = raw[k]
                if b == 0 { break }
                s.append(Character(UnicodeScalar(b)))
            }
            while s.count < 4 { s = " " + s }
            print("setFormatForStream, error code : \(s)")
        }
    }
}

//  set buffer (frame) size for device (size is per channel)
func setBufferSize(_ deviceID: Int32, _ isInput: Bool, _ size: Int32) -> Int32 {
    var datasize: UInt32
    var data: UInt32

    data = UInt32(bitPattern: size)
    datasize = UInt32(MemoryLayout<UInt32>.size)
    _ = cm_AudioDeviceSetProperty(UInt32(bitPattern: deviceID), 0, isInput, kAudioDevicePropertyBufferFrameSize, datasize, &data)
    usleep(100000)
    _ = cm_AudioDeviceGetProperty(UInt32(bitPattern: deviceID), 0, isInput, kAudioDevicePropertyBufferFrameSize, &datasize, &data)

    return Int32(bitPattern: data)
}

//  set sampling rate, number of bits per sample and number of channels
func setParamsForDevice(_ streamID: Int32, _ isInput: Bool, _ rate: Float, _ bits: Int32, _ channels: Int32) -> Bool {
    var datasize: UInt32
    var writeEnable: UInt8 = 0
    var basic = AudioStreamBasicDescription()
    var err: OSStatus = 0

    //  check if we can write to device
    datasize = UInt32(MemoryLayout<UInt8>.size)
    _AudioStreamGetPropertyInfo(UInt32(bitPattern: streamID), 0, kAudioDevicePropertyStreamFormat, &datasize, &writeEnable)
    if writeEnable == 0 { return false }

    //  fetch all formats (max of 16 Basic descriptions)
    datasize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size) &* 256
    let formatsAvailable = malloc(Int(datasize))!.assumingMemoryBound(to: AudioStreamBasicDescription.self)
    _ = cm_AudioStreamGetProperty(UInt32(bitPattern: streamID), 0, kAudioStreamPropertyPhysicalFormats, &datasize, formatsAvailable)

    let formats = Int(datasize / UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    err = 0

    //  find the format and set both stream format and physical formats
    for i in 0..<formats {
        let s = formatsAvailable + i
        //  mSampleRate of 0.0 in formatsAvailable[i] means that we can select any of the available rates
        if (Double(rate) == s.pointee.mSampleRate || s.pointee.mSampleRate < 1)
            && UInt32(bitPattern: bits) == s.pointee.mBitsPerChannel
            && UInt32(bitPattern: channels) == s.pointee.mChannelsPerFrame {
            //  fix sampling rate for the case it is flexible
            if s.pointee.mSampleRate < 1 { s.pointee.mSampleRate = Double(rate) }
            datasize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            err = _AudioStreamSetProperty(UInt32(bitPattern: streamID), nil, 0, kAudioStreamPropertyPhysicalFormat, datasize, s)
            usleep(10000)
            datasize = 0
            //  v0.76 do GetPropertyInfo first
            _AudioStreamGetPropertyInfo(UInt32(bitPattern: streamID), 0, kAudioStreamPropertyPhysicalFormat, &datasize, nil)
            assert(datasize == UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            _ = cm_AudioStreamGetProperty(UInt32(bitPattern: streamID), 0, kAudioStreamPropertyPhysicalFormat, &datasize, &basic)
            //  check if rate is properly set (2 sets needed in Jaguar with Rev3 iMic?)
            if basic.mSampleRate != Double(rate) {
                // re-set rate a second time
                basic.mSampleRate = Double(rate)
                datasize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                _AudioStreamSetProperty(UInt32(bitPattern: streamID), nil, 0, kAudioStreamPropertyPhysicalFormat, datasize, &basic)
                usleep(10000)
                //  return false if failed second time too
                datasize = 0
                //  v0.76 do GetPropertyInfo first
                _AudioStreamGetPropertyInfo(UInt32(bitPattern: streamID), 0, kAudioStreamPropertyPhysicalFormat, &datasize, nil)
                assert(datasize == UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
                _ = cm_AudioStreamGetProperty(UInt32(bitPattern: streamID), 0, kAudioStreamPropertyPhysicalFormat, &datasize, &basic)
                if basic.mSampleRate != Double(rate) { return false }
            }
            break
        }
    }
    free(formatsAvailable)
    return err == 0
}

//  return AudioStreamInfo entry for the StreamID
//  If not, return an empty entry.  If there are no empty entries, return the first entry, which is used as a recycled cache.
func infoForStream(_ streamID: AudioStreamID) -> UnsafeMutablePointer<AudioStreamInfo>! {
    //  v0.78 change to 4096 elements
    let index = Int(Int32(bitPattern: streamID) % 4096)
    return streamInfo + index
}

func audioDeviceChangeInputProc(_ deviceID: AudioDeviceID, _ proc: AudioDeviceIOProc!, _ clientData: UnsafeMutableRawPointer!) -> OSStatus {
    let index = Int(Int32(bitPattern: deviceID) % 4096)
    let d = deviceInfo + index

    if unsafeBitCast(d.pointee.inputProc, to: UnsafeRawPointer?.self) == unsafeBitCast(proc, to: UnsafeRawPointer?.self)
        && clientData == d.pointee.inputClient { return 0 }

    if d.pointee.inputProc != nil {
        _ = cm_AudioDeviceRemoveIOProc(deviceID, proc)
        usleep(200000)
    }
    d.pointee.inputProc = proc
    d.pointee.inputClient = clientData
    return cm_AudioDeviceAddIOProc(deviceID, proc, clientData)
}

func audioDeviceChangeOutputProc(_ deviceID: AudioDeviceID, _ proc: AudioDeviceIOProc!, _ clientData: UnsafeMutableRawPointer!) -> OSStatus {
    let index = Int(Int32(bitPattern: deviceID) % 4096)
    let d = deviceInfo + index

    if unsafeBitCast(d.pointee.outputProc, to: UnsafeRawPointer?.self) == unsafeBitCast(proc, to: UnsafeRawPointer?.self)
        && clientData == d.pointee.outputClient { return 0 }

    if d.pointee.outputProc != nil {
        _ = cm_AudioDeviceRemoveIOProc(deviceID, proc)
    }
    d.pointee.outputProc = proc
    d.pointee.outputClient = clientData
    return cm_AudioDeviceAddIOProc(deviceID, proc, clientData)
}
