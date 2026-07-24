//
//  PSKReceiver.swift
//  cocoaModem
//
//  Created by Kok Chen on Thu Sep 02 2004.
//  Swift port of PSKReceiver.m.
//
//  NIB-loaded (loads "PSKReceiver").  Outlets keep their EXACT names as
//  @objc IBOutlet properties.  The receive thread is preserved exactly
//  (detachNewThreadSelector + NSConditionLock on kNoData/kHasData); the old
//  manual NSAutoreleasePool drain (with its Gestalt Snow-Leopard guard and the
//  private delayedRelease ivar) is replaced by a per-iteration autoreleasepool {}.
//  The malloc'd click buffers (float*[512]) and the two 128 KB Shift-JIS tables
//  (unsigned char[65536*2]) become UnsafeMutablePointer buffers freed in deinit.
//
//  enum LockCondition { kNoData, kHasData } (formerly from RTTYReceiver.h) is now
//  the module-scope kNoData/kHasData defined in RTTYReceiver.swift.
//

import Cocoa
import Accelerate                       //  DSPSplitComplex

//  kPSKBrowserWindowPosition / kPSKBrowserSquelch were #define @"..." string
//  macros in Plist.h, which the Swift importer does not surface, so the literal
//  values are inlined here (kept identical to Plist.h).
private let kPSKBrowserWindowPosition = "PSK Browser Window Position"
private let kPSKBrowserSquelch = "PSK Browser Squelch"

//  transmit light state (were #defines in PSKReceiver.h)
private let TxOff: Int32 = 0
private let TxReady: Int32 = 1
private let TxWait: Int32 = 2
private let TxActive: Int32 = 3

//  Phi (slashed-zero glyph): #define Phi 0xd8 in cocoaModemParams.h.
private let Phi: Int32 = 0xd8

@objc(PSKReceiver)
class PSKReceiver: CMPipe {

    @objc var controlView: NSView!              //  receiver controls
    @objc var freqIndicator: FrequencyIndicator!
    @objc var phaseIndicator: PhaseIndicator!
    @objc var rxFrequencyField: NSTextField!
    @objc var txFrequencyField: NSTextField!
    @objc var IMDField: NSTextField!
    @objc var transmitLight: NSTextField!

    @objc var browserTable: NSTableView!
    @objc var browserSquelch: NSControl!
    var pskHub: PSKHub!
    var pskBrowserHub: PSKBrowserHub!

    var client: Modem!
    var uniqueID: Int32 = 0
    var lock: NSLock!
    var monitor: PSKMonitor!

    var extendedASCII: Bool = false

