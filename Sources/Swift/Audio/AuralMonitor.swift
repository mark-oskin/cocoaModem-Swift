//
//  AuralMonitor.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 10/31/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of AuralMonitor.m.  A nib-loaded DestClient that mixes the stereo
//  aural streams pushed by the modem monitors and feeds them to a
//  PushedStereoDest (ModemDest) output.  The AURALBUFFERS ring of 512-sample
//  left/right buffers is modelled by a small reference type whose C float
//  buffers are freed in its deinit; the producer/consumer sample-index
//  arithmetic is preserved exactly.
//

import Cocoa

private let AURALBUFFERS = 16

//  one slot of the aural ring buffer (was the C `AuralBuffer` struct)
private final class AuralBuffer {
    let left = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    var client = [DestClient?](repeating: nil, count: 32)
    var clients: Int = 0
    init() {
        left.initialize(repeating: 0, count: 512)
        right.initialize(repeating: 0, count: 512)
    }
    deinit {
        left.deallocate()
        right.deallocate()
    }
}

@objc(AuralMonitor)
class AuralMonitor: DestClient {

    @IBOutlet var window: NSWindow!
    @IBOutlet var controlView: NSView!
    @IBOutlet var levelView: NSView!
    @IBOutlet var blendSlider: NSSlider!
    @IBOutlet var muteCheckBox: NSButton!

    @objc var modemDest: PushedStereoDest!

    //  active client list (was AuralClient activeClient[64]; only .client is used)
    private var activeClient = [DestClient?](repeating: nil, count: 64)
    private var clients: Int = 0

    private var auralBuffer: [AuralBuffer] = (0..<AURALBUFFERS).map { _ in AuralBuffer() }

    private var stereoBlend: Float = 0                       //  v0.88
    private var stepAttenuator: Float = 0                    //  v0.88
    private var producerSampleIndex: Int = 0                 //  v0.88
    private var consumerSampleIndex: Int = 0                 //  v0.88
    private var readHysteresis: Int = 0
    private var readBlocked: Bool = false

    private var lock: NSLock!

    //  (Private API)
    private func setInterface(_ object: NSControl?, to selector: Selector) {
        object?.action = selector
        object?.target = self
    }

