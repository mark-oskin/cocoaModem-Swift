//
//  RTTYTxConfig.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/6/06.
//  Swift port of RTTYTxConfig.m.  RTTYTxConfig is the base of ASCIITxConfig and
//  CWTxConfig (both in this batch); it stays a subclass of ModemConfig (Swift).
//  Instance variables become EXACT-named stored properties so the subclasses
//  reference them by name (configSet, afsk, fir, transmitBPF, currentLow,
//  currentHigh, equalize, fsk, ook, usosState, rttyAuralMonitor, ...).
//

import Cocoa

//  Convert an NSString* field of the (bridged) RTTYConfigSet C struct into a String
private func cmKey(_ u: Unmanaged<NSString>?) -> String? {
    guard let u = u else { return nil }
    return u.takeUnretainedValue() as String
}

//  guarded float -> Int32
private func cmClampInt(_ x: Float) -> Int32 {
    if !x.isFinite { return 0 }
    let c = min(max(x, -2.0e9), 2.0e9)
    return Int32(c)
}

@objc(RTTYTxConfig)
class RTTYTxConfig: ModemConfig {

    static let stopDuration: [Float] = [1.0, 1.5, 2.0]

    @IBOutlet var stopBits: NSMatrix!

    //  rttyRxControl is an Objective-C RTTYRxControl* (informal-protocol access)
    var rttyRxControl: AnyObject?
    var afsk: RTTYModulator?
    var fsk: FSK?
    var ook: Int32 = 0                          //  v0.85
    var transmitBPF: UnsafeMutablePointer<CMFIR>?
    var fir: UnsafeMutablePointer<Float>?
    var outputSamplingRate: Float = 0
    var currentLow: Int32 = 0
    var currentHigh: Int32 = 0
    var outputChannels: Int32 = 0

    var equalize: Float = 0
    var usosState: Bool = false                 //  v0.84

    //  the following flags keep txConfigs from being called more than once
    var hasSetupDefaultPreferences: Bool = false
    var hasRetrieveForPlist: Bool = false
    var hasUpdateFromPlist: Bool = false

    var rttyAuralMonitor: RTTYAuralMonitor?

    //  RTTYConfigSet is a C struct; keep it in stable heap storage so the
    //  Objective-C accessors can hand back a valid pointer.
    let configSetStorage: UnsafeMutablePointer<RTTYConfigSet> = {
        let p = UnsafeMutablePointer<RTTYConfigSet>.allocate(capacity: 1)
        p.initialize(to: RTTYConfigSet())
        return p
    }()
    var configSet: RTTYConfigSet {
        get { configSetStorage.pointee }
        set { configSetStorage.pointee = newValue }
    }

    deinit {
        if let fir = fir { free(fir) }
        if let transmitBPF = transmitBPF { CMDeleteFIR(transmitBPF) }
        configSetStorage.deallocate()
    }

    /* local */
    private func createTransmitBPF(_ inLow: Float, high inHigh: Float) {
        var low = inLow, high = inHigh

        //  place reasonable limits on tones
        if low < 600 { low = 400 }
        if high > 2750 { high = 2750 }
        if high < low { swap(&high, &low) }         //  sanity check

        let n: Int32 = 128
        let center = (low + high) * 0.5
        let f = 0.5 * center * Float(n) / Float(CMFs)
        var w = 0.5 * (high - low) * Float(n) / Float(CMFs)     //  bandwidth of sinc

        if let fir = fir { free(fir) }
        let firBuf = (malloc(MemoryLayout<Float>.size * Int(n)))!.assumingMemoryBound(to: Float.self)
        fir = firBuf
        var sum: Float = 0
        for i in 0..<Int(n) {
            let t = Float(n) / 2
            let x = (Float(i) - t) / t
            let baseband = Float(CMModifiedBlackmanWindow(Int32(i), n) * CMSinc(Int32(i), n, Double(w)))
            sum += baseband
            firBuf[i] = Float(Double(baseband) * cos(2.0 * CMPi * Double(f) * Double(x)))
        }
        w = 2 / sum
        for i in 0..<Int(n) { firBuf[i] *= w }

        if let transmitBPF = transmitBPF { CMDeleteFIR(transmitBPF) }
        transmitBPF = CMFIRFilter(firBuf, n)
    }

