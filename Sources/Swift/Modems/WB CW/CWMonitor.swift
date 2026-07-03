//
//  CWMonitor.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/1/06.
//  Swift port of CWMonitor.m.
//
//  Subclass of DestClient (now Swift).  Nib-loaded (the WBCW nib instantiates it
//  and connects it to WBCW's `monitor` outlet), so every ivar becomes an
//  EXACT-named stored property and every `IBOutlet id` an @objc outlet reached
//  nil-tolerantly (?.).  The malloc'd CMFIR filters and the fixed C float buffers
//  (sidetoneBuf[1024], panoBuf[512], localLeftBuf[512], localRightBuf[512]) become
//  UnsafeMutablePointers allocated in -init and freed in deinit (the MRC original
//  had no dealloc and leaked them).  DSP math is preserved exactly, including the
//  original bug where the sub-channel non-pano branch pulls its sidetone from
//  receiver[0] instead of receiver[1].
//

import Cocoa

//  --- Plist keys (Plist.h #define'd @"..." macros; Swift cannot import NSString
//      macros so they are restated here with the exact string values) ---
private let kWBCWMainPitch        = "WBCW Main Pitch"
private let kWBCWSubPitch          = "WBCW Sub Pitch"
private let kWBCWTransmitPitch      = "WBCW Transmit Pitch"
private let kWBCWTransmitSidetone   = "WBCW Transmit Sidetone Enable"
private let kWBCWTransmitChannels   = "WBCW Transmit Channels"
private let kWBCWMainChannels       = "WBCW Main Channels"
private let kWBCWSubChannels        = "WBCW Sub Channels"
private let kWBCWPanoSeparation     = "WBCW Pano Separation"
private let kWBCWPanoBalance        = "WBCW Pano Balance"
private let kWBCWPanoReverse        = "WBCW Pano Reverse"
private let kWBCWMonitorActive      = "WBCW Monitor Active"
private let kWBCWTxSidetoneLevel    = "WBCW Tx Sidetone Level"
private let kWBCWMainSidetoneLevel  = "WBCW Main Sidetone Level"
private let kWBCWSubSidetoneLevel   = "WBCW Sub Sidetone Level"

@objc(CWMonitor)
class CWMonitor: DestClient {

    //  IBOutlet id -- shared between main and sub CWConfig (unused in code)
    @objc var monitorControl: AnyObject!
    @objc var monitorAttenuator: AnyObject!

    @objc var activeButton: NSButton!

    @objc var mainChannel: NSPopUpButton!
    @objc var mainPitch: NSTextField!
    @objc var subChannel: NSPopUpButton!
    @objc var subPitch: NSTextField!
    @objc var txChannel: NSPopUpButton!
    @objc var txPitch: NSTextField!
    @objc var txSidetoneEnable: NSButton!

    @objc var panoSeparation: NSControl!
    @objc var panoBalance: NSControl!
    @objc var panoReverseCheckbox: NSButton!

    var modem: WBCW!
    var receiver = [CWReceiver?](repeating: nil, count: 2)
    var auralMonitor: AuralMonitor!

    var transmitSidetone: CMPCO!
    //  filter for deglitching R/T transitions
    var leftTxFilter: UnsafeMutablePointer<CMFIR>!             //  v0.88  separate Rx and Tx filters
    var rightTxFilter: UnsafeMutablePointer<CMFIR>!            //  v0.88
    var leftRxFilter: UnsafeMutablePointer<CMFIR>!
    var rightRxFilter: UnsafeMutablePointer<CMFIR>!

    var running: Bool = false
    var mute: Bool = false
    var isWide = [Bool](repeating: false, count: 2)
    var isPano = [Bool](repeating: false, count: 2)
    var isEnabled = [Bool](repeating: false, count: 2)
    var allowSidetone = [Bool](repeating: false, count: 2)
    var sideband = [Int32](repeating: 0, count: 2)
    let sidetoneBuf = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
    let panoBuf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    var monitorGain = [Float](repeating: 0, count: 2)
    var mainChannels: Int32 = 0
    var subChannels: Int32 = 0
    var txChannels: Int32 = 0
    var separation: Float = 0
    var balance: Float = 0
    var agcGain = [Float](repeating: 0, count: 2)

