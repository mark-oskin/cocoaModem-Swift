//
//  ASCIITxConfig.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/30/10.
//  Copyright 2010 Kok Chen, W7AY. All rights reserved.
//  Swift port of ASCIITxConfig.m.  ASCIITxConfig is a subclass of RTTYTxConfig
//  (now Swift) and uses an ASCIIModulator for its afsk source.
//

import Cocoa

//  Convert an NSString* field of the (bridged) RTTYConfigSet C struct into a String
private func cmKey(_ u: Unmanaged<NSString>?) -> String? {
    guard let u = u else { return nil }
    return u.takeUnretainedValue() as String
}

@objc(ASCIITxConfig)
class ASCIITxConfig: RTTYTxConfig {

    override func awakeFromModem(_ set: UnsafeMutablePointer<RTTYConfigSet>, rttyRxControl control: AnyObject?) {
        rttyRxControl = nil
        rttyAuralMonitor = nil
        configSet = set.pointee

        transmitBPF = nil
        fir = nil
        hasSetupDefaultPreferences = false
        hasRetrieveForPlist = false
        hasUpdateFromPlist = false
        equalize = 1.0
        fsk = nil
        ook = 0

        //  set output to defaults
        if let outputDevice = cmKey(configSet.outputDevice) {
            currentLow = 0
            currentHigh = 0
            afsk = ASCIIModulator()
            afsk?.setModemClient(modemObj)

            setupModemDest(outputDevice, controlView: soundOutputControls, attenuatorView: soundOutputLevel as? NSView)
            if let level = cmKey(configSet.outputLevel), let att = cmKey(configSet.outputAttenuator) {
                modemDest?.setSoundLevelKey(level, attenuatorKey: att)
            }
            //  color well changes
            setInterface(transmitTextColor, to: #selector(RTTYTxConfig.txColorChanged))
            //  Transmit equalizer
            equalizer = ModemEqualizer(sheetFor: outputDevice)
        }
    }

    //  preferences maintainence, called from ASCII.m
    @objc(setupDefaultPreferences:rttyRxControl:)
    override func setupDefaultPreferences(_ pref: Preferences, rttyRxControl control: AnyObject?) {
        if hasSetupDefaultPreferences { return }        //  already done (multiple receivers)
        hasSetupDefaultPreferences = true

        rttyRxControl = control

        if let k = cmKey(configSet.stopBits) { pref.setFloat(2.0, forKey: k) }
        if let k = cmKey(configSet.sentColor) { set(k, fromRed: 0.0, green: 0.8, blue: 1.0, into: pref) }
        modemDest?.setupDefaultPreferences(pref)
        equalizer?.setupDefaultPreferences(pref)
    }

    //  called from ASCII.m
    @objc(updateFromPlist:rttyRxControl:)
    @discardableResult
    override func updateFromPlist(_ pref: Preferences, rttyRxControl control: AnyObject?) -> Bool {
        if hasUpdateFromPlist { return true }           //  already done (multiple receivers)
        hasUpdateFromPlist = true

        rttyRxControl = control

        updateColorsFromPreferences(pref, configSet: configSetStorage)

        if !(modemDest?.updateFromPlist(pref) ?? false) {
            _ = Messages.alert(withMessageText: NSLocalizedString("ASCII settings needs to be reselected", comment: ""),
                               informativeText: NSLocalizedString("Device removed", comment: ""))
        }
        equalizer?.updateFromPlist(pref)

        //  stop bits
        var stopValue: Float = 0
        if let k = cmKey(configSet.stopBits) { stopValue = pref.floatValue(forKey: k) }
        let version = pref.intValue(forKey: kPrefVersion)

        //  fix bug in simple RTTY (not connected) stop value
        if stopValue < 1.1 && version == 2 { stopValue = 1.5 }

        var index = 1
        if stopValue < 1.1 { index = 0 } else if stopValue > 1.9 { index = 2 }
        if cmKey(configSet.stopBits) != nil {
            stopBits?.selectCell(atRow: index, column: 0)
            afsk?.setStopBits(stopValue)
        }
        return true
    }

    //  update preference dictionary for writing back into the plist file
    @objc(retrieveForPlist:rttyRxControl:)
    override func retrieveForPlist(_ pref: Preferences, rttyRxControl control: AnyObject?) {
        if hasRetrieveForPlist { return }               //  already done (multiple receivers)
        hasRetrieveForPlist = true

        rttyRxControl = control

        if let sent = transmitTextColor?.color, let k = cmKey(configSet.sentColor) { set(k, fromColor: sent, into: pref) }
        //  rtty output prefs
        modemDest?.retrieveForPlist(pref)
        equalizer?.retrieveForPlist(pref)
        //  stop bits
        if let stopBits = stopBits {
            let index = stopBits.selectedRow
            if index >= 0 && index < RTTYTxConfig.stopDuration.count, let k = cmKey(configSet.stopBits) {
                pref.setFloat(RTTYTxConfig.stopDuration[index], forKey: k)
            }
        }
    }

    //  -------------- transmit stream ---------------------

    override func startTransmit() -> Bool {
        if fsk != nil { return startFSKTransmit() }      // v0.50

        //  adjust amplitude based on equalizer here
        if let tonepair = afsk?.toneFrequencies() {
            let midFrequency = (tonepair.pointee.mark + tonepair.pointee.space) * 0.5
            equalize = Float(equalizer?.amplitude(Float(midFrequency)) ?? 1.0)
        }

        if !isTransmit && !configOpen {
            toneIndex = 0
            modemDest?.stopSampling()
            "|".withCString { afsk?.appendString($0, clearExistingCharacters: false) }        //  send a long mark
            modemDest?.startSampling()
            if let transmitButton = transmitButton {
                transmitButton.title = NSLocalizedString("Receive", comment: "")
                transmitButton.state = .on
            }
            isTransmit = true
            return true
        }
        isTransmit = false
        NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
        if let transmitButton = transmitButton {
            transmitButton.title = NSLocalizedString("Transmit", comment: "")
            transmitButton.state = .off
        }
        if configOpen {
            _ = Messages.alert(withMessageText: NSLocalizedString("Close Config Panel", comment: ""),
                               informativeText: NSLocalizedString("Close Config Panel and try Again", comment: ""))
            modemObj.flushAndLeaveTransmit()
        }
        return false
    }

    //  v0.50
    @discardableResult
    override func stopFSKTransmit() -> Bool {
        if isTransmit {
            isTransmit = false
            fsk?.stopSampling()
            if let transmitButton = transmitButton {
                transmitButton.title = NSLocalizedString("Transmit", comment: "")
                transmitButton.state = .off
            }
            fsk?.clearOutput()
            modemObj.transmissionEnded()
        }
        return false
    }

    override func stopTransmit() -> Bool {
        if fsk != nil { return stopFSKTransmit() }       //  v0.50

        if isTransmit {
            isTransmit = false
            modemDest?.stopSampling()
            if let transmitButton = transmitButton {
                transmitButton.title = NSLocalizedString("Transmit", comment: "")
                transmitButton.state = .off
            }
            afsk?.clearOutput()                          //  v0.46
            modemObj.transmissionEnded()
        }
        return false
    }

    @objc(transmitCharacter:)
    override func transmitCharacter(_ ascii: Int32) {
        if ascii == 0x6 { return }                       // ignore %[tx] for now
        if let fsk = fsk { fsk.appendASCII(ascii) } else { afsk?.appendASCII(ascii) }        // v0.50
    }

    @objc(flushTransmitBuffer)
    override func flushTransmitBuffer() {
        if let fsk = fsk { fsk.clearOutput() } else { afsk?.clearOutput() }                  // v0.50
    }

    //  accepts a button; returns YES if RTTY modemDest is Transmiting
    @objc(turnOnTransmission:button:fsk:)
    @discardableResult
    override func turnOnTransmission(_ inState: Bool, button: NSButton?, fsk inFSK: FSK?) -> Bool {
        //  check if we should use FSK
        fsk = inFSK
        if let f = fsk {
            //  select fsk port and check if port is good
            let fd = f.useSelectedPort()
            if fd <= 0 { fsk = nil }
        }
        ook = 0
        transmitButton = button
        return inState ? startTransmit() : stopTransmit()
    }

    @objc(turnOnTransmission:button:fsk:ook:)
    @discardableResult
    override func turnOnTransmission(_ inState: Bool, button: NSButton?, fsk inFSK: FSK?, ook inOOK: Int32) -> Bool {
        //  check if we should use FSK
        fsk = inFSK
        if let f = fsk {
            f.setUSOS(usosState)                         //  v0.84
            let fd = f.useSelectedPort()
            if fd <= 0 { fsk = nil }
        }
        //  v0.85 check ook state 0 = afsk, fsk, 1, 2 = ook
        ook = inOOK
        transmitButton = button
        return inState ? startTransmit() : stopTransmit()
    }

    /* local */
    override func selectTestTone(_ index: Int32) {
        guard let toneMatrix = toneMatrix else { return }

        toneMatrix.deselectAllCells()
        toneMatrix.selectCell(atRow: 0, column: Int(index))
        if let timeout = timeout {
            timeout.invalidate()
            self.timeout = nil
        }

        modemObj.executePTT(index != 0)
        switch index {
        case 0:
            modemDest?.stopSampling()
            flushTransmitBuffer()
        case 4:
            toneIndex = index
            modemDest?.stopSampling()
            "========".withCString { afsk?.appendString($0, clearExistingCharacters: true) }
            modemDest?.startSampling()
        case 5:
            toneIndex = index
            modemDest?.stopSampling()
            "RYRYRYRY".withCString { afsk?.appendString($0, clearExistingCharacters: true) }
            modemDest?.startSampling()
        case 6:
            toneIndex = index
            modemDest?.stopSampling()
            "\nthe quick brown fox jumps over the lazy dog. 589 73 qrz".withCString { afsk?.appendString($0, clearExistingCharacters: true) }
            modemDest?.startSampling()
        default:
            toneIndex = index
            modemDest?.startSampling()
        }
    }

    //  watchdog timer, turn test tone off
    @objc(timedOut:)
    override func timedOut(_ timer: Timer) {
        timeout = nil
        selectTestTone(0)
        NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
    }

    @objc(afskObj)
    override func afskObj() -> RTTYModulator? {
        return afsk
    }

    @objc(stopSampling)
    override func stopSampling() {
        modemDest?.stopSampling()
    }

    //  ---------------- ModemDest callbacks ---------------------

    //  modemDest needs more data
    @objc(needData:samples:)
    override func needData(_ outbuf: UnsafeMutablePointer<Float>!, samples: Int32) -> Int32 {
        //  assume outputSamplingRate = 11025, outputChannels = 1
        assert(samples <= 512)
        switch toneIndex {
        case 0:
            //  normal transmission, index != 0 is for test tones
            afsk?.getBufferWithDiddleFill(bpfBuf, length: samples)
        case 2:
            afsk?.getBufferOfSpaceTone(bpfBuf, length: samples)
        case 3:
            afsk?.getBufferOfTwoTone(bpfBuf, length: samples)
        case 4, 5, 6:
            afsk?.getBufferWithRepeatFill(bpfBuf, length: samples)
        default:
            afsk?.getBufferOfMarkTone(bpfBuf, length: samples)
        }

        //  apply bandpass filter and save into output
        CMPerformFIR(transmitBPF, bpfBuf, samples, outbuf)

        //  v0.78 send unequalized output to auralMonitor
        if let rttyAuralMonitor = rttyAuralMonitor {
            rttyAuralMonitor.newBandpassFilteredData(outbuf, scale: outputScale, fromReceiver: false)
        }

        if equalizer != nil {
            for i in 0..<Int(samples) { outbuf[i] *= equalize }
        }
        return 1        // output channels
    }

    @objc(setOutputScale:)
    override func setOutputScale(_ value: Float) {
        outputScale = value * modemObj.outputBoost      //  v0.88 allow 2 dB boost
        afsk?.setOutputScale(outputScale)
    }
}
