//
//  PSKHub.swift
//  cocoaModem 2.0  v0.57b
//
//  Created by Kok Chen on 10/18/08.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//  Swift port of PSKHub.m.
//
//  MODERNIZATION NOTE: the original PSKHub.m drove the resampler with
//  -AudioConverterFillBuffer / AudioConverterInputDataProc.  That entry point is
//  marked "no longer supported" and the Swift importer makes it *unavailable*, so
//  this port uses the fully supported AudioConverterFillComplexBuffer with an
//  AudioConverterComplexInputDataProc (the same substitution used by
//  ResamplingPipe.swift).  The mono/float LinearPCM format has 1 frame per packet,
//  so 1 packet == 1 sample == 4 bytes; the 512-sample handoff is preserved exactly.
//

import Cocoa
import CoreAudio
import AudioToolbox

//  ------------------------------------------------------------------------
//  AudioConverterComplexInputDataProc (see CoreAudio AudioConverter documentation)
//
//  AudioConverterFillComplexBuffer in the readThread causes data to be read from
//  this proc.  readThread will block here (inside DataPipe.readData) if there is no
//  data in the pipe.  The proc always supplies one fixed 512-sample (2048-byte)
//  buffer, exactly like the original AudioConverterInputDataProc.
private let pskHubResampleProc: AudioConverterComplexInputDataProc = { (_, ioNumberDataPackets, ioData, _, userData) -> OSStatus in
    let obj = Unmanaged<PSKHub>.fromOpaque(userData!).takeUnretainedValue()
    //  block here waiting for one 512-sample buffer
    obj.readAudioStream()
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(obj.audioStream)
    ioData.pointee.mBuffers.mDataByteSize = UInt32(512 * MemoryLayout<Float>.size)
    ioData.pointee.mBuffers.mNumberChannels = 1
    ioNumberDataPackets.pointee = UInt32(512)
    return 0
}

@objc(PSKHub)
class PSKHub: NSObject {

    //  ---- ivars shared with the PSKBrowserHub subclass (kept internal) ----
    var hasBrowser: Bool = false
    var receiver: PSKReceiver!
    var dataPipe: DataPipe!
    var poolBusy: NSLock!            //  nil in PSKBrowserHub (its -initHub calls [super init]); locked via optional chaining
    //  states
    var enabled: Bool = false

    //  ---- base-only ivars ----
    private var mainDemodulator: PSKDemodulator!
    private var pskDemodulatorLock: NSLock!             //  v0.66

    //  resampler
    private var rateConverter: AudioConverterRef?

    //  float audioStream[512] -> pointer-shared heap buffer (its address is handed
    //  to the AudioConverter), freed in deinit.
    fileprivate let audioStream = UnsafeMutablePointer<Float>.allocate(capacity: 512)

    //  ------------------------------------------------------------------------
    //  Minimal designated initializer (maps to plain -init).  PSKBrowserHub's
    //  -initHub chains through here, mirroring the ObjC PSKBrowserHub -initHub
    //  which calls [super init] (NOT [super initHub]).
    override init() {
        super.init()
        audioStream.initialize(repeating: 0, count: 512)
    }

    //  Mirrors -[PSKHub initHub]; the @objc(initHub) selector is preserved exactly.
    @objc(initHub) init(hub: ()) {
        super.init()
        audioStream.initialize(repeating: 0, count: 512)

        poolBusy = NSLock()
        pskDemodulatorLock = NSLock()
        dataPipe = DataPipe(capacity: Int32(2048 * MemoryLayout<Float>.size))
        setupResampler()
        receiver = nil
        hasBrowser = false
        enabled = false

        //  main demodulator
        mainDemodulator = PSKDemodulator()
        mainDemodulator.delegate = self
    }

    deinit {
        if let rc = rateConverter {
            AudioConverterReset(rc)
            AudioConverterDispose(rc)
            rateConverter = nil
        }
        //  dataPipe and the NSLocks are released by ARC; free the C buffer.
        audioStream.deallocate()
    }