    var activeState: Bool = false
    var modemVisible: Bool = false
    var transmitState: Bool = false
    var txSidetoneState: Bool = false
    var panoReversed: Bool = false

    var panoLow: UnsafeMutablePointer<CMFIR>!
    var panoHigh: UnsafeMutablePointer<CMFIR>!

    var accumulatedRx: Int32 = 0
    var accumulatedTx: Int32 = 0
    let localLeftBuf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    let localRightBuf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    var auralLockout: Int32 = 0

    @objc(setInterface:to:)
    func setInterface(_ object: NSControl?, to selector: Selector) {
        object?.action = selector
        object?.target = self
    }

    override init() {
        super.init()

        modem = nil
        receiver[0] = nil; receiver[1] = nil
        monitorGain[0] = 1.0; monitorGain[1] = 1.0
        sideband[0] = 1; sideband[1] = 1       //  default initially to USB
        auralMonitor = nil
        accumulatedRx = 0; accumulatedTx = 0
        auralLockout = 0
        localLeftBuf.initialize(repeating: 0, count: 512)
        localRightBuf.initialize(repeating: 0, count: 512)
        sidetoneBuf.initialize(repeating: 0, count: 1024)
        panoBuf.initialize(repeating: 0, count: 512)

        running = false; mute = false
        isWide[0] = false; isWide[1] = false
        isPano[0] = false; isPano[1] = false
        isEnabled[0] = false; isEnabled[1] = false
        allowSidetone[0] = false; allowSidetone[1] = false
        mainChannels = 3; subChannels = 3; txChannels = 3
        agcGain[0] = 0.3; agcGain[1] = 0.3
        activeState = false; modemVisible = false

        //  this smooths out the transitions when switched between Tx and Rx
        //  should be at least as wide as the wideband passband
        leftRxFilter = CMFIRLowpassFilter(2400.0, Float(CMFs), 64)      //  v0.88 separated Rx from Tx filters
        rightRxFilter = CMFIRLowpassFilter(2400.0, Float(CMFs), 64)     //  v0.88
        leftTxFilter = CMFIRLowpassFilter(2400.0, Float(CMFs), 64)      //  v0.88 separated Rx from Tx filters
        rightTxFilter = CMFIRLowpassFilter(2400.0, Float(CMFs), 64)     //  v0.88
        panoReversed = false

        transmitSidetone = CMPCO()
        transmitSidetone.setOutputScale(1.0)
        transmitSidetone.setCarrier(650)
        txSidetoneState = true
        transmitState = false

        //  create low and high pass filters for pano mode (sinc^2 impluse response to get tent LPF)
        panoLow = CMFIRLowpassFilter(880, Float(CMFs), 256)
        let kernel = panoLow.pointee.kernel!
        for i in 0..<Int(panoLow.pointee.activeTaps) { kernel[i] = kernel[i] * kernel[i] * 4.0 }
        panoHigh = CMFIRLowpassFilter(880, Float(CMFs), 256)
        for i in 0..<Int(panoHigh.pointee.activeTaps) {
            let t = fabs(Double(i) - Double(panoHigh.pointee.activeTaps) * 0.5) * 2.0 * 3.1415926535 * 2400.0 / Double(CMFs)  //  center highpass at 2400 Hz
            panoHigh.pointee.kernel[i] = kernel[i] * Float(cos(t))
        }
    }

    deinit {
        if leftRxFilter != nil { CMDeleteFIR(leftRxFilter) }
        if rightRxFilter != nil { CMDeleteFIR(rightRxFilter) }
        if leftTxFilter != nil { CMDeleteFIR(leftTxFilter) }
        if rightTxFilter != nil { CMDeleteFIR(rightTxFilter) }
        if panoLow != nil { CMDeleteFIR(panoLow) }
        if panoHigh != nil { CMDeleteFIR(panoHigh) }
        sidetoneBuf.deallocate()
        panoBuf.deallocate()
        localLeftBuf.deallocate()
        localRightBuf.deallocate()
    }

