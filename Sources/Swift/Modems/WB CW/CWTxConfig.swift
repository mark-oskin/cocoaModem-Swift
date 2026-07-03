//
//  CWTxConfig.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/5/07.
//  Swift port of CWTxConfig.m.  CWTxConfig is a subclass of RTTYTxConfig (now
//  Swift) and uses a CWModulator for its afsk source.  The CW-specific control
//  entry points (setCarrier:, setSpeed:, setRisetime:weight:ratio:farnsworth:,
//  setModulationMode:, holdOff:, bufferEmpty) are called from WBCW.m.
//

import Cocoa

//  Convert an NSString* field of the (bridged) RTTYConfigSet C struct into a String
private func cmKey(_ u: Unmanaged<NSString>?) -> String? {
    guard let u = u else { return nil }
    return u.takeUnretainedValue() as String
}

@objc(CWTxConfig)
class CWTxConfig: RTTYTxConfig {

    //  test tone
    @IBOutlet var testFreq: NSTextField!

    override func awakeFromModem(_ set: UnsafeMutablePointer<RTTYConfigSet>, rttyRxControl control: AnyObject?) {
        rttyRxControl = control
        configSet = set.pointee

        transmitBPF = nil
        fir = nil
        hasSetupDefaultPreferences = false
        hasRetrieveForPlist = false
        hasUpdateFromPlist = false
        equalize = 1.0
        rttyAuralMonitor = nil          //  v0.78

        //  set output to defaults
        if let outputDevice = cmKey(configSet.outputDevice) {
            currentLow = 0
            currentHigh = 0
            afsk = CWModulator()
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

    //  -------------- transmit stream ---------------------
    override func startTransmit() -> Bool {
        //  adjust amplitude based on equalizer here
        if let tonepair = afsk?.toneFrequencies() {
            let midFrequency = tonepair.pointee.mark * 0.5
            equalize = Float(equalizer?.amplitude(Float(midFrequency)) ?? 1.0)
        }
        (afsk as? CWModulator)?.setGain(equalize)

        if ook != 0 { modemDest?.setOOKDeviceLevel() } else { _ = modemDest?.validateDeviceLevel() }

        if !isTransmit && !configOpen {
            toneIndex = 0
            modemDest?.stopSampling()
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

    @objc(transmitCharacter:)
    override func transmitCharacter(_ ascii: Int32) {
        if ascii == 0x5 {                                   // %[rx]
            (afsk as? CWModulator)?.insertEndOfTransmit()   //  v0.37 does not switch over immediately
            return
        }
        if ascii == 0x6 { return }                          //  ignore %[tx] for now

        afsk?.appendASCII(ascii)                            //  send character on to modulator
    }

    @objc(holdOff:)
    func holdOff(_ milliseconds: Int32) {
        (afsk as? CWModulator)?.holdOff(milliseconds)
    }

    @objc(bufferEmpty)
    func bufferEmpty() -> Bool {
        return (afsk as? CWModulator)?.bufferEmpty() ?? false
    }

    @objc(flushTransmitBuffer)
    override func flushTransmitBuffer() {
        afsk?.clearOutput()
    }

    @objc(setSpeed:)
    func setSpeed(_ speed: Float) {
        (afsk as? CWModulator)?.setSpeed(speed)
    }

    @objc(setCarrier:)
    func setCarrier(_ freq: Float) {
        (afsk as? CWModulator)?.setCarrier(freq)
    }

    @objc(setRisetime:weight:ratio:farnsworth:)
    func setRisetime(_ t: Float, weight w: Float, ratio r: Float, farnsworth f: Float) {
        (afsk as? CWModulator)?.setRisetime(t, weight: w, ratio: r, farnsworth: f)
    }

    //  v0.85
    @objc(setModulationMode:)
    func setModulationMode(_ index: Int32) {
        ook = (index != 0) ? 1 : 0
        (afsk as? CWModulator)?.setModulationMode(index)
    }

    @objc(needData:samples:)
    override func needData(_ outbuf: UnsafeMutablePointer<Float>!, samples: Int32) -> Int32 {
        return (afsk as? CWModulator)?.needData(outbuf, samples: samples) ?? 0
    }

    /* local */
    override func selectTestTone(_ index: Int32) {
        guard let toneMatrix = toneMatrix else { return }

        (afsk as? CWModulator)?.selectTestTone(index)

        toneMatrix.deselectAllCells()
        toneMatrix.selectCell(atRow: 0, column: Int(index))
        if let timeout = timeout {
            timeout.invalidate()
            self.timeout = nil
        }
        switch index {
        case 0:
            modemDest?.stopSampling()
            modemObj.executePTT(false)
            toneIndex = 0
        default:
            toneIndex = index
            let freq = testFreq?.floatValue ?? 0
            (afsk as? CWModulator)?.setTestFrequency(freq)
            modemObj.executePTT(true)
            modemDest?.startSampling()
        }
    }

    //  watchdog timer, turn test tone off
    @objc(timedOut:)
    override func timedOut(_ timer: Timer) {
        timeout = nil
        selectTestTone(0)
    }

    @objc(openAuralMonitor:)
    override func openAuralMonitor(_ sender: Any?) {
        if let application = (NSApp.delegate as? AppDelegate)?.application() {
            //  fetch the common aural monitor
            if let auralMonitor = application.auralMonitor() as? AuralMonitor {
                auralMonitor.showWindow()
            }
        }
    }

    @objc(testToneChanged:)
    override func testToneChanged(_ sender: Any?) {
        toneMatrix = sender as? NSMatrix
        let index = Int32(toneMatrix?.selectedColumn ?? 0)
        selectTestTone(index)
        if index != 0 {
            timeout = Timer.scheduledTimer(timeInterval: 3 * 60, target: self, selector: #selector(timedOut(_:)), userInfo: self, repeats: false)
        }
    }
}