    //  v0.67
    @objc(transmitTonePair)
    func transmitTonePair() -> UnsafeMutablePointer<CMTonePair>? {
        return afsk?.toneFrequencies()
    }

    //  v0.83
    @objc(setBitsPerCharacter:)
    func setBitsPerCharacter(_ bits: Int32) {
        afsk?.setBitsPerCharacter(bits)
    }

    @objc(setupTonesFrom:lockTone:)
    func setupTones(from control: AnyObject?, lockTone state: Bool) {
        rttyRxControl = control                                          // v0.50

        //  get tonepair with the order required by sideband and polarity
        var tonepair = state ? ((control as? RTTYRxControl)?.lockedTxTonePair() ?? CMTonePair())
                             : ((control as? RTTYRxControl)?.txTonePair() ?? CMTonePair())

        withUnsafeMutablePointer(to: &tonepair) { (rttyRxControl as? RTTYRxControl)?.transmitterTonePairChanged(to: $0) }   //  v0.78

        //  set transmit tones
        withUnsafePointer(to: &tonepair) { afsk?.setTonePair($0) }
        //  create a transmit band pass filter that covers up to 4th harmonic of signalling bits
        let width = (tonepair.baud / 2) * 4
        var low: Float, high: Float
        if tonepair.mark < tonepair.space {
            low = Float(tonepair.mark - width)
            high = Float(tonepair.space + width)
        } else {
            high = Float(tonepair.mark + width)
            low = Float(tonepair.space - width)
        }
        //  quantize to 0.1 Hz steps
        let ilow = cmClampInt(low * 10)
        let ihigh = cmClampInt(high * 10)
        if ilow != currentLow || ihigh != currentHigh {
            createTransmitBPF(Float(ilow) * 0.1, high: Float(ihigh) * 0.1)
            currentLow = ilow
            currentHigh = ihigh
        }
    }