    @objc override func awakeFromNib() {
        setInterface(txPitch, to: #selector(sidetoneFrequencyChanged))
        setInterface(txSidetoneEnable, to: #selector(sidetoneFrequencyChanged))
        setInterface(mainPitch, to: #selector(sidetoneFrequencyChanged))
        setInterface(subPitch, to: #selector(sidetoneFrequencyChanged))
        setInterface(mainChannel, to: #selector(channelSelectionChanged))
        setInterface(subChannel, to: #selector(channelSelectionChanged))
        setInterface(txChannel, to: #selector(channelSelectionChanged))
        setInterface(panoSeparation, to: #selector(panoParamsChanged))
        setInterface(panoBalance, to: #selector(panoParamsChanged))
        setInterface(panoReverseCheckbox, to: #selector(panoParamsChanged))
        setInterface(activeButton, to: #selector(activeChanged))
    }

    @objc(setupMonitor:modem:main:sub:)
    func setupMonitor(_ deviceName: String!, modem cwModem: WBCW!, main: CWReceiver!, sub: CWReceiver!) {
        modem = cwModem
        receiver[0] = main
        receiver[1] = sub

        if let application = modem?.application() {
            //  fetch the common aural monitor
            auralMonitor = application.auralMonitor() as? AuralMonitor
        }
    }

    @objc func sidetoneFrequencyChanged() {
        receiver[0]?.setSidetoneFrequency(mainPitch?.floatValue ?? 0)
        receiver[1]?.setSidetoneFrequency(subPitch?.floatValue ?? 0)
        //  set tx pitch to 0 to disable
        txSidetoneState = (txSidetoneEnable?.state == .on)
        transmitSidetone.setCarrier(txPitch?.floatValue ?? 0)
    }

    //  the tag of the menu item carries the two bits to lelect left (0x01) or right (0x02) [or both bits set]
    @objc func channelSelectionChanged() {
        mainChannels = Int32(mainChannel?.selectedItem?.tag ?? 0)
        subChannels = Int32(subChannel?.selectedItem?.tag ?? 0)
        txChannels = Int32(txChannel?.selectedItem?.tag ?? 0)
    }

    @objc func panoParamsChanged() {
        separation = panoSeparation?.floatValue ?? 0
        balance = panoBalance?.floatValue ?? 0
        panoReversed = (panoReverseCheckbox?.state == .on)
    }

    @objc func updateSoundState() {
        if auralMonitor == nil { return }

        let state = ((allowSidetone[0] && isEnabled[0]) || (allowSidetone[1] && isEnabled[1])) && activeState && modemVisible

        if state == true {
            if running { return }
            running = true
            auralMonitor.addClient(self)
        } else {
            if !running { return }
            running = false
            auralMonitor.removeClient(self)
        }
    }

    @objc func activeChanged() {
        activeState = (activeButton?.state == .on)
        receiver[0]?.setMonitorEnable(activeState)
        receiver[1]?.setMonitorEnable(activeState)
        activeButton?.title = activeState ? NSLocalizedString("Active", comment: "") : NSLocalizedString("Inactive", comment: "")
        updateSoundState()
    }

    @objc(setVisibleState:)
    func setVisibleState(_ state: Bool) {
        modemVisible = state
        updateSoundState()
    }

    @objc(enableSidetone:index:)
    func enableSidetone(_ state: Bool, index n: Int32) {
        allowSidetone[Int(n)] = state
        updateSoundState()
    }

    @objc(sidebandChanged:index:)
    func sidebandChanged(_ state: Int32, index n: Int32) {
        if n >= 0 && n < 2 { sideband[Int(n)] = state }
    }

    @objc(setMute:)
    func setMute(_ state: Bool) {
        mute = state
    }

    @objc(enableWide:index:)
    func enableWide(_ state: Bool, index n: Int32) {
        if n >= 0 && n < 2 { isWide[Int(n)] = state }
    }

    @objc(enablePano:index:)
    func enablePano(_ state: Bool, index n: Int32) {
        if n >= 0 && n < 2 { isPano[Int(n)] = state }
    }

    @objc(setEnabled:index:)
    func setEnabled(_ state: Bool, index n: Int32) {
        if n >= 0 && n < 2 { isEnabled[Int(n)] = state }
        updateSoundState()
    }

    @objc(monitorLevel:index:)
    func monitorLevel(_ value: Float, index n: Int32) {
        if n >= 0 && n < 2 { monitorGain[Int(n)] = value }
    }

    //  update agc (unused in the original; retained for fidelity)
    func agc(_ buf: UnsafeMutablePointer<Float>, _ n: Int32, _ lowmean: UnsafeMutablePointer<Float>, _ highmean: UnsafeMutablePointer<Float>) {
        var m: Float = 0
        for i in 0..<Int(n) { m += abs(buf[i]) }
        m /= Float(n)
        var p = m
        var s = m
        var j: Int32 = 1
        var k: Int32 = 1
        for i in 0..<Int(n) {
            let v = abs(buf[i])
            if v > m {
                p += v
                j += 1
            } else {
                s += v
                k += 1
            }
        }
        p /= Float(j)
        s /= Float(k)
        lowmean.pointee = s
        highmean.pointee = p
    }

    @objc(addLeft:right:state:)
    func addLeft(_ leftbuf: UnsafeMutablePointer<Float>, right rightbuf: UnsafeMutablePointer<Float>, state pushState: Int32) {
        if accumulatedRx == 0 && accumulatedTx == 0 {
            memcpy(localLeftBuf, leftbuf, 512 * MemoryLayout<Float>.size)
            memcpy(localRightBuf, rightbuf, 512 * MemoryLayout<Float>.size)
            if pushState == 1 { accumulatedRx = 1 } else { accumulatedTx = 1 }
            return
        }
        if pushState == 1 && accumulatedRx > 0 {
            //  flush
            auralMonitor.addLeft(localLeftBuf, right: localRightBuf, samples: 512, client: self)
            memcpy(localLeftBuf, leftbuf, 512 * MemoryLayout<Float>.size)
            memcpy(localRightBuf, rightbuf, 512 * MemoryLayout<Float>.size)
            accumulatedRx = 1
            accumulatedTx = 0
            return
        }
        if pushState == 2 && accumulatedTx > 0 {
            //  flush
            auralMonitor.addLeft(localLeftBuf, right: localRightBuf, samples: 512, client: self)
            memcpy(localLeftBuf, leftbuf, 512 * MemoryLayout<Float>.size)
            memcpy(localRightBuf, rightbuf, 512 * MemoryLayout<Float>.size)
            accumulatedRx = 0
            accumulatedTx = 1
            return
        }
        if (pushState == 1 && accumulatedTx > 0) || (pushState == 2 && accumulatedRx > 0) {
            for i in 0..<512 {
                localLeftBuf[i] += leftbuf[i]
                localRightBuf[i] += rightbuf[i]
            }
            //  flush
            auralMonitor.addLeft(localLeftBuf, right: localRightBuf, samples: 512, client: self)
            accumulatedRx = 0; accumulatedTx = 0
            return
        }

        //  flush
        auralMonitor.addLeft(localLeftBuf, right: localRightBuf, samples: 512, client: self)
        memcpy(localLeftBuf, leftbuf, 512 * MemoryLayout<Float>.size)
        memcpy(localRightBuf, rightbuf, 512 * MemoryLayout<Float>.size)
        accumulatedRx = 0; accumulatedTx = 0
        if pushState == 1 { accumulatedRx = 1 } else { accumulatedTx = 1 }
    }

    //  v0.78  aural received changed to push model, using the common AuralMonitor
    @objc(push:quadrature:wide:samples:)
    func push(_ inph: UnsafeMutablePointer<Float>!, quadrature quad: UnsafeMutablePointer<Float>!, wide: UnsafeMutablePointer<Float>!, samples n: Int32) {
        var n = n

        if !running || mute {
            //  if not running, return zeros, left channel only
            return
        }
        if n > 512 { n = 512 }                                  //  sanity check

        if isEnabled[0] == false && isEnabled[1] == false { return }

        //  transmit aural monitor sets auralLockout so both transmit and receive won't be sent to the monitor at the same time
        if auralLockout > 0 {
            auralLockout -= 1
            if auralLockout > 4 { auralLockout = 4 }        //  sanity check
            return
        }

        let leftBuf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let rightBuf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let leftOutbuf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let rightOutbuf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer {
            leftBuf.deallocate(); rightBuf.deallocate()
            leftOutbuf.deallocate(); rightOutbuf.deallocate()
        }

        leftBuf.initialize(repeating: 0, count: 512)
        rightBuf.initialize(repeating: 0, count: 512)

        //  main channel
        if isEnabled[0] {
            if isWide[0] && isPano[0] {
                // pano (reverse for LSB)
                receiver[0]?.needSidetone(panoBuf, inphase: inph, quadrature: quad, wide: wide, samples: n, wide: true)
                CMPerformFIR(panoLow, panoBuf, 512, sidetoneBuf)
                CMPerformFIR(panoHigh, panoBuf, 512, sidetoneBuf + 512)

                //  blend for separation
                let t = 1.0 - separation
                for i in 0..<512 {
                    let save = sidetoneBuf[i]
                    sidetoneBuf[i] = separation * sidetoneBuf[i] + t * sidetoneBuf[i + 512]
                    sidetoneBuf[i + 512] = separation * sidetoneBuf[i + 512] + t * save
                }
                //  left channel
                var offset = panoReversed ? 512 : 0
                var gain = monitorGain[0] * (1.0 - balance)
                if sideband[0] == 0 { offset = 512 - offset }
                var buf = sidetoneBuf + offset
                for i in 0..<Int(n) { leftBuf[i] += buf[i] * gain }

                //  right channel
                offset = panoReversed ? 0 : 512
                gain = monitorGain[0] * (1.0 + balance)
                if sideband[0] == 0 { offset = 512 - offset }
                buf = sidetoneBuf + offset
                for i in 0..<Int(n) { rightBuf[i] += buf[i] * gain }
            } else {
                //  non-pano
                receiver[0]?.needSidetone(sidetoneBuf, inphase: inph, quadrature: quad, wide: wide, samples: n, wide: isWide[0])
                let gain = monitorGain[0] * (isWide[0] ? 0.316 : (0.6 / agcGain[0]))         // -16 dB for wideband

                if mainChannels == 0x01 {
                    // left channel
                    for i in 0..<Int(n) { leftBuf[i] += gain * sidetoneBuf[i] }
                } else if mainChannels == 0x02 {
                    // right channel
                    for i in 0..<Int(n) { rightBuf[i] += gain * sidetoneBuf[i] }
                } else if mainChannels == 0x03 {
                    // left and right channels
                    for i in 0..<Int(n) {
                        let v = gain * sidetoneBuf[i]
                        leftBuf[i] += v
                        rightBuf[i] += v
                    }
                }
            }
        }
        //  sub channel
        if isEnabled[1] {
            if isWide[1] && isPano[1] {
                // pano (reverse for LSB)
                receiver[1]?.needSidetone(panoBuf, inphase: inph, quadrature: quad, wide: wide, samples: n, wide: true)
                CMPerformFIR(panoLow, panoBuf, 512, sidetoneBuf)
                CMPerformFIR(panoHigh, panoBuf, 512, sidetoneBuf + 512)

                //  blend for separation
                let t = 1.0 - separation
                for i in 0..<512 {
                    let save = sidetoneBuf[i]
                    sidetoneBuf[i] = separation * sidetoneBuf[i] + t * sidetoneBuf[i + 512]
                    sidetoneBuf[i + 512] = separation * sidetoneBuf[i + 512] + t * save
                }
                //  left channel
                var offset = panoReversed ? 512 : 0
                var gain = monitorGain[1] * (1.0 - balance)
                if sideband[1] == 0 { offset = 512 - offset }
                var buf = sidetoneBuf + offset
                for i in 0..<Int(n) { leftBuf[i] += buf[i] * gain }

                //  right channel
                offset = panoReversed ? 0 : 512
                gain = monitorGain[1] * (1.0 + balance)
                if sideband[1] == 0 { offset = 512 - offset }
                buf = sidetoneBuf + offset
                for i in 0..<Int(n) { rightBuf[i] += buf[i] * gain }
            } else {
                //  non-pano
                receiver[0]?.needSidetone(sidetoneBuf, inphase: inph, quadrature: quad, wide: wide, samples: n, wide: isWide[1])
                let gain = monitorGain[1] * (isWide[1] ? 0.316 : (0.6 / agcGain[1]))         // -16 dB for wideband

                if subChannels == 0x01 {
                    // left channel
                    for i in 0..<Int(n) { leftBuf[i] += gain * sidetoneBuf[i] }
                } else if subChannels == 0x02 {
                    // right channel
                    for i in 0..<Int(n) { rightBuf[i] += gain * sidetoneBuf[i] }
                } else if subChannels == 0x03 {
                    // left and right channels
                    for i in 0..<Int(n) {
                        let v = gain * sidetoneBuf[i]
                        leftBuf[i] += v
                        rightBuf[i] += v
                    }
                }
            }
        }
        for i in 0..<Int(n) { leftOutbuf[i] = CMSimpleFilter(leftRxFilter, leftBuf[i]) }
        for i in 0..<Int(n) { rightOutbuf[i] = CMSimpleFilter(rightRxFilter, rightBuf[i]) }

        addLeft(leftOutbuf, right: rightOutbuf, state: 1)
    }

    //  v0.78  transmit sidetone changed to push model, using the common AuralMonitor
    @objc(transmitted:samples:)
    func transmitted(_ keyed: UnsafeMutablePointer<Float>!, samples n: Int32) {
        if n != 512 { return }

        auralLockout = 2

        if !running || mute || txSidetoneState == false {
            //  if not running, no need to push data to aural monitor
            return
        }

        let buf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let leftbuf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let rightbuf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { buf.deallocate(); leftbuf.deallocate(); rightbuf.deallocate() }

        for i in 0..<512 {
            //  nextSample() is a Double; compute in double then truncate to float (as the C did)
            buf[i] = Float(Double(keyed[i]) * transmitSidetone.nextSample() * 0.1)
        }

        if txChannels & 0x01 != 0 {
            // left channel
            for i in 0..<512 { leftbuf[i] = CMSimpleFilter(leftTxFilter, buf[i]) }
        } else {
            for i in 0..<512 { leftbuf[i] = CMSimpleFilter(leftTxFilter, 0.0) }
        }

        //  v0.88 bug fix, was writing into [i+n] instead of [i]
        if txChannels & 0x02 != 0 {
            // right channel
            for i in 0..<512 { rightbuf[i] = CMSimpleFilter(rightTxFilter, buf[i]) }
        } else {
            for i in 0..<512 { rightbuf[i] = CMSimpleFilter(rightTxFilter, 0.0) }
        }

        addLeft(leftbuf, right: rightbuf, state: 2)
    }

    @objc(changeTransmitStateTo:)
    func changeTransmitState(to state: Bool) {
        transmitState = state
    }

    //  this is no longer needed in the push model
    @objc(needData:samples:)
    override func needData(_ outbuf: UnsafeMutablePointer<Float>!, samples n: Int32) -> Int32 {
        NSLog("CWMonitor needData called, should no longer be called.")
        return n
    }

    @objc(setupDefaultPreferences:)
    func setupDefaultPreferences(_ pref: Preferences!) {
        pref.setInt(650, forKey: kWBCWMainPitch)
        pref.setInt(750, forKey: kWBCWSubPitch)
        pref.setInt(700, forKey: kWBCWTransmitPitch)
        pref.setInt(1, forKey: kWBCWTransmitSidetone)
        pref.setInt(3, forKey: kWBCWTransmitChannels)
        pref.setInt(3, forKey: kWBCWMainChannels)
        pref.setInt(0, forKey: kWBCWSubChannels)
        pref.setFloat(0.75, forKey: kWBCWPanoSeparation)
        pref.setFloat(0, forKey: kWBCWPanoBalance)
        pref.setInt(0, forKey: kWBCWPanoReverse)
        pref.setInt(0, forKey: kWBCWMonitorActive)
        pref.setFloat(0, forKey: kWBCWTxSidetoneLevel)
        pref.setFloat(0, forKey: kWBCWMainSidetoneLevel)
        pref.setFloat(0, forKey: kWBCWSubSidetoneLevel)
    }

    @objc(updateFromPlist:)
    @discardableResult
    func updateFromPlist(_ pref: Preferences!) -> Bool {
        txPitch?.intValue = pref.intValue(forKey: kWBCWTransmitPitch)
        txSidetoneEnable?.intValue = pref.intValue(forKey: kWBCWTransmitSidetone)
        mainPitch?.intValue = pref.intValue(forKey: kWBCWMainPitch)
        subPitch?.intValue = pref.intValue(forKey: kWBCWSubPitch)
        sidetoneFrequencyChanged()

        txChannel?.selectItem(withTag: Int(pref.intValue(forKey: kWBCWTransmitChannels)))
        mainChannel?.selectItem(withTag: Int(pref.intValue(forKey: kWBCWMainChannels)))
        subChannel?.selectItem(withTag: Int(pref.intValue(forKey: kWBCWSubChannels)))
        channelSelectionChanged()

        panoSeparation?.floatValue = pref.floatValue(forKey: kWBCWPanoSeparation)
        panoBalance?.floatValue = pref.floatValue(forKey: kWBCWPanoBalance)
        panoReverseCheckbox?.state = (pref.intValue(forKey: kWBCWPanoReverse) != 0) ? .on : .off
        panoParamsChanged()

        activeButton?.state = (pref.intValue(forKey: kWBCWMonitorActive) != 0) ? .on : .off
        activeChanged()

        return true
    }

    @objc(retrieveForPlist:)
    func retrieveForPlist(_ pref: Preferences!) {
        pref.setInt(mainPitch?.intValue ?? 0, forKey: kWBCWMainPitch)
        pref.setInt(subPitch?.intValue ?? 0, forKey: kWBCWSubPitch)
        pref.setInt(txPitch?.intValue ?? 0, forKey: kWBCWTransmitPitch)
        pref.setInt((txSidetoneEnable?.state == .on) ? 1 : 0, forKey: kWBCWTransmitSidetone)

        pref.setInt(Int32(mainChannel?.selectedItem?.tag ?? 0), forKey: kWBCWMainChannels)
        pref.setInt(Int32(subChannel?.selectedItem?.tag ?? 0), forKey: kWBCWSubChannels)

        pref.setFloat(panoSeparation?.floatValue ?? 0, forKey: kWBCWPanoSeparation)
        pref.setFloat(panoBalance?.floatValue ?? 0, forKey: kWBCWPanoBalance)
        pref.setInt((panoReverseCheckbox?.state == .on) ? 1 : 0, forKey: kWBCWPanoReverse)

        pref.setInt((activeButton?.state == .on) ? 1 : 0, forKey: kWBCWMonitorActive)
    }

    @objc(terminate)
    func terminate() {
        running = false
        auralMonitor?.removeClient(self)
    }
}
