//
//  ResamplingPipe.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 10/22/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of ResamplingPipe.m.  ResamplingPipe remains a subclass of the
//  DataPipe base (now also Swift).  It adds a CoreAudio AudioConverter that is
//  disposed in deinit and whenever it is recreated in makeNewRateConverter.
//
//  v0.90  convert data into stereo and keep AudioConverter working with Stereo
//
//  MODERNIZATION NOTE: the original ResamplingPipe.m drove the AudioConverter
//  with -AudioConverterFillBuffer/AudioConverterInputDataProc.  That entry point
//  is marked "no longer supported" (deprecated macOS 10.5) and the Swift importer
//  makes it *unavailable* — it cannot be called from Swift at all.  This port uses
//  the fully supported equivalent, AudioConverterFillComplexBuffer with an
//  AudioConverterComplexInputDataProc.  The resampling arithmetic (buffer sizes,
//  byte counts, double-buffer alternation, remainingSamples bookkeeping, buffer
//  advances) is preserved exactly; only the byte<->packet interface at the
//  AudioConverter boundary changed.  For this interleaved LinearPCM/float format
//  mFramesPerPacket == 1, so 1 packet == 1 frame == (4 * channels) bytes.
//
//  The AudioConverterComplexInputDataProc callbacks are C function pointers, so
//  they are implemented as file-scope non-capturing closures typed as
//  AudioConverterComplexInputDataProc; the receiver is recovered from the refcon
//  (inUserData) via Unmanaged.  The two fixed C buffers (stereoBuffer[2048] and
//  resampledBuffer[8192*2]) are UnsafeMutablePointer<Float> allocated in init and
//  freed in deinit so the callback has a stable pointer into them.
//

import Foundation
import CoreAudio
import AudioToolbox

@objc(ResamplingPipe)
class ResamplingPipe: DataPipe {

    fileprivate var basicDescription = AudioStreamBasicDescription()
    fileprivate var rateConverter: AudioConverterRef?

    fileprivate var numberOfChannels: Int32 = 0
    private var cycle: Int32 = 0

    fileprivate var odd: Bool = false
    fileprivate var useConstantOutputBufferSize: Bool = false
    fileprivate let stereoBuffer: UnsafeMutablePointer<Float>       //  v0.90  [2048]
    fileprivate let resampledBuffer: UnsafeMutablePointer<Float>    //  double buffer it [8192*2]
    fileprivate var remainingSamples: Int32 = 0                     //  for unbuffered buffer
    fileprivate var unbufferedTarget: ModemAudio?
    private var pushed: Bool = false
    fileprivate var inputSamplingRate: Float = 0.0
    fileprivate var currentInputSamplingRate: Float = 0.0
    fileprivate var outputSamplingRate: Float = 0.0
    fileprivate var currentOutputSamplingRate: Float = 0.0

    //  v0.93c -- set up basic description with updated channels instead of stereo channels
    @objc(setNumberOfChannels:)
    func setNumberOfChannels(_ ch: Int32) {
        numberOfChannels = ch
        basicDescription.mChannelsPerFrame = UInt32(ch)
        basicDescription.mBytesPerFrame = 4 * basicDescription.mChannelsPerFrame
        basicDescription.mBytesPerPacket = 4 * basicDescription.mChannelsPerFrame
        basicDescription.mBitsPerChannel = 32
        //  set up rate/channels that will cause an initialization when first used
        currentInputSamplingRate = -1
        currentOutputSamplingRate = -1
    }

    //  (Private API)
    private func finishInit(_ rate: Float, channels ch: Int32) {
        inputSamplingRate = rate
        outputSamplingRate = rate

        basicDescription.mSampleRate = Float64(rate)
        basicDescription.mFormatID = kAudioFormatLinearPCM
        basicDescription.mFormatFlags = kLinearPCMFormatFlagIsFloat
        //  (The original had a __BIG_ENDIAN__ branch adding
        //  kLinearPCMFormatFlagIsBigEndian; all supported Macs are little-endian.)
        basicDescription.mFramesPerPacket = 1
        setNumberOfChannels(ch)         //  v0.93c
        rateConverter = nil
        odd = false
        remainingSamples = 0
    }