    //  NOTE: when RTTYTxControl is called, RTTYRxControl is not defined
    @objc(awakeFromModem:rttyRxControl:)
    func awakeFromModem(_ set: UnsafeMutablePointer<RTTYConfigSet>, rttyRxControl control: AnyObject?) {
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
        ook = 0                     //  v0.85
        usosState = true

        //  set output to defaults
        if let outputDevice = cmKey(configSet.outputDevice) {
            currentLow = 0
            currentHigh = 0
            afsk = RTTYModulator()
            afsk?.setModemClient(modemObj)

            setupModemDest(outputDevice, controlView: soundOutputControls, attenuatorView: soundOutputLevel as? NSView)
            if let level = cmKey(configSet.outputLevel), let att = cmKey(configSet.outputAttenuator) {
                modemDest?.setSoundLevelKey(level, attenuatorKey: att)
            }
            //  color well changes
            setInterface(transmitTextColor, to: #selector(txColorChanged))
            //  Transmit equalizer
            equalizer = ModemEqualizer(sheetFor: outputDevice)
        }
    }

    //  v0.78
    @objc(setRTTYAuralMonitor:)
    func setRTTYAuralMonitor(_ mon: RTTYAuralMonitor?) {
        if configSet.usesRTTYAuralMonitor.boolValue { rttyAuralMonitor = mon }
    }

    //  preferences maintainence, called from RTTY.m
    @objc(setupDefaultPreferences:rttyRxControl:)
    func setupDefaultPreferences(_ pref: Preferences, rttyRxControl control: AnyObject?) {
        if hasSetupDefaultPreferences { return }        //  already done (multiple receivers)
        hasSetupDefaultPreferences = true

        rttyRxControl = control

        if let k = cmKey(configSet.stopBits) { pref.setFloat(1.5, forKey: k) }
        if let k = cmKey(configSet.sentColor) { set(k, fromRed: 0.0, green: 0.8, blue: 1.0, into: pref) }
        modemDest?.setupDefaultPreferences(pref)
        equalizer?.setupDefaultPreferences(pref)
    }

    @objc(updateColorsFromPreferences:configSet:)
    func updateColorsFromPreferences(_ pref: Preferences, configSet set: UnsafeMutablePointer<RTTYConfigSet>) {
        //  set tx color
        if let sent = getColor(cmKey(set.pointee.sentColor) ?? "", from: pref) {
            transmitTextColor?.color = sent
        }
    }

    //  called when color well changes
    @objc(colorChanged)
    func txColorChanged() {
        modemObj.setTransmitTextColor(transmitTextColor?.color)
    }

    //  called from RTTY.m
    @objc(updateFromPlist:rttyRxControl:)
    @discardableResult
    func updateFromPlist(_ pref: Preferences, rttyRxControl control: AnyObject?) -> Bool {
        if hasUpdateFromPlist { return true }           //  already done (multiple receivers)
        hasUpdateFromPlist = true

        rttyRxControl = control

        updateColorsFromPreferences(pref, configSet: configSetStorage)

        if !(modemDest?.updateFromPlist(pref) ?? false) {
            _ = Messages.alert(withMessageText: NSLocalizedString("RTTY settings needs to be reselected", comment: ""),
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
    func retrieveForPlist(_ pref: Preferences, rttyRxControl control: AnyObject?) {
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

    //  v0.50
    @objc(startFSKTransmit)
    @discardableResult
    func startFSKTransmit() -> Bool {
        guard let fsk = fsk else { return false }

        if !isTransmit && !configOpen {
            let baudRate = (rttyRxControl as? RTTYRxControl)?.actualBaudRate() ?? 0
            let txInvert = (rttyRxControl as? RTTYRxControl)?.invertStateForTransmitter() ?? false
            fsk.startSampling(baudRate, invert: txInvert, stopBits: Int32(stopBits?.selectedRow ?? 0))
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

    func startTransmit() -> Bool {
        if fsk != nil { return startFSKTransmit() }      // v0.50

        afsk?.setOOK(ook, invert: (rttyRxControl as? RTTYRxControl)?.invertStateForTransmitter() ?? false)      //  v0.85

        //  adjust amplitude based on equalizer here
        if ook == 0 {
            afsk?.setOutputScale(outputScale)
            _ = modemDest?.validateDeviceLevel()
            if let tonepair = afsk?.toneFrequencies() {
                let midFrequency = (tonepair.pointee.mark + tonepair.pointee.space) * 0.5
                equalize = equalizer?.amplitude(Float(midFrequency)) ?? 1.0
            }
        } else {
            equalize = 1.0                               //  v0.85
            afsk?.setOutputScale(0.75)
            modemDest?.setOOKDeviceLevel()
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
    func stopFSKTransmit() -> Bool {
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

    func stopTransmit() -> Bool {
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
    func transmitCharacter(_ ascii: Int32) {
        if ascii == 0x6 { return }                       // ignore %[tx] for now
        if let fsk = fsk { fsk.appendASCII(ascii) } else { afsk?.appendASCII(ascii) }        // v0.50
    }

    @objc(flushTransmitBuffer)
    func flushTransmitBuffer() {
        if let fsk = fsk { fsk.clearOutput() } else { afsk?.clearOutput() }                  // v0.50
    }

    //  v0.84 local usos state for FSK in turnOnTransmission
    @objc(setUSOS:)
    func setUSOS(_ state: Bool) {
        afskObj()?.setUSOS(state)
        usosState = state
    }

    //  accepts a button; returns YES if RTTY modemDest is Transmiting
    @objc(turnOnTransmission:button:fsk:)
    @discardableResult
    func turnOnTransmission(_ inState: Bool, button: NSButton?, fsk inFSK: FSK?) -> Bool {
        //  check if we should use FSK
        fsk = inFSK
        if let f = fsk {
            f.setUSOS(usosState)                         //  v0.84
            //  select fsk port and check if port is good
            let fd = f.useSelectedPort()
            if fd <= 0 { fsk = nil }
        }
        ook = 0                                          //  v0.85
        transmitButton = button
        return inState ? startTransmit() : stopTransmit()
    }

    @objc(turnOnTransmission:button:fsk:ook:)
    @discardableResult
    func turnOnTransmission(_ inState: Bool, button: NSButton?, fsk inFSK: FSK?, ook inOOK: Int32) -> Bool {
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
    func selectTestTone(_ index: Int32) {
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
    func timedOut(_ timer: Timer) {
        timeout = nil
        selectTestTone(0)
        NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
    }

    @objc(afskObj)
    func afskObj() -> RTTYModulator? {
        return afsk
    }

    @objc(stopSampling)
    func stopSampling() {
        modemDest?.stopSampling()
    }

    //  ---------------- ModemDest callbacks ---------------------

    //  modemDest needs more data
    @objc(needData:samples:)
    override func needData(_ outbuf: UnsafeMutablePointer<Float>!, samples: Int32) -> Int32 {
        //  assume outputSamplingRate = 11025, outputChannels = 1

        //  v0.85 if OOK, do not bandpass
        let buf: UnsafeMutablePointer<Float> = (ook == 0) ? bpfBuf : outbuf!

        assert(samples <= 512)
        switch toneIndex {
        case 0:
            //  normal transmission, index != 0 is for test tones
            afsk?.getBufferWithDiddleFill(buf, length: samples)
        case 2:
            afsk?.getBufferOfSpaceTone(buf, length: samples)
        case 3:
            afsk?.getBufferOfTwoTone(buf, length: samples)
        case 4, 5, 6:
            afsk?.getBufferWithRepeatFill(buf, length: samples)
        default:
            afsk?.getBufferOfMarkTone(buf, length: samples)
        }

        //  apply bandpass filter and save into output
        if ook == 0 {
            //  v0.85 don't filter for OOK, data is already in outbuf
            CMPerformFIR(transmitBPF, bpfBuf, samples, outbuf)
        }

        //  v0.78 send unequalized output to auralMonitor (v0.85 not for OOK)
        if let rttyAuralMonitor = rttyAuralMonitor, ook == 0 {
            rttyAuralMonitor.newBandpassFilteredData(outbuf, scale: outputScale, fromReceiver: false)
        }

        if equalizer != nil, ook == 0 {
            //  v0.85 don't equalize if OOK
            for i in 0..<Int(samples) { outbuf[i] *= equalize }
        }
        return 1        // output channels
    }

    @objc(setOutputScale:)
    override func setOutputScale(_ value: Float) {
        outputScale = value * modemObj.outputBoost      //  allow 2 dB boost
        afsk?.setOutputScale(outputScale)
    }

    @objc(openAuralMonitor:)
    func openAuralMonitor(_ sender: Any?) {
        //  override by subclasses that has an aural monitor
    }

    @objc(testToneChanged:)
    func testToneChanged(_ sender: Any?) {
        toneMatrix = sender as? NSMatrix
        let index = Int32(toneMatrix?.selectedColumn ?? 0)
        selectTestTone(index)
        if index != 0 {
            timeout = Timer.scheduledTimer(timeInterval: 3 * 60, target: self, selector: #selector(timedOut(_:)), userInfo: self, repeats: false)
        }
    }

    @objc(stopBitsChanged:)
    func stopBitsChanged(_ sender: Any?) {
        let index = (sender as? NSMatrix)?.selectedRow ?? 0
        if index >= 0 && index < RTTYTxConfig.stopDuration.count {
            afsk?.setStopBits(RTTYTxConfig.stopDuration[index])
        }
    }

    @objc(openEqualizer:)
    func openEqualizer(_ sender: Any?) {
        if let window = window { equalizer?.showMacroSheet(in: window) }
    }
}
