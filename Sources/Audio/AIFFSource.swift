//
//  AIFFSource.swift
//  AudioInterface
//
//  Created by Kok Chen on 11/06/05
//	Ported from cocoaModem; file originally dated 1/21/05.
//  Swift port of AIFFSource.{h,m}.
//
//  Allows data to be inserted from an AIFF or WAV file instead of the usual
//  stream.  -openSoundFileWithTypes: is modernized to AudioFileOpenURL /
//  NSOpenPanel.runModal (the original FSRef / AudioFileOpen path is unavailable
//  in the current SDK); observable behavior (returns the path or nil, opens the
//  file into soundFile) is preserved.
//
//  Only the little-endian host code path of the original -fetchDataFromFile is
//  ported (the build targets little-endian arm64 / x86_64).
//

import Cocoa
import AudioToolbox

@objc(AIFFSource)
class AIFFSource: CMTappedPipe {

    internal let storage: UnsafeMutablePointer<Float>   // was float[1024], stereo 512-sample channels
    internal var soundFile = AudioSoundFile()

    override init() {
        storage = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        storage.initialize(repeating: 0, count: 1024)
        super.init()
    }

    deinit {
        storage.deallocate()
    }

    @objc(pipeWithClient:)
    @discardableResult
    override func pipe(withClient inClient: CMPipe?) -> CMPipe? {
        _ = super.pipe(withClient: inClient)
        data.pointee.samplingRate = 11025.0
        data.pointee.array = storage
        data.pointee.components = 1
        data.pointee.channels = 1
        //  soundFile
        soundFile.ID = nil
        soundFile.active = false
        soundFile.repeatFile = true
        soundFile.stride = 1
        return self
    }

    @objc func samplingRate() -> Float {
        return Float(soundFile.basicDescription.mSampleRate)
    }

    @objc(setSamplingRate:)
    func setSamplingRate(_ samplingRate: Float) {
        data.pointee.samplingRate = samplingRate
    }

    @objc(setFileRepeat:)
    func setFileRepeat(_ doRepeat: Bool) {
        soundFile.repeatFile = DarwinBoolean(doRepeat)
    }

    @objc func soundFileStride() -> Int32 {
        return soundFile.stride
    }

    @objc func soundFileActive() -> Bool {
        return soundFile.active.boolValue
    }

    @objc func stopSoundFile() {
        soundFile.active = false
        if let id = soundFile.ID { AudioFileClose(id) }
        soundFile.ID = nil
    }

    //  fill in AudioStreamBasicDescription, etc
    private func getSoundFileProperty() {
        guard let id = soundFile.ID else { return }

        var size: UInt32 = 4
        AudioFileGetProperty(id, kAudioFilePropertyFileFormat, &size, &soundFile.fileFormat)
        size = 8
        AudioFileGetProperty(id, kAudioFilePropertyAudioDataByteCount, &size, &soundFile.bytes)
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioFileGetProperty(id, kAudioFilePropertyDataFormat, &size, &soundFile.basicDescription)

        if err == noErr {
            let b = soundFile.basicDescription
            soundFile.sampleSize = Int32(b.mBytesPerFrame / b.mChannelsPerFrame)
            soundFile.stride = Int32(b.mBytesPerFrame) / soundFile.sampleSize
            soundFile.samples = soundFile.bytes / UInt64(soundFile.stride * soundFile.sampleSize)
            soundFile.isBigEndian = DarwinBoolean((b.mFormatFlags & kLinearPCMFormatFlagIsBigEndian) != 0)
            soundFile.isSigned = DarwinBoolean((b.mFormatFlags & kLinearPCMFormatFlagIsSignedInteger) != 0)
        }
    }

    //  return nil if user aborted, else path string
    @objc(openSoundFileWithTypes:)
    func openSoundFile(withTypes fileTypes: [Any]?) -> String? {
        if soundFile.active.boolValue { stopSoundFile() }

        let open = NSOpenPanel()
        open.allowsMultipleSelection = false
        open.allowedFileTypes = fileTypes as? [String]

        if open.runModal() == .OK {
            guard let url = open.url else { return nil }
            var fileID: AudioFileID? = nil
            let err = AudioFileOpenURL(url as CFURL, .readWritePermission, 0, &fileID)
            if err == noErr {
                soundFile.ID = fileID
                getSoundFileProperty()
                soundFile.currentSample = 0
                soundFile.active = true
            }
            return url.path
        }
        return nil
    }