    //  Add an AudioConverter to a DataPipe
    @objc(initWithSamplingRate:channels:)
    init(samplingRate rate: Float, channels ch: Int32) {
        stereoBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
        resampledBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 8192 * 2)
        super.init(capacity: 16384 * 128 * Int32(MemoryLayout<Float>.size))
        unbufferedTarget = nil
        useConstantOutputBufferSize = true
        finishInit(rate, channels: ch)
    }

    //  this is used by ModemDest
    @objc(initUnbufferedPipeWithSamplingRate:channels:target:)
    init(unbufferedPipeWithSamplingRate rate: Float, channels ch: Int32, target: ModemAudio?) {
        stereoBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
        resampledBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 8192 * 2)
        super.init(capacity: 512 * 2 * Int32(MemoryLayout<Float>.size))  //  stereo 512 sample buffer
        unbufferedTarget = target
        useConstantOutputBufferSize = true
        finishInit(rate, channels: ch)
    }

    deinit {
        if let rc = rateConverter {
            AudioConverterDispose(rc)
            rateConverter = nil
        }
        stereoBuffer.deallocate()
        resampledBuffer.deallocate()
    }

    @objc(setInputSamplingRate:)
    func setInputSamplingRate(_ rate: Float) {
        inputSamplingRate = rate
    }

    @objc(setOutputSamplingRate:)
    func setOutputSamplingRate(_ rate: Float) {
        outputSamplingRate = rate
    }

    @objc(channels)
    func channels() -> Int32 {
        return numberOfChannels
    }

    @objc(write:samples:)
    func write(_ buf: UnsafeMutablePointer<Float>, samples: Int32) -> Int32 {
        var samples = samples

        if unbufferedTarget != nil { return 0 }   //  cannot write into an unbuffered resampling pipe

        if numberOfChannels == 1 {
            //  v0.93c - only write a single channel into the resampling pipe if mono
            var b = stereoBuffer
            if samples > 1024 { samples = 1024 }
            for i in 0..<Int(samples) {
                let u = buf[i]
                b.pointee = u
                b += 1
            }
            let written = self.write(UnsafeMutableRawPointer(stereoBuffer),
                                     length: samples * Int32(MemoryLayout<Float>.size))
            return written / Int32(MemoryLayout<Float>.size)
        }
        //  stereo input
        let written = self.write(UnsafeMutableRawPointer(buf),
                                 length: samples * numberOfChannels * Int32(MemoryLayout<Float>.size))
        return written / (numberOfChannels * Int32(MemoryLayout<Float>.size))
    }

    @objc(setUseConstantOutputBufferSize:)
    func setUseConstantOutputBufferSize(_ constant: Bool) {
        useConstantOutputBufferSize = constant
    }

    @objc(makeNewRateConverter)
    func makeNewRateConverter() {
        if let rc = rateConverter {
            //  a rate converter already exists
            AudioConverterReset(rc)
            AudioConverterDispose(rc)
            rateConverter = nil
        }
        var inDesc = basicDescription
        inDesc.mSampleRate = Float64(inputSamplingRate)
        var outDesc = basicDescription
        outDesc.mSampleRate = Float64(outputSamplingRate)

        remainingSamples = 0            //  v0.85

        //  create a SamplerateConverter for this read thread
        var converter: AudioConverterRef?
        _ = AudioConverterNew(&inDesc, &outDesc, &converter)
        rateConverter = converter

        //  set up as high quality rate converter
        var quality = UInt32(kAudioConverterQuality_Max)
        if let rc = rateConverter {
            AudioConverterSetProperty(rc, kAudioConverterSampleRateConverterQuality,
                                      UInt32(MemoryLayout<UInt32>.size), &quality)
        }
        currentInputSamplingRate = inputSamplingRate
        currentOutputSamplingRate = outputSamplingRate
    }

    //  return -1 if EOF
    //  return number of samples otherwise
    @objc(readResampledData:samples:)
    func readResampledData(_ buf: UnsafeMutablePointer<Float>, samples: Int32) -> Int32 {
        if self.eof() == true { return -1 }

        if rateConverter == nil
            || inputSamplingRate != currentInputSamplingRate
            || outputSamplingRate != currentOutputSamplingRate {
            //  need to create new rate converter
            makeNewRateConverter()
        }

        guard let rc = rateConverter else { return 0 }

        //  get rate converted data and send to client.
        //  v0.92 (was set to 2 channels in v0.90, which does not work for output
        //  unbuffered channels).  1 packet == 1 frame, so the requested output
        //  packet count is exactly `samples`.
        var ioOutputPackets = UInt32(bitPattern: samples)

        var outputList = AudioBufferList()
        outputList.mNumberBuffers = 1
        outputList.mBuffers = AudioBuffer(
            mNumberChannels: UInt32(bitPattern: numberOfChannels),
            mDataByteSize: UInt32(bitPattern: samples * numberOfChannels * Int32(MemoryLayout<Float>.size)),
            mData: UnsafeMutableRawPointer(buf))

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status: OSStatus
        if unbufferedTarget != nil {
            status = AudioConverterFillComplexBuffer(rc, unbufferedResampleProc, refcon,
                                                     &ioOutputPackets, &outputList, nil)
        } else {
            status = AudioConverterFillComplexBuffer(rc, resampleProc, refcon,
                                                     &ioOutputPackets, &outputList, nil)
        }
        if status == 0 {
            //  ioOutputPackets == output frames produced (== samples produced)
            return Int32(bitPattern: ioOutputPackets)
        }
        return 0
    }
}