    override init() {
        super.init()
        clients = 0
        stereoBlend = 0.5
        stepAttenuator = 0.707
        producerSampleIndex = 0
        consumerSampleIndex = 0                              //  v0.88
        readHysteresis = 0                                   //  v0.88
        readBlocked = false                                 //  v0.88

        if Bundle.main.loadNibNamed("AuralMonitor", owner: self, topLevelObjects: nil) {
            lock = NSLock()
            modemDest = PushedStereoDest(intoView: controlView, device: "Aural Monitor", level: levelView, client: self)
            modemDest.setSoundLevelKey(kAuralMonitorLevel, attenuatorKey: kAuralMonitorAttenuator)
            modemDest.setupSoundCards()
            //  for now
            modemDest.enableOutput(false)
            //modemDest.enableOutput(true)
            setInterface(muteCheckBox, to: #selector(muteChanged))
            setInterface(blendSlider, to: #selector(blendChanged))
        }
    }

    @objc func muteChanged() {
        let muted = (muteCheckBox.state == .on)

        if muted == false {
            modemDest.enableOutput(true)                     //  v0.88 turn on at start
            modemDest.startSampling()
        } else {
            modemDest.stopSampling()
            modemDest.enableOutput(false)                    //  v0.88 turn on at start
        }
        modemDest.setMute(muted)
    }

    @objc func blendChanged() {
        stereoBlend = blendSlider.floatValue
        if stereoBlend > 0.5 { stereoBlend = 0.5 } else if stereoBlend < 0 { stereoBlend = 0 }
    }

    //  v0.88 callback from PushedStereoDest (ModemDest)
    @objc(setOutputScale:)
    override func setOutputScale(_ value: Float) {
        stepAttenuator = value
    }

    //  place DestClient into the actively sampling list
    @objc(addClient:)
    func addClient(_ client: DestClient?) {
        lock.lock()
        //  check if this client is already active
        for i in 0..<clients {
            if activeClient[i] === client {
                lock.unlock()
                return
            }
        }
        activeClient[clients] = client
        clients += 1

        if clients == 1 {
            modemDest.startSampling()
        }
        lock.unlock()
    }

    //  place DestClient into the actively sampling list
    @objc(removeClient:)
    func removeClient(_ client: DestClient?) {
        lock.lock()
        //  check if this client is actually active
        var i = 0
        while i < clients {
            if activeClient[i] === client { break }
            i += 1
        }
        if i >= clients {
            lock.unlock()
            return
        }
        //  remove the unregistering client
        clients -= 1
        while i < clients {
            activeClient[i] = activeClient[i + 1]
            i += 1
        }
        if clients <= 0 {
            modemDest.stopSampling()
        }
        lock.unlock()
    }

    //  clients add data to the Aural Monitor here.
    //  left and right channel data can be nil.
    @objc(addLeft:right:samples:client:)
    func addLeft(_ leftp: UnsafeMutablePointer<Float>?, right rightp: UnsafeMutablePointer<Float>?, samples: Int32, client who: DestClient?) {
        if samples != 512 { return }        //  sanity check

        //  v0.88 check if input is close to overrunning output
        let samplesAvailable = producerSampleIndex - consumerSampleIndex
        if samplesAvailable > (AURALBUFFERS - 4) * 512 {
            //  already 12 AURALBUFFERS ahead of playback pointer
            return
        }

        //  v0.88 stereo blend
        let alpha = (1 - stereoBlend) * stepAttenuator
        let beta = stereoBlend * stepAttenuator

        let left = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { left.deallocate(); right.deallocate() }

        if leftp == nil {
            left.initialize(repeating: 0, count: 512)
            right.initialize(repeating: 0, count: 512)
        } else {
            for i in 0..<512 {
                let v = leftp![i]
                left[i] = v * alpha
                right[i] = v * beta
            }
        }
        if let rightp = rightp {
            for i in 0..<512 {
                let v = rightp[i]
                left[i] += v * beta
                right[i] += v * alpha
            }
        }

        //  check if the client is already in the current buffer
        let writeBlock = (producerSampleIndex / 512) % AURALBUFFERS
        let a = auralBuffer[writeBlock]
        let n = a.clients
        var i = 0
        while i < n {
            if a.client[i] === who { break }
            i += 1
        }
        if i < n {
            //  time to advance the next buffer in the ring and copy data into it
            a.clients = 1
            a.client[0] = who
            a.left.update(from: left, count: 512)
            a.right.update(from: right, count: 512)
        } else {
            //  add the client to the current buffer's client list, and mix the new data into it
            a.client[a.clients] = who
            a.clients += 1
            for j in 0..<512 {
                a.left[j] += left[j]
                a.right[j] += right[j]
            }
        }
        producerSampleIndex += 512
    }

    //  Sound Card fetches data from here.
    @objc(needData:samples:channels:)
    override func needData(_ outbuf: UnsafeMutablePointer<Float>!, samples requestedSamplesIn: Int32, channels chIn: Int32) -> Int32 {
        var requestedSamples = Int(requestedSamplesIn)
        let ch = Int(chIn)

        if clients == 0 {
            //  sanity check
            modemDest.stopSampling()
            memset(outbuf, 0, requestedSamples * ch * MemoryLayout<Float>.size)
            return Int32(requestedSamples)
        }

        //  v0.88  use producer-consumer model
        var samplesAvailable = producerSampleIndex - consumerSampleIndex

        //  sanity check
        if readHysteresis > 1024 { readHysteresis = 1024 }

        if samplesAvailable < requestedSamples + readHysteresis || producerSampleIndex > 0x3ffffff {
            memset(outbuf, 0, requestedSamples * ch * MemoryLayout<Float>.size)
            readHysteresis = 512        //  v0.88 once we run out of data, don't return until we have at least 1024 more samples than necessary

            if !readBlocked {
                consumerSampleIndex = 1 //  this skips the first buffer sent to the aural monitor after input resumes (could be leftover)
                producerSampleIndex = 0
            }
            readBlocked = true
            return Int32(requestedSamples)
        }

        readBlocked = false
        readHysteresis = 0

        let block = (consumerSampleIndex / 512) % AURALBUFFERS
        let sampleOffset = consumerSampleIndex % 512

        //  truncate read to the samples remaining in 512 samples buffer
        samplesAvailable = 512 - sampleOffset
        if requestedSamples > samplesAvailable { requestedSamples = samplesAvailable }

        if ch == 1 {
            memcpy(outbuf, auralBuffer[block].left + sampleOffset, MemoryLayout<Float>.size * requestedSamples)
        } else {
            let a = auralBuffer[block]
            let left = a.left + sampleOffset
            let right = a.right + sampleOffset
            var o = outbuf!
            for i in 0..<requestedSamples {
                o.pointee = left[i]; o += 1
                o.pointee = right[i]; o += 1
            }
        }
        //  advance read pointer
        consumerSampleIndex += requestedSamples

        return Int32(requestedSamples)
    }

    @objc func showWindow() {
        window.level = .floating
        window.makeKeyAndOrderFront(self)
    }

    @objc(setupDefaultPreferences:)
    func setupDefaultPreferences(_ pref: Preferences!) {
        pref.setFloat(0.0, forKey: kAuralMonitorBlend)                          //  v0.88
        pref.setInt(0, forKey: kAuralMonitorMute)
        if modemDest != nil && pref != nil { modemDest.setupDefaultPreferences(pref) }
    }

    @objc(updateFromPlist:)
    func updateFromPlist(_ pref: Preferences!) {
        if pref != nil {
            if modemDest != nil {
                _ = modemDest.updateFromPlist(pref, updateAudioLevel: false)

                let mute = pref.intValue(forKey: kAuralMonitorMute)             //  v0.88
                muteCheckBox.state = (mute == 0) ? .off : .on

                if muteCheckBox.state == .off {
                    modemDest.enableOutput(true)                                //  v0.88 turn on at start
                    modemDest.startSampling()
                }
            }
            stereoBlend = pref.floatValue(forKey: kAuralMonitorBlend)
            if blendSlider != nil {
                blendSlider.floatValue = stereoBlend
                blendChanged()
            }
        }
    }

    //  v0.86 (don't update aural monitor level)
    @objc(retrieveForPlist:)
    func retrieveForPlist(_ pref: Preferences!) {
        if pref != nil {
            if modemDest != nil { modemDest.retrieveForPlist(pref, updateAudioLevel: false) }        //  v0.86
            pref.setInt((muteCheckBox.state == .on) ? 1 : 0, forKey: kAuralMonitorMute)              //  v0.88 missing plist
            pref.setFloat(blendSlider.floatValue, forKey: kAuralMonitorBlend)                        //  v0.88
        }
    }

    //  This is called from Application.m when terminating to ensure the output ModemDest stops sampling
    @objc func unconditionalStop() {
        if modemDest != nil { modemDest.stopSampling() }
    }
}