    /* local */
    private func fetchDataFromFile(channel offset: Int32, bufferOffset: Int32) {
        let stride = Int(soundFile.stride)
        let bufOff = Int(bufferOffset)
        let off = Int(offset)
        let sampleSize = Int(soundFile.sampleSize)
        let isSigned = soundFile.isSigned.boolValue
        let isBigEndian = soundFile.isBigEndian.boolValue

        withUnsafeMutableBytes(of: &soundFile.buf) { rawBuf in
            let base = rawBuf.baseAddress!

            if sampleSize == 1 {   /* 8-bit data */
                let gain: Float = 1.0 / 128.0
                if isSigned {
                    var b = base.advanced(by: off).assumingMemoryBound(to: CChar.self)
                    for i in 0..<512 {
                        storage[bufOff + i] = Float(b.pointee) * gain
                        b = b.advanced(by: stride)
                    }
                } else {
                    var c = base.advanced(by: off).assumingMemoryBound(to: UInt8.self)
                    for i in 0..<512 {
                        storage[bufOff + i] = Float(c.pointee) * gain - 1.0
                        c = c.advanced(by: stride)
                    }
                }
            } else {   /* 16-bit data, sampleSize > 1 */
                let gain: Float = 1.0 / 32768.0

                if !isBigEndian {
                    if isSigned {
                        var u = base.assumingMemoryBound(to: Int16.self).advanced(by: off)
                        for i in 0..<512 {
                            storage[bufOff + i] = Float(u.pointee) * gain
                            u = u.advanced(by: stride)
                        }
                    } else {
                        var v = base.assumingMemoryBound(to: UInt16.self).advanced(by: off)
                        for i in 0..<512 {
                            storage[bufOff + i] = Float(v.pointee) * gain - 1.0
                            v = v.advanced(by: stride)
                        }
                    }
                } else {
                    let skip = stride * 2
                    if isSigned {
                        var c = base.advanced(by: off * 2).assumingMemoryBound(to: UInt8.self)
                        for i in 0..<512 {
                            //  swap for little endian
                            let t = Int16(truncatingIfNeeded: (Int(c[0]) << 8) | Int(c[1]))
                            storage[bufOff + i] = Float(t) * gain
                            c = c.advanced(by: skip)
                        }
                    } else {
                        var c = base.advanced(by: off * 2).assumingMemoryBound(to: UInt8.self)
                        for i in 0..<512 {
                            //  swap for little endian
                            let w = (Int(c[0]) << 8) | Int(c[1])
                            storage[bufOff + i] = Float(w) * gain - 1.0
                            c = c.advanced(by: skip)
                        }
                    }
                }
            }
        }
    }

    //  fetch next 512 samples from AudioSoundFile and insert into CMPipe
    //  return true if ended
    @objc(insertNextFileFrameWithOffset:)
    func insertNextFileFrame(withOffset offset: Int32) -> Bool {
        if (soundFile.currentSample + 512) > soundFile.samples {
            // EOF reached
            if !soundFile.repeatFile.boolValue {
                if let id = soundFile.ID { AudioFileClose(id) }
                return true
            }
            //  repeat file at beginning
            soundFile.currentSample = 0
        }
        var bytes = UInt32(soundFile.stride * soundFile.sampleSize * 512)
        guard let fileID = soundFile.ID else { return true }
        let startByte = Int64(soundFile.currentSample) * Int64(soundFile.sampleSize)
        let status = withUnsafeMutableBytes(of: &soundFile.buf) { rawBuf in
            AudioFileReadBytes(fileID, true, startByte, &bytes, rawBuf.baseAddress!)
        }
        if status != noErr { return true }

        //  extract data and send to client
        fetchDataFromFile(channel: offset, bufferOffset: 0)
        soundFile.currentSample += UInt64(soundFile.stride * 512)
        data.pointee.array = storage
        data.pointee.samples = 512
        data.pointee.channels = 1
        exportData()
        return false
    }

    //  fetch next 512 stereo samples from AudioSoundFile and insert into CMPipe
    //  truncate and return true if end reached
    @objc func insertNextStereoFileFrame() -> Bool {
        var bytes = UInt32(soundFile.stride * soundFile.sampleSize * 512)
        if (soundFile.currentSample + 512) > soundFile.samples {
            // EOF reached
            if !soundFile.repeatFile.boolValue {
                stopSoundFile()
                return true
            }
            //  repeat file
            soundFile.currentSample = 0
        }
        guard let fileID = soundFile.ID else { return true }
        let startByte = Int64(soundFile.currentSample) * Int64(soundFile.sampleSize)
        let status = withUnsafeMutableBytes(of: &soundFile.buf) { rawBuf in
            AudioFileReadBytes(fileID, true, startByte, &bytes, rawBuf.baseAddress!)
        }
        if status != noErr { return true }

        //  extract and create "split complex" data and export to client
        fetchDataFromFile(channel: 0, bufferOffset: 0)
        if soundFile.stride == 1 {
            //  file is mono, duplicate the same mono channel into the output right channel
            fetchDataFromFile(channel: 0, bufferOffset: 512)
        } else {
            //  file has more than one channel, fetch from second channel
            fetchDataFromFile(channel: 1, bufferOffset: 512)
        }
        soundFile.currentSample += UInt64(soundFile.stride * 512)
        data.pointee.array = storage
        data.pointee.samples = 512
        data.pointee.channels = 2   // "split complex" channels
        exportData()
        return false
    }

    //  export imported data, but offsetting to the appropriate channel if it exists
    @objc(importData:offset:)
    func importData(_ inpipe: CMPipe!, offset: Int32) {
        if soundFile.active.boolValue { return }

        data.pointee = inpipe.stream().pointee

        if offset < 2 {
            if data.pointee.channels != 1 {
                data.pointee.channels = 1
                if offset != 0 { data.pointee.array = data.pointee.array?.advanced(by: Int(data.pointee.samples)) }
            }
        }
        exportData()
    }
}