//  AudioConverterComplexInputDataProc (see CoreAudio AudioConverter documentation)
//
//  AudioConverterFillComplexBuffer in readResampledData causes data to be read
//  from this proc.  The requested amount depends on the decimation ratio.  In the
//  resampleProc implementation, we block on multiple read() calls until we have
//  all of the requested bytes available.  Excess data that is unused is written
//  into the resampled buffer.
//
//  readThread will block here if there is no data in the pipe.
//
//  The AudioConverter requests `ioNumberDataPackets` input packets; with 1 frame
//  per packet that is (ioNumberDataPackets * 4 * channels) bytes -- the exact
//  `*dataSize` byte count the original AudioConverterInputDataProc received.
private let resampleProc: AudioConverterComplexInputDataProc = { (_, ioNumberDataPackets, ioData, _, userData) -> OSStatus in
    let p = Unmanaged<ResamplingPipe>.fromOpaque(userData!).takeUnretainedValue()
    let bytesPerFrame = Int32(MemoryLayout<Float>.size) * p.numberOfChannels

    //  limit return size of our buffer size (original capped at 8192 bytes)
    var n = Int32(truncatingIfNeeded: ioNumberDataPackets.pointee) * bytesPerFrame
    if n > 8192 { n = 8192 }

    //  alternate between two buffers
    var buf = p.resampledBuffer
    if p.odd { buf += 8192 }
    p.odd = !p.odd

    n = p.readData(UnsafeMutableRawPointer(buf), length: n)   //  block here until all data arrives

    if n < 0 {
        //  EOF: the original propagated -1 as a (huge, wrapped) byte count; here
        //  we signal "no more input" the way FillComplexBuffer expects.
        ioNumberDataPackets.pointee = 0
        ioData.pointee.mBuffers.mData = nil
        ioData.pointee.mBuffers.mDataByteSize = 0
        ioData.pointee.mBuffers.mNumberChannels = UInt32(bitPattern: p.numberOfChannels)
        return 0
    }
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(buf)
    ioData.pointee.mBuffers.mDataByteSize = UInt32(bitPattern: n)
    ioData.pointee.mBuffers.mNumberChannels = UInt32(bitPattern: p.numberOfChannels)
    ioNumberDataPackets.pointee = UInt32(bitPattern: n / bytesPerFrame)
    return 0
}

//  data is fetched from the "target" in 512 sample chunks.  If the buffer runs
//  out, another 512 samples are pulled from the target.  In the unbuffered case
//  here, we skip the pipe entirely.
private let unbufferedResampleProc: AudioConverterComplexInputDataProc = { (_, ioNumberDataPackets, ioData, _, userData) -> OSStatus in
    let p = Unmanaged<ResamplingPipe>.fromOpaque(userData!).takeUnretainedValue()
    let sizeofFloat = Int32(MemoryLayout<Float>.size)
    let bytesPerFrame = sizeofFloat * p.numberOfChannels

    guard let target = p.unbufferedTarget else {
        ioNumberDataPackets.pointee = 0
        return 0
    }

    //  original `*dataSize` (byte count wanted)
    let dataSizeBytes = Int32(truncatingIfNeeded: ioNumberDataPackets.pointee) * bytesPerFrame

    var n: Int32
    var buf: UnsafeMutablePointer<Float>
    if p.useConstantOutputBufferSize == false {
        //  For clients that can supply a variable number of samples (or supply a
        //  zero-filled buffer).  The client should return the actual number of
        //  samples supplied if it is less than the requested number of samples.
        let m = dataSizeBytes / sizeofFloat / p.numberOfChannels
        buf = p.resampledBuffer
        n = target.needData(buf, samples: m, channels: p.numberOfChannels) * p.numberOfChannels * sizeofFloat
    } else {
        //  Always ask for a constant number of samples from the client.
        buf = p.resampledBuffer
        if p.remainingSamples <= 0 {
            _ = target.needData(buf, samples: 512, channels: p.numberOfChannels)
            p.remainingSamples = 512
        }
        //  limit return size of our buffer size
        n = dataSizeBytes
        let m = p.remainingSamples * sizeofFloat * p.numberOfChannels
        if n > m { n = m }

        buf = buf + Int((512 - p.remainingSamples) * p.numberOfChannels)
        p.remainingSamples -= n / sizeofFloat
    }
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(buf)
    ioData.pointee.mBuffers.mDataByteSize = UInt32(bitPattern: n)
    ioData.pointee.mBuffers.mNumberChannels = UInt32(bitPattern: p.numberOfChannels)
    ioNumberDataPackets.pointee = UInt32(bitPattern: n / bytesPerFrame)
    return 0
}