    //  local
    //  set up AudioConverter to resample from 11025 to 8000 samples per second
    @objc(setupResampler)
    func setupResampler() {
        var basicDescription = AudioStreamBasicDescription()
        basicDescription.mSampleRate = 11025
        basicDescription.mFormatID = kAudioFormatLinearPCM
        basicDescription.mFormatFlags = kLinearPCMFormatFlagIsFloat
        //  (The original had a __BIG_ENDIAN__ branch adding
        //  kLinearPCMFormatFlagIsBigEndian; all supported Macs are little-endian.)
        basicDescription.mFramesPerPacket = 1
        basicDescription.mChannelsPerFrame = 1
        basicDescription.mBytesPerFrame = 4 * basicDescription.mChannelsPerFrame
        basicDescription.mBytesPerPacket = 4 * basicDescription.mChannelsPerFrame
        basicDescription.mBitsPerChannel = 32

        var outDescription = basicDescription
        outDescription.mSampleRate = 8000

        //  create a SamplerateConverter for this read thread
        var converter: AudioConverterRef?
        _ = AudioConverterNew(&basicDescription, &outDescription, &converter)
        rateConverter = converter
        //  set up as high quality rate converter
        var quality = UInt32(kAudioConverterQuality_Max)
        if let rc = rateConverter {
            AudioConverterSetProperty(rc, kAudioConverterSampleRateConverterQuality,
                                      UInt32(MemoryLayout<UInt32>.size), &quality)
        }
        //  create a pipe for the input data and read thread to pull the resampled data
        Thread.detachNewThreadSelector(#selector(readThread(_:)), toTarget: self, with: self)
    }

    //  callback only used by PSKBrowserHub
    @objc(newFFTBuffer:)
    func newFFTBuffer(_ inSpectrum: UnsafeMutablePointer<Float>) {
    }

    @objc(demodulatorEnabled)
    func demodulatorEnabled() -> Bool {
        return mainDemodulator?.isEnabled() ?? false
    }

    @objc(enableReceiver:)
    func enableReceiver(_ state: Bool) {
        enabled = state
        mainDemodulator?.enableReceiver(state)
    }

    //  wait for demodulator to go completely quiescent before releasing it
    @objc(delayedRelease:)
    func delayedRelease(_ timer: Timer) {
        //  Under MRC this released the LitePSKDemodulator held in the timer's
        //  userInfo; ARC manages the lifetime, so nothing to release here.
        _ = timer.userInfo
    }

    @objc(setReceiveFrequency:)
    func setReceiveFrequency(_ tone: Float) {
        mainDemodulator?.receiveFrequency = tone
    }

    @objc(setPSKMode:)
    func setPSKMode(_ mode: Int32) {
        mainDemodulator?.setPSKMode(mode)
    }

    @objc(selectFrequency:fromWaterfall:)
    func selectFrequency(_ freq: Float, fromWaterfall: Bool) {
        mainDemodulator?.selectFrequency(freq, fromWaterfall: fromWaterfall)
    }

    @objc(receiveFrequency)
    func receiveFrequency() -> Float {
        return mainDemodulator?.receiveFrequency ?? 0
    }

    @objc(setDelegate:)
    func setDelegate(_ delegate: PSKReceiver!) {
        receiver = delegate
        mainDemodulator?.delegate = receiver
    }

    @objc(setPSKModem:index:)
    func setPSKModem(_ modem: PSK!, index: Int32) {
        mainDemodulator?.setPSKModem(modem, index: index)
    }

    //  New resampled data buffer (at 8000 s/s) arrives.
    @objc(sendBufferToDemodulators:samples:)
    func sendBufferToDemodulators(_ buffer: UnsafeMutablePointer<Float>, samples: Int32) {
        assert(samples == 512)
        mainDemodulator?.newDataBuffer(buffer, samples: samples)
    }

    //  ------------------------------------------------------------------------
    //  Called from the (C) pskHubResampleProc: block on the pipe for one 512-sample
    //  buffer into audioStream (whose address the callback then hands back to the
    //  AudioConverter).
    fileprivate func readAudioStream() {
        _ = dataPipe?.readData(UnsafeMutableRawPointer(audioStream),
                               length: Int32(512 * MemoryLayout<Float>.size))
    }

    //  This thread runs constantly (but is blocked in the resample proc when data
    //  is stopped, i.e. nothing coming in via -importBuffer).
    //
    //  MODERNIZATION NOTE: the original hand-managed a pair of NSAutoreleasePools
    //  with a Gestalt Snow-Leopard check to defer draining.  That workaround is
    //  obsolete; each iteration now simply runs inside an autoreleasepool.
    @objc(readThread:)
    func readThread(_ client: Any?) {
        let inputBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { inputBuffer.deallocate() }

        //  Loop continuously requesting data at 8000 s/s.  This thread blocks inside
        //  the resample proc.  When a complete buffer is received, it is sent to the
        //  demodulators.
        while true {
            autoreleasepool {
                guard let rc = rateConverter else { return }
                //  request 512 output frames (1 frame == 1 sample == 4 bytes)
                var ioOutputPackets = UInt32(512)
                var outputList = AudioBufferList()
                outputList.mNumberBuffers = 1
                outputList.mBuffers = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(512 * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(inputBuffer))
                let refcon = Unmanaged.passUnretained(self).toOpaque()
                let status = AudioConverterFillComplexBuffer(rc, pskHubResampleProc, refcon,
                                                             &ioOutputPackets, &outputList, nil)
                if status == 0 {
                    let samples = Int32(bitPattern: ioOutputPackets)
                    sendBufferToDemodulators(inputBuffer, samples: samples)
                }
            }
        }
    }

    @objc(isEnabled)
    func isEnabled() -> Bool {
        return mainDemodulator?.receiverEnabled() ?? false
    }

    //  How it works:
    //
    //  Data comes here from PSKReceiver as 512 floating point packets at 11025 (CMFs)
    //  samples/second.  We simply write the 512 floating point samples into the
    //  resampling pipe.  This will subsequently be picked up by a waiting resample
    //  proc that is initiated when the readThread calls the AudioConverter.
    //  The readThread is blocked by the resampling proc, which in turn is blocked
    //  waiting for a buffer write from here.  The readThread receives 8000 s/s data,
    //  which it then sends to the demodulators.
    @objc(importData:)
    func importData(_ pipe: CMPipe!) {
        if !isEnabled() { return }

        poolBusy?.lock()
        if let stream = pipe.stream() {
            _ = dataPipe.write(UnsafeMutableRawPointer(stream.pointee.array),
                               length: Int32(512 * MemoryLayout<Float>.size))
        }
        poolBusy?.unlock()
    }
}