    var squelchHold: Int32 = 0
    let clickBuffer: UnsafeMutablePointer<UnsafeMutablePointer<Float>?> = {
        let p = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 512)
        p.initialize(repeating: nil, count: 512)
        return p
    }()
    var clickBufferProducer: Int32 = 0
    var clickBufferConsumer: Int32 = 0
    var clickBufferLock: NSLock!
    var overrunLock: NSLock!
    var newData: NSConditionLock!

    let cmData = UnsafeMutablePointer<CMDataStream>.allocate(capacity: 1)
    //  user controls
    var control: PSKControl!

    //  textview
    var receiveView: ExchangeView!
    var appleScript: Module!

    var vfoOffset: Float = 0
    var sideband: Bool = false                  //  NO == LSB
    var displayedRxFrequency: Float = 0
    var displayedTxFrequency: Float = 0
    var currentFrequency: Float = 0

    var transferToTransmitFreq: Bool = false

    var mux: Int32 = 0
    var slashZero: Bool = false

    //  Shift-JIS
    let jisToUnicode = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536 * 2)
    let unicodeToJis = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536 * 2)
    var useShiftJIS: Bool = false
    var useRawOutput: Bool = false
    var doubleByteIndex: Int32 = 0
    var doubleByteValue = [Int32](repeating: 0, count: 16)
    var lastASCII: Int32 = 0                     //  use to detect \r\n and \n\r

    //  transmitter
    var transmitFrequency: Float = 0
    var txOff: NSColor!
    var txReady1: NSColor!
    var txReady0: NSColor!
    var txWait: NSColor!
    var txActive: NSColor!
    var indicatorState: Int32 = 0

    //  C truncated (finite) float->int toward zero; guard NaN/inf (see DisplayColor.cInt).
    private func cInt(_ x: Float) -> Int32 {
        if x.isNaN { return 0 }
        if x >= 2147483647.0 { return Int32.max }
        if x <= -2147483648.0 { return Int32.min }
        return Int32(x)
    }

    //  (Private API)
    private func printable(_ character: Int32, extended: Int32) -> Int32 {
        var character = character
        let previous = lastASCII
        lastASCII = character

        if character == 0o10 { return character }

        if character == 0x0d /* '\r' */ {
            if previous != 0x0a { return 0x0a }
            //  suppress
            lastASCII = -1
            return 0
        }
        if character == 0x0a /* '\n' */ {
            if previous != 0x0d { return 0x0a }
            //  suppress
            lastASCII = -1
            return 0
        }
        if character >= 32 && character < 128 { return character }
        //  HTML extended ASCII
        if extended != 0 {
            if character > 159 && character < 256 { return character }
            if character == 145 || character == 146 { return character }
        }
        character = 0
        return character
    }

    private func loadReceiver(_ view: NSView?, index: Int32) -> Bool {
        if Bundle.main.loadNibNamed("PSKReceiver", owner: self, topLevelObjects: nil) {
            //  loadNib should have set up controlView connection
            if let view = view, let cv = controlView { view.addSubview(cv) }

            transmitFrequency = 10          //  stay away from active signals
            vfoOffset = 0
            sideband = false
            monitor = PSKMonitor()
            monitor.setTitle("PSK Monitor")
            //  set up rx field
            rxFrequencyField?.stringValue = NSLocalizedString("Off", comment: "")
            rxFrequencyField?.action = #selector(rxFieldChanged)
            rxFrequencyField?.target = self
            //  set up tx field
            txFrequencyField?.stringValue = ""
            txFrequencyField?.action = #selector(txFieldChanged)
            txFrequencyField?.target = self
            //  tx light
            setTransmitLightState(TxOff)
            return true
        }
        return false
    }

    @objc(initIntoView:client:index:)
    init?(intoView view: NSView?, client modem: Modem?, index: Int32) {
        cmData.initialize(to: CMDataStream())
        jisToUnicode.initialize(repeating: 0, count: 65536 * 2)
        unicodeToJis.initialize(repeating: 0, count: 65536 * 2)

        super.init()

        //  v0.70
        useShiftJIS = false
        useRawOutput = false
        doubleByteIndex = 0
        lastASCII = -1
        //  v0.57b -- PSKDemodulator is now behind the PSKHub
        pskHub = PSKHub(hub: ())
        pskHub.setDelegate(self)

        pskBrowserHub = nil
        if index == 0 {
            pskBrowserHub = PSKBrowserHub(hub: ())
            pskBrowserHub.setDelegate(self)
        }

        //  local CMDataStream
        cmData.pointee.samplingRate = 11025.0
        cmData.pointee.samples = 512
        cmData.pointee.components = 1
        cmData.pointee.channels = 1
        data = cmData

        uniqueID = index
        client = modem
        pskHub.setPSKModem(modem as? PSK, index: uniqueID)   //  v0.78

        slashZero = false
        extendedASCII = true
        txOff = NSColor(calibratedWhite: 0.5, alpha: 1.0)
        txReady0 = NSColor.green
        txReady1 = NSColor.magenta
        txWait = NSColor.yellow
        txActive = NSColor.red

        displayedRxFrequency = -1
        displayedTxFrequency = -1
        receiveView = nil
        control = nil
        appleScript = nil
        squelchHold = 0

        mux = 0
        transferToTransmitFreq = true

        //  create history buffer (blocks of 512 samples)
        clickBufferProducer = 0
        clickBufferConsumer = 0
        clickBufferLock = NSLock()
        for i in 0..<512 {
            //  1 MB buffer, for 262,144 floating point samples (23.77 seconds)
            clickBuffer[i] = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        }
        overrunLock = NSLock()
        lock = NSLock()
        newData = NSConditionLock(condition: kNoData)

        Thread.detachNewThreadSelector(#selector(receiveThread(_:)), toTarget: self, with: self)
        if loadReceiver(view, index: index) { return }
        return nil
    }

    deinit {
        for i in 0..<512 {
            if let p = clickBuffer[i] { p.deallocate() }
        }
        clickBuffer.deallocate()
        jisToUnicode.deallocate()
        unicodeToJis.deallocate()
        cmData.deinitialize(count: 1)
        cmData.deallocate()
    }

    //  v0.70
    @objc(setUseShiftJIS:)
    func setUseShiftJIS(_ state: Bool) {
        useShiftJIS = state
        pskBrowserHub?.setUseShiftJIS(DarwinBoolean(state))     //  for TableView printing
    }

    //  v0.70
    @objc(useShiftJIS)
    func useShiftJIS_() -> Bool {
        return useShiftJIS
    }

    //  v0.70
    @objc(setUseRawForPSK:)
    func setUseRawForPSK(_ state: Bool) {
        useRawOutput = state
    }

    //  v0.70
    @objc(setJisToUnicodeTable:)
    func setJisToUnicodeTable(_ uarray: UnsafeMutablePointer<UInt8>) {
        memcpy(jisToUnicode, uarray, 65536 * 2)
        pskBrowserHub?.setJisToUnicodeTable(uarray)
    }

    //  v0.70
    @objc(setUnicodeToJisTable:)
    func setUnicodeToJisTable(_ uarray: UnsafeMutablePointer<UInt8>) {
        memcpy(unicodeToJis, uarray, 65536 * 2)
    }

    @objc(controlModem)
    func controlModem() -> PSK! {      //  v0.57b
        return client as? PSK
    }

    @objc(enableTableView:)
    func enableTableView(_ state: Bool) {
        if state == true { pskBrowserHub?.enableTableView() } else { pskBrowserHub?.disableTableView() }   //  v0.97
    }

    //  v0.97
    @objc(nextStationInTableView)
    func nextStationInTableView() {
        pskBrowserHub?.nextStationInTableView()
    }

    //  v1.01c
    @objc(previousStationInTableView)
    func previousStationInTableView() {
        pskBrowserHub?.previousStationInTableView()
    }

    @objc override func awakeFromNib() {
        if uniqueID == 0 && pskBrowserHub != nil {
            pskBrowserHub.setBrowserTable(browserTable)
        }
    }

    //  v0.89
    @objc(clearClickBuffer)
    func clearClickBuffer() {
        //  clickBuffer base is always allocated; original `if ( clickBuffer != nil )`
        //  is always true.
        clickBufferLock.lock()
        clickBufferProducer = 0
        clickBufferConsumer = 0
        clickBufferLock.unlock()
    }

    //  sends output of click buffer to PSKHub
    @objc(receiveThread:)
    func receiveThread(_ ourself: Any?) {
        Thread.setThreadPriority(Thread.current.threadPriority * 0.95)   //  lower thread priority

        while true {
            autoreleasepool {
                //  block here waiting for data
                newData.lock(whenCondition: kHasData)
                if pskHub.demodulatorEnabled() {
                    //  process 8 click buffers as fast as possible until the stream has caught up
                    for _ in 0..<8 {
                        if clickBufferConsumer == clickBufferProducer { break }
                        //  push out unprocessed data
                        cmData.pointee.array = clickBuffer[Int(clickBufferConsumer)]
                        clickBufferConsumer = (clickBufferConsumer + 1) & 0x1ff  //  wrap around a 256K (512*512 sample) buffer
                        pskHub.importData(self)
                    }
                }
                newData.unlock(withCondition: kNoData)      //  v0.62
            }
        }
    }

    //  audio data is sent here from PSK.m
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        if overrunLock.try() {
            newData.lock(whenCondition: kNoData)
            let buf = clickBuffer[Int(clickBufferProducer)]
            clickBufferProducer = (clickBufferProducer + 1) & 0x1ff  //  wrap around a 256K (512*512 sample) buffer

            if pskBrowserHub != nil {
                //  TableView
                let hubBuf = clickBuffer[Int((clickBufferProducer - 9 + 0x200) & 0x1ff)]
                pskBrowserHub.importBuffer(hubBuf!)
            }

            //  copy data into tail of clickBuffer
            let stream = pipe.stream()
            let array = stream!.pointee.array
            //  copy another 512 samples into the click buffer
            memcpy(buf, array, 512 * MemoryLayout<Float>.size)
            //  run the receive thread
            cmData.pointee.userData = stream!.pointee.userData
            cmData.pointee.sourceID = stream!.pointee.sourceID
            //  signal receiveThread that new data has arrived
            newData.unlock(withCondition: kHasData)
            overrunLock.unlock()
        }
    }

    @objc(useSlashedZero:)
    func useSlashedZero(_ state: Bool) {
        slashZero = state
    }

    @objc(isEnabled)
    func isEnabled() -> Bool {
        return pskHub.demodulatorEnabled()
    }

    @objc(setExchangeView:)
    func setExchangeView(_ eview: ExchangeView!) {
        receiveView = eview
    }

    @objc(registerModule:)
    func registerModule(_ module: Module!) {
        appleScript = module
    }

    @objc(enableReceiver:)
    func enableReceiver(_ state: Bool) {
        pskHub.enableReceiver(state)
        pskBrowserHub?.enableReceiver(state)
        if state == false {
            freqIndicator?.clear()
            phaseIndicator?.clear()
            rxFrequencyField?.stringValue = NSLocalizedString("Off", comment: "")
            txFrequencyField?.stringValue = ""
            IMDField?.stringValue = ""
            client.application()?.clearVoiceChannel(uniqueID + 1)   //  v0.96d voice synthesizer
        }
        //  update indicator light
        setTransmitLightState(indicatorState)
    }

    @objc(currentTransmitFrequency)
    func currentTransmitFrequency() -> Float {
        return transmitFrequency
    }

    @objc(setPSKControl:)
    func setPSKControl(_ inControl: PSKControl!) {
        control = inControl
    }

    private func displayFrequency(_ freq: Float, on field: NSTextField!) {
        field?.stringValue = String(format: "%.1f", freq)
    }

    //  called from NewPSKDemodulator when AFC updates
    @objc(setReceiveFrequency:)
    func setReceiveFrequency(_ freq: Float) {
        displayFrequency(freq, on: rxFrequencyField)
    }

    @objc(updateReceiveFrequencyDisplay:)
    func updateReceiveFrequencyDisplay(_ tone: Float) {
        var freq: Float = sideband ? tone - vfoOffset : vfoOffset - tone
        let p = cInt(freq * 10)
        freq = Float(p) * 0.1
        if freq != displayedRxFrequency {
            if rxFrequencyField.floatValue != freq { displayFrequency(freq, on: rxFrequencyField) }
            (client as? PSK)?.frequencyUpdatedTo(tone, receiver: uniqueID)
        }
        displayedRxFrequency = freq
    }

    @objc(updateTransmitFrequencyDisplay:)
    func updateTransmitFrequencyDisplay(_ tone: Float) {
        var freq: Float = sideband ? tone - vfoOffset : vfoOffset - tone
        let p = cInt(freq * 10)
        freq = Float(p) * 0.1
        if freq != displayedTxFrequency {
            displayFrequency(freq, on: txFrequencyField)
        }
        displayedTxFrequency = freq
    }

    //  check if transmit is within range
    @objc(canTransmit)
    func canTransmit() -> Bool {
        return pskHub.demodulatorEnabled() && transmitFrequency > 250 && transmitFrequency < 4800   //  v0.68
    }

    @objc(setTransmitLightState:)
    func setTransmitLightState(_ state: Int32) {
        var color: NSColor

        indicatorState = state
        if !canTransmit() {
            color = txOff
        } else {
            switch state {
            case TxReady:
                color = (uniqueID == 0) ? txReady0 : txReady1   //  0 - Green, 1 - Magenta
            case TxWait:
                color = txWait
            case TxActive:
                color = txActive
            default:    //  TxOff
                color = txOff
            }
        }
        transmitLight?.backgroundColor = color
    }

    //  callback from VCO
    @objc(vcoChangedTo:)
    func vcoChanged(to vcoFreq: Float) {
        let tone = vcoFreq
        pskHub.setReceiveFrequency(tone)
        updateReceiveFrequencyDisplay(tone)
    }

    @objc(setPSKMode:)
    func setPSKMode(_ mode: Int32) {
        pskHub.setPSKMode(mode)
    }

    //  0.64e - set click buffer offset
    @objc(setTimeOffset:)
    func setTimeOffset(_ history: Float) {
        var history = history
        //  set up where in click buffer to use
        if history < 0.1 { history = 0.1 }
        if history > 20.0 { history = 20.0 }

        clickBufferLock.lock()
        clickBufferConsumer = clickBufferProducer + (512 - Int32(21.5 * history))
        clickBufferConsumer = clickBufferConsumer & 0x1ff   //  wrap around a 256K sample (512*512) float buffer
        clickBufferLock.unlock()
    }

    @objc(selectFrequency:secondsAgo:fromWaterfall:)
    func selectFrequency(_ freq: Float, secondsAgo history: Float, fromWaterfall: Bool) {
        setTimeOffset(history)
        squelchHold = 0
        transferToTransmitFreq = fromWaterfall
        if fromWaterfall {
            //  clear indicators
            freqIndicator?.clear()
            phaseIndicator?.clear()
            IMDField?.stringValue = ""
        }
        updateReceiveFrequencyDisplay(freq)
        //  set up transmit VCO here if clicked from waterfall
        if fromWaterfall { setTransmitFrequencyToTone(freq) }
        setTransmitLightState(indicatorState)
        pskHub.selectFrequency(freq, fromWaterfall: fromWaterfall)
        client.application()?.clearVoiceChannel(uniqueID + 1)   //  v0.96d voice synthesizer
    }

    //  display PSK Monitor
    @objc(showScope)
    func showScope() {
        monitor.showWindow()
    }

    @objc(hideScopeOnDeactivation:)
    func hideScopeOnDeactivation(_ hide: Bool) {
        monitor.hideScopeOnDeactivation(DarwinBoolean(hide))
    }

    @objc(setVFOOffset:sideband:)
    func setVFOOffset(_ offset: Float, sideband polarity: Bool) {
        vfoOffset = offset
        sideband = polarity
        freqIndicator?.setSideband(sideband ? 1 : 0)

        pskBrowserHub?.setVFOOffset(offset, sideband: DarwinBoolean(polarity))
    }

    @objc(setTransmitFrequencyToReceiveFrequency)
    func setTransmitFrequencyToReceiveFrequency() {
        let tone = pskHub.receiveFrequency()
        if tone > 10.5 { setTransmitFrequencyToTone(tone) }
    }

    @objc(setTransmitFrequencyToTone:)
    func setTransmitFrequencyToTone(_ tone: Float) {
        //  set transmit freq (actual tone frequency, no offset)
        updateTransmitFrequencyDisplay(tone)
        transmitFrequency = tone
        setTransmitLightState(indicatorState)
    }

    @objc(setFrequencyDefined)
    func setFrequencyDefined() {
        (client as? PSK)?.setFrequencyDefined()
    }

    //  local
    @discardableResult
    private func setRxOffset(_ freq: Float) -> Float {
        let tone: Float = sideband ? freq + vfoOffset : vfoOffset - freq
        if freq != displayedRxFrequency {
            displayedRxFrequency = freq
            (client as? PSK)?.receiveFrequency(tone, setBy: uniqueID)
        }
        return tone
    }

    //  local
    @discardableResult
    private func setRxTone(_ tone: Float) -> Float {
        let freq: Float = sideband ? tone - vfoOffset : vfoOffset - tone
        if freq != displayedRxFrequency {
            displayedRxFrequency = freq
            (client as? PSK)?.receiveFrequency(tone, setBy: uniqueID)
        }
        return freq
    }

    //  local
    @discardableResult
    private func setTxOffset(_ freq: Float) -> Float {
        let tone: Float = sideband ? freq + vfoOffset : vfoOffset - freq
        if freq != displayedTxFrequency {
            displayedTxFrequency = freq
            setTransmitFrequencyToTone(tone)
        }
        return tone
    }

    //  local
    @discardableResult
    private func setTxTone(_ tone: Float) -> Float {
        let freq: Float = sideband ? tone - vfoOffset : vfoOffset - tone
        if freq != displayedTxFrequency {
            displayedTxFrequency = freq
            setTransmitFrequencyToTone(tone)
        }
        return freq
    }

    @objc(setAndDisplayRxOffset:)
    func setAndDisplayRxOffset(_ freq: Float) {
        setRxOffset(freq)
        rxFrequencyField?.stringValue = String(format: "%.1f", freq)
    }

    @objc(setAndDisplayRxTone:)
    func setAndDisplayRxTone(_ tone: Float) {
        let freq = setRxTone(tone)
        rxFrequencyField?.stringValue = String(format: "%.1f", freq)
    }

    @objc(setAndDisplayTxOffset:)
    func setAndDisplayTxOffset(_ freq: Float) {
        setTxOffset(freq)
        txFrequencyField?.stringValue = String(format: "%.1f", freq)
    }

    @objc(setAndDisplayTxTone:)
    func setAndDisplayTxTone(_ tone: Float) {
        let freq = setTxTone(tone)
        txFrequencyField?.stringValue = String(format: "%.1f", freq)
    }

    @objc(rxTone)
    func rxTone() -> Float {
        if displayedRxFrequency < 0 { return -1.0 }
        return sideband ? displayedRxFrequency + vfoOffset : vfoOffset - displayedRxFrequency
    }

    @objc(rxOffset)
    func rxOffset() -> Float {
        return displayedRxFrequency
    }

    @objc(txOffset)
    func txOffset() -> Float {
        return displayedTxFrequency
    }

    @objc(txTone)
    func txTone() -> Float {
        if displayedTxFrequency < 0 { return -1.0 }
        return sideband ? displayedTxFrequency + vfoOffset : vfoOffset - displayedTxFrequency
    }

    @objc func rxFieldChanged() {
        setRxOffset(rxFrequencyField.floatValue)
    }

    @objc func txFieldChanged() {
        setTxOffset(txFrequencyField.floatValue)
    }

    //  delegate of CMPSKMatchedFilter
    @objc(updatePhase:)
    func updatePhase(_ phase: Float) {
        phaseIndicator?.newPhase(phase)
    }

    //  delegate of CMPSKMatchedFilter
    @objc(receivedCharacter:spectrum:)
    func receivedCharacter(_ c: Int32, spectrum: UnsafeMutablePointer<Float>) {
        print("PSKReceiver: receivedCharacter:spectrum deprecated")
        exit(0)
    }

    //  v0.57 -- new -receivedCharacter that has quality of character
    //  delegate of CMPSKMatchedFilter
    @objc(receivedCharacter:spectrum:quality:)
    func receivedCharacter(_ inC: Int32, spectrum: UnsafeMutablePointer<Float>, quality: Float) {
        var c = inC & 0xff
        var isShiftJISCharacter: Bool

        //  check squelch -- used to squelch print but not decoding
        let squelch = 1 - control.squelchValue()
        if squelch < 0.05 {
            squelchHold = 0
        } else {
            //  v0.57 -- use character quality
            let q = quality * 1.1
            if q < squelch { squelchHold = 2 } else if squelchHold > 0 { squelchHold -= 1 }
        }
        //  v0.70 - raw output
        if useRawOutput {
            if squelchHold > 0 { return }
            var buffer = Array(String(format: "<%02x>", c).utf8CString)
            receiveView?.append(&buffer)
            return
        }

        //  double byte output
        if useShiftJIS {
            if doubleByteIndex == 0 {
                //  validate that it is the first byte of Shift-JIS
                isShiftJISCharacter = true
                if !(c >= 0x81 && c <= 0x84) {
                    if !(c >= 0x87 && c <= 0x9f) {
                        if !(c >= 0xe0 && c <= 0xea) {
                            if !(c >= 0xed && c <= 0xee) { isShiftJISCharacter = false }
                        }
                    }
                }
                if isShiftJISCharacter == false {
                    //  Not a first byte for Shift-JIS, decode as ASCII...
                    if squelchHold > 0 { return }

                    var decoded = printable(c, extended: extendedASCII ? 1 : 0)
                    if decoded != 0 {
                        if appleScript != nil { appleScript.insertBuffer(decoded) }
                        if decoded == 0x30 /* '0' */ && slashZero { decoded = Phi }
                        var buffer: [CChar] = [CChar(truncatingIfNeeded: decoded), 0]
                        receiveView?.append(&buffer)
                    }
                    return
                }
                lastASCII = -1
                doubleByteValue[0] = c
                doubleByteIndex += 1
                return
            } else {
                lastASCII = -1
                c = doubleByteValue[0] * 256 + c
                doubleByteIndex = 0
            }
        }
        if c == 0x0a /* '\n' */ { c = 0x0d }    //  v0.44 some programs send line feeds for carriage returns

        //  Squelch a character away while the squelch is being held
        if squelchHold > 0 { return }

        if useShiftJIS {
            let uch = unichar(truncatingIfNeeded: Int(jisToUnicode[Int(c) * 2]) * 256 + Int(jisToUnicode[Int(c) * 2 + 1]))
            if uch >= 0xffff {
                //  error in table lookup!
                var buffer: [CChar] = [CChar(truncatingIfNeeded: 0x2e /* '.' */), 0]
                receiveView?.append(&buffer)
                return
            }
            receiveView?.appendUnicode(uch)
            return
        }
        //  single byte case
        var decoded = printable(c, extended: extendedASCII ? 1 : 0)
        if receiveView != nil && decoded != 0 {
            if appleScript != nil { appleScript.insertBuffer(decoded) }
            if decoded == 0x30 /* '0' */ && slashZero { decoded = Phi }
            var buffer: [CChar] = [CChar(truncatingIfNeeded: decoded), 0]
            receiveView.append(&buffer)
            client.application()?.addToVoice(decoded, channel: uniqueID + 1)     //  v0.96d voice synthesizer
        }
    }

    @objc(browserSquelchChanged:)
    func browserSquelchChanged(_ sender: Any?) {
        if let slider = sender as? NSSlider { pskBrowserHub?.squelchChanged(slider) }
    }

    @objc(browserSquelchRescan:)
    func browserSquelchRescan(_ sender: Any?) {
        pskBrowserHub?.rescan()
    }

    @objc(browserSetAlarm:)
    func browserSetAlarm(_ sender: Any?) {
        pskBrowserHub?.openAlarm()
    }

    //  this button is hidden in released version
    @objc(testCheck:)
    func testCheck(_ sender: Any?) {
        pskBrowserHub?.testCheck()
    }

    @objc(useControlButton:)
    func useControlButton(_ state: Bool) {
        pskBrowserHub?.useControlButton(DarwinBoolean(state))
    }

    @objc(updateVisibleState:)
    func updateVisibleState(_ visible: Bool) {
        pskBrowserHub?.updateVisibleState(DarwinBoolean(visible))
    }

    //  delegate to CMPSKDemodulator
    @objc(newSpectrum:size:)
    func newSpectrum(_ buf: UnsafeMutablePointer<DSPSplitComplex>, size length: Int32) {
        //  v0.57 full spectrum arrives (used to be demux here)
        freqIndicator?.newSpectrum(buf, size: length)
    }

    //  delegate to CMPSKDemodulator
    @objc(afcEnabled)
    func afcEnabled() -> Bool {
        return control.afcEnabled().boolValue
    }

    //  delegate to CMPSKDemodulator
    @objc(squelchValue)
    func squelchValue() -> Float {
        return control.squelchValue()
    }

    //  delegate to CMPSKDemodulator
    @objc(updateDisplayFrequency:)
    func updateDisplayFrequency(_ tone: Float) {
        updateReceiveFrequencyDisplay(tone)
    }

    //  delegate to CMPSKDemodulator
    //  v0.57 -- change snr behavior
    @objc(updateIMD:snr:)
    func updateIMD(_ imd: Float, snr: Float) {
        if snr < 0 {
            IMDField?.stringValue = ""      //  clear IMD field
            return
        }
        if imd < -0.1 {
            IMDField?.stringValue = "NL"    //  "noise limited"
            return
        }
        let n = cInt(10 * log10(imd) - 0.5)     //  quantize to 1 dB steps
        if abs(snr) > abs(imd) {
            IMDField?.stringValue = String(format: "%d", n)
        } else {
            IMDField?.stringValue = String(format: "%d*", n)
        }
    }

    //  delegate to CMPSKDemodulator
    @objc(setTransmitFrequency:)
    func setTransmitFrequency(_ tone: Float) {
        if transferToTransmitFreq {
            setTransmitFrequencyToTone(tone)
        }
    }

    @objc(updateFromPlist:)
    func updateFromPlist(_ pref: Preferences!) -> Bool {
        var str = pref.stringValue(forKey: kPSKBrowserWindowPosition)
        if let str = str, uniqueID == 0 { browserTable.window?.setFrame(from: str) }
        str = pref.stringValue(forKey: kPSKBrowserSquelch)
        if let str = str, uniqueID == 0 { browserSquelch.floatValue = (str as NSString).floatValue }
        if uniqueID == 0 && pskBrowserHub != nil { _ = pskBrowserHub.updateFromPlist(pref) }

        return true
    }

    @objc(retrieveForPlist:)
    func retrieveForPlist(_ pref: Preferences!) {
        if uniqueID == 0 {
            pref.setString(browserTable.window?.frameDescriptor, forKey: kPSKBrowserWindowPosition)
            pref.setString(String(format: "%.3f", browserSquelch.floatValue), forKey: kPSKBrowserSquelch)
            if pskBrowserHub != nil { pskBrowserHub.retrieveForPlist(pref) }
        }
    }
}
