//
//  PSK.swift
//  cocoaModem
//
//  Created by Kok Chen on Tue Jul 27 2004.
//  Swift port of PSK.m / PSK.h.
//
//  PSK : ContestInterface : MacroInterface : Modem : CMPipe.  This is the PSK
//  mode tab (two receivers, transmit control, aural monitor, waterfall).  It is
//  the base class of LitePSK.
//
//  Port notes:
//   * Every original PSK ivar is an internal stored property with its EXACT
//     original name so LitePSK (and KVC) resolve them across the module.  The
//     C-pointer members (jisToUnicode/unicodeToJis byte tables and the
//     TextAttribute* scratch pointers) are plain `internal` (not @objc); the
//     byte tables are UnsafeMutablePointer buffers freed in deinit.
//   * The C struct `AuralAction` is modelled as a Swift reference type (its
//     address was taken with `&auralAction[i]` and its fields mutated in place).
//   * The ivar `selectedTransceiver` collides with the inherited/overridden
//     `-selectedTransceiver` method, so the STORED PROPERTY is renamed
//     `selectedTransceiverIndex` (the method keeps the `selectedTransceiver`
//     selector).  Likewise the `inputAttenuator` outlet is renamed
//     `inputAttenuatorOutlet` (nib key preserved via @objc) because it collides
//     with the `-inputAttenuator:` accessor.
//   * TextAttribute is a C struct (see TextAttribute.h); AYTextView's
//     -newAttribute/-setTextColor:attribute:/-setTextFont:... use
//     UnsafeMutablePointer<TextAttribute>, so PSK's attribute members use that
//     type too.
//

import Cocoa

//  Transmit indicator states (match PSKReceiver.swift)
private let TxOff: Int32 = 0
private let TxReady: Int32 = 1
private let TxWait: Int32 = 2
private let TxActive: Int32 = 3

//  PSK modes (match CMPSKModes.h)
private let kBPSK31: Int32 = 0
private let kBPSK63: Int32 = 1
private let kQPSK31: Int32 = 2
private let kQPSK63: Int32 = 3

//  PSK Aural Monitor keys
private let kAuralMonitor0     = "PSK Aural Monitor for xcvr 0"
private let kAuralMonitor1     = "PSK Aural Monitor for xcvr 1"
private let kAuralTransmitter  = "PSK Aural Monitor for transmit"
private let kAuralWideband     = "PSK Aural Monitor for wideband"
private let kMasterVolume      = "PSK Aural Master Volume"
private let kMasterMute        = "PSK Aural Master Mute"

//  Individual aural channels (kAuralMonitor0, transmitter, etc)
private let kMonitorEnable     = "Enable"
private let kMonitorAttenuator = "Attenuator"
private let kMonitorFixSelect  = "Fix Selection"
private let kMonitorFrequency  = "Fix Frequency"

//  --- Plist keys (from Plist.h; kept local so PSK.swift is self-contained) ---
private let kPSK1Font           = "PSK 1 Font"
private let kPSK1FontSize        = "PSK 1 Font Size"
private let kPSK2Font           = "PSK 2 Font"
private let kPSK2FontSize        = "PSK 2 Font Size"
private let kPSKTxFont          = "PSK Tx Font"
private let kPSKTxFontSize       = "PSK Tx Font Size"
private let kPSKTextColor       = "PSK Text Color"
private let kPSKSentColor       = "PSK Sent Color"
private let kPSKBackgroundColor  = "PSK Background Color"
private let kPSKPlotColor       = "PSK Plot Color"
private let kPSKSquelchA        = "PSK Squelch A"
private let kPSKSquelchB        = "PSK Squelch B"
private let kPSKWaterfallNR      = "PSK Waterfall Noise Reduction"
private let kSlashZeros         = "Null for Zero"

//  ---------------------------------------------------------------------------
//  AuralAction -- originally a C struct in PSK.h.  Modelled as a reference type
//  because the code takes &auralAction[i] and mutates its fields in place.
//  ---------------------------------------------------------------------------
final class AuralAction {
    var enableButton: NSButton!
    var attenuationField: NSTextField!
    var floatMatrix: NSMatrix!
    var fixedFrequency: NSTextField!
}

@objc(PSK)
class PSK: ContestInterface, NSTextViewDelegate {

    //  --- IBOutlets (id) ---
    @objc var waterfall: Waterfall!
    @objc var transmitButton: AnyObject!
    @objc var squelch: AnyObject!

    @objc var rx1Group: AnyObject!
    @objc var rx1View: AnyObject!
    @objc var rx1ControlView: AnyObject!
    @objc var receive1View: ExchangeView!

    @objc var rx2Group: AnyObject!
    @objc var rx2View: AnyObject!
    @objc var rx2ControlView: AnyObject!
    @objc var receive2View: ExchangeView!

    @objc var txControlView: AnyObject!
    @objc var contestTxControlView: AnyObject!

    //  the outlet is named "inputAttenuator"; the accessor -inputAttenuator: has
    //  the same base name, so the stored property is renamed and given the exact
    //  nib key via @objc.
    @objc(inputAttenuator) var inputAttenuatorOutlet: NSSlider!
    @objc var vuMeter: AnyObject!

    @objc var shiftJISTextField: AnyObject!

    //  v0.78 PSKAuralMonitor
    @objc var auralPanel: AnyObject!
    @objc var masterLevel: AnyObject!
    @objc var masterMute: AnyObject!

    @objc var auralRxEnable0: AnyObject!
    @objc var auralAttenuatorField0: AnyObject!
    @objc var auralFixedFrequency0: AnyObject!
    @objc var auralFloatMatrix0: AnyObject!

    @objc var auralRxEnable1: AnyObject!
    @objc var auralAttenuatorField1: AnyObject!
    @objc var auralFixedFrequency1: AnyObject!
    @objc var auralFloatMatrix1: AnyObject!

    @objc var auralTxEnable: AnyObject!
    @objc var auralTxAttenuatorField: AnyObject!
    @objc var auralTxFixedFrequency: AnyObject!
    @objc var auralTxFloatMatrix: AnyObject!

    @objc var auralWideEnable: AnyObject!
    @objc var auralWideAttenuatorField: AnyObject!

    @objc var pskAuralMonitor: PSKAuralMonitor!

    //  0,1 = receiver, 2 = transmitter, 3 = wideband
    var auralMonitorPlist = [SubDictionary?](repeating: nil, count: 4)
    let auralAction: [AuralAction] = [AuralAction(), AuralAction(), AuralAction(), AuralAction()]

    @objc var rx1: PSKReceiver!
    @objc var rx2: PSKReceiver!
    @objc var rx1Control: PSKControl!
    @objc var rx2Control: PSKControl!
    @objc var txControl: PSKTransmitControl!
    @objc var contestTxControl: PSKContestTxControl!
    var transmitModule = [Module?](repeating: nil, count: 2)
    //  renamed: `selectedTransceiver` ivar collides with -selectedTransceiver method
    @objc var selectedTransceiverIndex: Int32 = 0

    @objc var receiveFrame = NSRect.zero      //  frame of receive-only receiver
    @objc var transceiveFrame = NSRect.zero   //  frame of receive-transmit receiver

    //  active receive view (one of two exchange views)
    @objc var activeReceiveView: ExchangeView!
    var activeReceiveTextAttribute: UnsafeMutablePointer<TextAttribute>!

    @objc var thread: Thread!

    //  v0.70 Shift-JIS (unsigned char[65536*2])
    let jisToUnicode: UnsafeMutablePointer<UInt8> = {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536 * 2)
        p.initialize(repeating: 0, count: 65536 * 2); return p
    }()
    let unicodeToJis: UnsafeMutablePointer<UInt8> = {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536 * 2)
        p.initialize(repeating: 0, count: 65536 * 2); return p
    }()
    //  v0.95 text insertion
    @objc var insertionRange = NSRange(location: 0, length: 0)
    @objc var unmarkedTextLength: Int32 = 0

    //  transmit
    @objc var transmitViewLock: NSLock!
    @objc var transmitBufferCheck: Timer!
    @objc var indexOfUntransmittedText: Int32 = 0
    @objc var hardLimitForBackspace: Int32 = 0    //  v0.66
    var transmitAttribute: UnsafeMutablePointer<TextAttribute>!
    @objc var frequencyDefined: Bool = false
    //  receive
    var receive1TextAttribute: UnsafeMutablePointer<TextAttribute>!
    var receive2TextAttribute: UnsafeMutablePointer<TextAttribute>!

    deinit {
        jisToUnicode.deinitialize(count: 65536 * 2); jisToUnicode.deallocate()
        unicodeToJis.deinitialize(count: 65536 * 2); unicodeToJis.deallocate()
    }

    //  PSK : ContestInterface : MacroInterface : Modem : CMPipe
    //  Forward the nib-loading designated init so LitePSK can pass its own nib.
    override init?(into tabview: NSTabView!, nib: String!, manager mgr: ModemManager!) {
        super.init(into: tabview, nib: nib, manager: mgr)
    }

    @objc(initIntoTabView:manager:)
    init?(into tabview: NSTabView!, manager mgr: ModemManager!) {
        mgr.showSplash("Creating PSK Modem")

        super.init(into: tabview, nib: "PSK", manager: mgr)

        manager = mgr
        transceivers = 2
        //  v0.78
        pskAuralMonitor = PSKAuralMonitor()
        //  v0.95
        unmarkedTextLength = 0
        insertionRange = NSRange(location: 0, length: 0)
    }

    @objc(setJisToUnicodeTable:)
    func setJisToUnicodeTable(_ uarray: UnsafeMutablePointer<UInt8>!) {
    }

    //  v0.70  JIS/Unicode tables are created by the Application.m
    @objc(setUnicodeToJisTable:)
    func setUnicodeToJisTable(_ uarray: UnsafeMutablePointer<UInt8>!) {
    }

    //  v0.71
    @objc(setAllowShiftJIS:)
    func setAllowShiftJIS(_ state: Bool) {
        manager?.setAllowShiftJISForPSK(state)
    }

    //  v0.87
    @objc override func switchModemIn() {
        if config != nil { configObj()?.setKeyerMode() }
    }

    @objc override func transmissionMode() -> Int32 {
        return PSKMODE
    }

    @objc func currentPSKMode() -> Int32 {
        let rx = (selectedTransceiverIndex == 0) ? rx1Control : rx2Control
        return rx?.pskMode() ?? 0
    }

    @objc func auralMonitor() -> PSKAuralMonitor! {
        return pskAuralMonitor
    }

    override func awakeFromNib() {
        ident = NSLocalizedString("PSK", comment: "")

        //  v0.78 moved here; JIS/Unicode tables are created by the Application
        if let jt = application()?.jisToUnicodeTable() { memcpy(jisToUnicode, jt, 65536 * 2) }
        if let ut = application()?.unicodeToJisTable() { memcpy(unicodeToJis, ut, 65536 * 2) }

        modemTabItem?.label = ident ?? ""

        configObj()?.awakeFromModem(self)
        ptt = configObj()?.pttObject()

        awakeFromContest()
        initCallsign()
        initColors()
        initMacros()

        //  actions
        setInterface(transmitButton as? NSControl, to: #selector(transmitButtonChanged))
        setInterface(squelch as? NSControl, to: #selector(squelchChanged))
        setInterface(inputAttenuatorOutlet, to: #selector(inputAttenuatorChanged))
        //  aural monitor actions
        setInterface(masterLevel as? NSControl, to: #selector(masterLevelChanged))
        setInterface(masterMute as? NSControl, to: #selector(masterMuteChanged))

        //  rx0
        var a = auralAction[0]
        a.enableButton = auralRxEnable0 as? NSButton
        a.attenuationField = auralAttenuatorField0 as? NSTextField
        a.floatMatrix = auralFloatMatrix0 as? NSMatrix
        a.fixedFrequency = auralFixedFrequency0 as? NSTextField
        //  rx1
        a = auralAction[1]
        a.enableButton = auralRxEnable1 as? NSButton
        a.attenuationField = auralAttenuatorField1 as? NSTextField
        a.floatMatrix = auralFloatMatrix1 as? NSMatrix
        a.fixedFrequency = auralFixedFrequency1 as? NSTextField
        //  tx
        a = auralAction[2]
        a.enableButton = auralTxEnable as? NSButton
        a.attenuationField = auralTxAttenuatorField as? NSTextField
        a.floatMatrix = auralTxFloatMatrix as? NSMatrix
        a.fixedFrequency = auralTxFixedFrequency as? NSTextField
        //  wideband
        a = auralAction[3]
        a.enableButton = auralWideEnable as? NSButton
        a.attenuationField = auralWideAttenuatorField as? NSTextField
        a.floatMatrix = nil
        a.fixedFrequency = nil

        //  rx, tx and wide actions
        for i in 0..<4 {
            let aa = auralAction[i]
            setInterface(aa.enableButton, to: #selector(enableChanged(_:)))
            setInterface(aa.attenuationField, to: #selector(attenuatorChanged(_:)))
        }
        //  rx and tx actions
        for i in 0..<3 {
            let aa = auralAction[i]
            setInterface(aa.floatMatrix, to: #selector(floatMatrixChanged(_:)))
            setInterface(aa.fixedFrequency, to: #selector(fixedFrequencyChanged(_:)))
        }

        //  use QSO transmitview
        (contestTab as? NSTabView)?.selectTabViewItem(at: 0)

        receiveFrame = (rx2Group as? NSView)?.frame ?? .zero
        transceiveFrame = (rx1Group as? NSView)?.frame ?? .zero

        waterfall?.awakeFromModem()
        waterfall?.enableIndicator(self)
        waterfall?.setFFTDelegate(self)
        //  prefs
        charactersSinceTimerStarted = 0
        timeout = nil
        transmitBufferCheck = nil
        thread = Thread.current
        frequencyDefined = false

        //  transmit view
        indexOfUntransmittedText = 0
        hardLimitForBackspace = 0                   // v0.66
        transmitState = false
        sentColor = false
        transmitCount = 0
        transmitCountLock = NSLock()
        transmitViewLock = NSLock()
        transmitTextAttribute = transmitView?.newAttribute()
        selectedTransceiverIndex = 0
        transmitView?.delegate = self

        //  receive view
        if receiveView != nil {         // not actually used
            receiveTextAttribute = receiveView?.newAttribute()
        }

        if receive1View != nil {
            receive1TextAttribute = receive1View?.newAttribute()
            receive1View?.delegate = self       //  delegate for callsign clicks
        }
        if receive2View != nil {
            receive2TextAttribute = receive2View?.newAttribute()
            receive2View?.delegate = self       //  delegate for callsign clicks
        }

        //  default receive view
        activeReceiveView = receive1View
        activeReceiveTextAttribute = receive1TextAttribute

        //  create the two receivers
        if rx1View != nil {
            rx1 = PSKReceiver(intoView: rx1View as? NSView, client: self, index: 0)
            rx1Control = PSKControl(intoView: rx1ControlView as? NSView, client: self, index: 0)
            rx1Control?.setPSKReceiver(rx1)
            rx1?.setExchangeView(receive1View)
            rx1?.setPSKControl(rx1Control)
            rx1?.setTransmitLightState(TxReady)
            rx1?.registerModule(transceiver1?.receiver())
            rx1?.setJisToUnicodeTable(jisToUnicode)      //  v0.95 moved here, copy to xcvr1
            rx1?.setUnicodeToJisTable(unicodeToJis)      //  v0.95 moved here, copy to xcvr1
            transmitModule[0] = transceiver1?.transmitter()
        }
        if rx2View != nil {
            rx2 = PSKReceiver(intoView: rx2View as? NSView, client: self, index: 1)
            rx2Control = PSKControl(intoView: rx2ControlView as? NSView, client: self, index: 1)
            rx2Control?.setPSKReceiver(rx2)
            rx2?.setExchangeView(receive2View)
            rx2?.setPSKControl(rx2Control)
            rx2?.setTransmitLightState(TxOff)
            rx2?.registerModule(transceiver2?.receiver())
            transmitModule[1] = transceiver2?.transmitter()
        }
        txControl = PSKTransmitControl(intoView: txControlView as? NSView, client: self)
        contestTxControl = PSKContestTxControl(intoView: contestTxControlView as? NSView, client: self)

        vuMeter?.setup?()
    }

    @objc override func initMacros() {
        currentSheet = 0
        check = 0
        let app = manager?.appObject()
        for i in 0..<3 {
            macroSheet[i] = PSKMacros(sheet: ())
            macroSheet[i]?.setUserInfo(app?.userInfoObject(), qso: (manager as? StdManager)?.qsoObject(), modem: self, canImport: true)
        }
    }

    //  v1.02b
    @objc(directSetFrequency:)
    override func directSetFrequency(_ freq: Float) {
        rx1?.setAndDisplayRxTone(freq)
        rx1?.setAndDisplayTxTone(freq)
    }

    //  v1.02b
    @objc override func selectedFrequency() -> Float {
        return rx1?.rxTone() ?? 0
    }

    @objc(configObj)
    func configObj() -> PSKConfig! {
        return config as? PSKConfig
    }

    override func updateSourceFromConfigInfo() {
        manager?.showSplash("Updating PSK sound source")
        //  send data back here from config where it all starts
        configObj()?.setClient(self)
        //  set up squelch
        (squelch as? NSControl)?.floatValue = 0.6
        //  turn on if it is on in Plist
        configObj()?.checkActive()
    }

    @objc(dataClient)
    override func dataClient() -> CMTappedPipe! {
        return unsafeBitCast(self, to: CMTappedPipe.self)
    }

    //  v0.78 PSKAuralMonitor
    @objc(openAuralPanel:)
    func openAuralPanel(_ sender: Any!) {
        (auralPanel as? NSWindow)?.makeKeyAndOrderFront(self)
    }

    @objc func masterLevelChanged() {
        if pskAuralMonitor == nil { return }
        pskAuralMonitor?.setMasterGain((masterLevel as? NSControl)?.floatValue ?? 0)
    }

    @objc func masterMuteChanged() {
        if pskAuralMonitor != nil {
            pskAuralMonitor?.setMute(DarwinBoolean((masterMute as? NSButton)?.state == .on).boolValue)
        }
    }

    @objc(enableChanged:)
    func enableChanged(_ sender: Any!) {
        if pskAuralMonitor == nil { return }
        for i in 0..<4 {
            if let btn = auralAction[i].enableButton, btn === (sender as AnyObject?) {
                pskAuralMonitor?.setEnable(DarwinBoolean((sender as? NSButton)?.state == .on).boolValue, channel: Int32(i))
                return
            }
        }
    }

    @objc(attenuatorChanged:)
    func attenuatorChanged(_ sender: Any!) {
        if pskAuralMonitor == nil { return }
        for i in 0..<4 {
            if let f = auralAction[i].attenuationField, f === (sender as AnyObject?) {
                pskAuralMonitor?.setAttenuation((sender as? NSControl)?.floatValue ?? 0, channel: Int32(i))
                return
            }
        }
    }

    @objc(floatMatrixChanged:)
    func floatMatrixChanged(_ sender: Any!) {
        if pskAuralMonitor == nil { return }
        for i in 0..<3 {
            if let m = auralAction[i].floatMatrix, m === (sender as AnyObject?) {
                let n = (sender as? NSMatrix)?.selectedRow ?? 0
                pskAuralMonitor?.setFloating(DarwinBoolean(n == 0).boolValue, forChannel: Int32(i))
                return
            }
        }
    }

    @objc(fixedFrequencyChanged:)
    func fixedFrequencyChanged(_ sender: Any!) {
        if pskAuralMonitor == nil { return }
        for i in 0..<4 {
            if let f = auralAction[i].fixedFrequency, f === (sender as AnyObject?) {
                pskAuralMonitor?.setFixedFrequency((sender as? NSControl)?.floatValue ?? 0, forChannel: Int32(i))
                return
            }
        }
    }

    //  Callback from a PSKReceiver when the mode (PSK31/63/125) changes or PSK center
    //  frequency changes.  NOTE: "mode" is the decimation factor in the PSKReceiver.
    @objc(setReceiveFrequency:mode:forReceiver:)
    func setReceiveFrequency(_ freq: Float, mode: Int32, forReceiver receiver: Int32) {
        let bw: Float
        switch mode {
        case 64:
            bw = 30
        case 128:
            bw = 60
        default:    //  32
            bw = 15
        }
        if receiver == 0 || receiver == 1 {
            pskAuralMonitor?.setCenterFrequency(freq, bandwidth: bw, channel: receiver)
            (NSApp.delegate as? AppDelegate)?.application()?.setDirectFrequencyFieldTo(freq)
        }
    }

    //  Audio data arrives here and is sent to the two receivers (and waterfall and VUMeter)
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        if !(manager?.modemIsVisible(self) ?? false) { return }

        rx1?.importData(pipe)
        rx2?.importData(pipe)

        if pskAuralMonitor != nil { pskAuralMonitor?.importWidebandData(pipe) }

        waterfall?.importData(pipe)
        (vuMeter as? CMPipe)?.importData(pipe)
    }

    @objc override func shouldEndTransmission() -> Bool {
        //  first decrement transmit count
        decrementTransmitCount()
        return transmitCount <= 0
    }

    //  v0.70 Shift-JIS double byte support
    //  echo callback from PSK generator
    @objc(transmittedCharacter:)
    override func transmittedCharacter(_ c: Int32) {
        setSentColor(true, view: activeReceiveView, textAttribute: activeReceiveTextAttribute)

        if c <= 26 {
            //  control character in stream
            if (c + Int32(UInt8(ascii: "a")) - 1) == Int32(UInt8(ascii: "z")) {
                //  end of macro transmitCount balance
                transmitCountLock?.lock()
                if transmitCount > 0 { transmitCount -= 1 }
                transmitCountLock?.unlock()
                return
            }
            //  for carriage return, newline, etc -- fall through
        }

        var useShiftJIS = false
        let vfo = txControl?.selectedTransceiver() ?? 0
        if vfo == 0 { useShiftJIS = rx1?.useShiftJIS_() ?? false }

        if c >= 0x100 && useShiftJIS {
            //  validate that it is Shift-JIS
            var isShiftJISCharacter = true
            if !(c >= 0x8100 && c <= 0x84ff) {
                if !(c >= 0x8700 && c <= 0x9fff) {
                    if !(c >= 0xe000 && c <= 0xeaff) {
                        if !(c >= 0xed00 && c <= 0xeeff) { isShiftJISCharacter = false }
                    }
                }
            }
            if isShiftJISCharacter {
                //  Got double byte character in Shift-JIS range, convert it to Unicode
                let uch = unichar(jisToUnicode[Int(c) * 2]) &* 256 &+ unichar(jisToUnicode[Int(c) * 2 + 1])
                print(String(format: "transmitted 0x%x => uch %d", c, uch))
                //  send character
                activeReceiveView?.appendUnicode(uch)
                transmitModule[Int(selectedTransceiverIndex)]?.insertBuffer(Int32(uch))
                transmitView?.select()
            }
            return
        }

        //  not in Shift-JIS mode
        var ch = c
        if ch > 256 { ch = Int32(UInt8(ascii: ".")) }       //  sanity check
        if ch == Int32(UInt8(ascii: "0")) && slashZero { ch = Phi }

        //  send character
        var buffer = [CChar](repeating: 0, count: 2)
        buffer[0] = CChar(truncatingIfNeeded: ch)
        buffer[1] = 0
        buffer.withUnsafeMutableBufferPointer { activeReceiveView?.append($0.baseAddress!) }
        transmitModule[Int(selectedTransceiverIndex)]?.insertBuffer(ch)
        transmitView?.select()
    }

    //  selected transceiver from normal or contest interface
    @objc func selectedReceiver() -> Int32 {
        let control = inContestMode ? contestTxControl : txControl
        selectedTransceiverIndex = control?.selectedTransceiver() ?? 0
        return selectedTransceiverIndex
    }

    //  check if selected receiver is on
    @objc(checkTx)
    func checkTx() -> Bool {
        let xcvr = selectedReceiver()
        return (xcvr == 0) ? (rx1?.isEnabled() ?? false) : (rx2?.isEnabled() ?? false)
    }

    @objc func transceiverChanged() {
        let xcvr = selectedReceiver()
        let receiveBox: AnyObject?
        let transceiveBox: AnyObject?
        if xcvr == 0 {
            //  receiverA = transceive
            rx2?.setTransmitLightState(TxOff)
            rx1?.setTransmitLightState(TxReady)
            transceiveBox = rx1Group
            receiveBox = rx2Group
        } else {
            //  receiverB = transceive
            rx1?.setTransmitLightState(TxOff)
            rx2?.setTransmitLightState(TxReady)
            transceiveBox = rx2Group
            receiveBox = rx1Group
        }
        (transceiveBox as? NSView)?.frame = transceiveFrame
        (receiveBox as? NSView)?.frame = receiveFrame
        (rx1Group as? NSView)?.needsDisplay = true
        (rx2Group as? NSView)?.needsDisplay = true
    }

    @objc func transmitFrequency() -> Float {
        let xcvr = selectedReceiver()
        return (xcvr == 0) ? (rx1?.currentTransmitFrequency() ?? 0) : (rx2?.currentTransmitFrequency() ?? 0)
    }

    //  waterfall clicked
    //  Note: for USB left edge is always 400 Hz no matter what the VFO offset is
    @objc(clicked:secondsAgo:option:fromWaterfall:waterfallID:)
    override func clicked(_ freq: Float, secondsAgo secs: Float, option: Bool, fromWaterfall acquire: Bool, waterfallID index: Int32) {
        frequencyDefined = true

        //  check if already in transmit mode, if so, don't change frequency
        if transmitState == false {
            if !option {
                rx1?.enableReceiver(true)
                rx1?.selectFrequency(freq, secondsAgo: secs, fromWaterfall: acquire)
                receive1View?.scrollToEnd()
            } else {
                rx2?.enableReceiver(true)
                rx2?.selectFrequency(freq, secondsAgo: secs, fromWaterfall: acquire)
                receive2View?.scrollToEnd()
            }
        }
    }

    //  turn off one of the receivers
    @objc(turnOffReceiver:option:)
    override func turnOffReceiver(_ ident: Int32, option: Bool) {
        if pskAuralMonitor != nil { pskAuralMonitor?.disactivateChannel(option ? 1 : 0) }   //  v0.78
        if !option { rx1?.enableReceiver(false) } else { rx2?.enableReceiver(false) }
    }

    //  receive frequency set not by clicking, but by direct entry
    @objc(receiveFrequency:setBy:)
    func receiveFrequency(_ freq: Float, setBy receiver: Int32) {
        frequencyUpdatedTo(freq, receiver: receiver)
        clicked(freq, secondsAgo: 0.0, option: (receiver != 0), fromWaterfall: false, waterfallID: 0)
    }

    @objc(setTimeOffset:index:)
    override func setTimeOffset(_ timeOffset: Float, index: Int32) {
        if transmitState == false {
            if index == 0 { rx1?.setTimeOffset(timeOffset) } else { rx2?.setTimeOffset(timeOffset) }
        }
    }

    //  frequency update from PSKReceiver
    @objc(frequencyUpdatedTo:receiver:)
    func frequencyUpdatedTo(_ tone: Float, receiver uniqueID: Int32) {
        waterfall?.forceToneTo(tone, receiver: uniqueID)
    }

    @objc(setAFCState:)
    func setAFCState(_ state: Bool) {
        rx1Control?.setAFCState(DarwinBoolean(state))
        rx2Control?.setAFCState(DarwinBoolean(state))
    }

    @objc(useControlButton:)
    func useControlButton(_ state: Bool) {
        waterfall?.useControlButton(state)
        rx1?.useControlButton(state)
        rx2?.useControlButton(state)
    }

    @objc(setVisibleState:)
    override func setVisibleState(_ visible: Bool) {
        if pskAuralMonitor != nil { pskAuralMonitor?.setModemActive(DarwinBoolean(visible).boolValue) }
        rx1?.updateVisibleState(visible)
        rx2?.updateVisibleState(visible)
        configObj()?.updateVisibleState(visible)
    }

    @objc(receiver:)
    func receiver(_ index: Int32) -> PSKReceiver! {
        if index == 1 { return rx2 }
        return rx1
    }

    @objc(setWaterfallOffset:sideband:)
    func setWaterfallOffset(_ freq: Float, sideband: Int32) {
        let offset = abs(freq)
        rx1?.setVFOOffset(offset, sideband: sideband != 0)
        rx2?.setVFOOffset(offset, sideband: sideband != 0)

        waterfall?.setOffset(freq, sideband: sideband)
    }

    //  v0.78 (Private API)
    func setupAuralMonitorDefaultPreferences(_ pref: Preferences!) {
        pref.setInt(1, forKey: kMasterMute)
        pref.setFloat(0.5, forKey: kMasterVolume)

        //  create sub dictionaries for the two receivers, transmitter and wideband
        for i in 0..<4 {
            auralMonitorPlist[i] = SubDictionary()
        }

        //  initially disable all channels
        for i in 0..<4 { auralMonitorPlist[i]?.setInt(0, forKey: kMonitorEnable) }

        for i in 0..<2 {
            //  receiver defaults
            let p = auralMonitorPlist[i]
            p?.setFloat(0.0, forKey: kMonitorAttenuator)
            p?.setInt(0, forKey: kMonitorFixSelect)
            p?.setFloat(1760.0, forKey: kMonitorFrequency)
        }

        //  transmitter defaults
        let p = auralMonitorPlist[2]
        p?.setFloat(6.0, forKey: kMonitorAttenuator)
        p?.setInt(0, forKey: kMonitorFixSelect)
        p?.setFloat(1048.0, forKey: kMonitorFrequency)

        //  wideband default
        auralMonitorPlist[3]?.setFloat(10.0, forKey: kMonitorAttenuator)
    }

    //  before Plist is read in
    @objc(setupDefaultPreferences:)
    override func setupDefaultPreferences(_ pref: Preferences!) {
        super.setupDefaultPreferences(pref)
        setupAuralMonitorDefaultPreferences(pref)   //  v0.78

        pref.setString("Verdana", forKey: kPSK1Font)
        pref.setFloat(14.0, forKey: kPSK1FontSize)
        pref.setString("Verdana", forKey: kPSK2Font)
        pref.setFloat(14.0, forKey: kPSK2FontSize)
        pref.setString("Verdana", forKey: kPSKTxFont)
        pref.setFloat(14.0, forKey: kPSKTxFontSize)
        pref.setInt(1, forKey: kPSKWaterfallNR)      //  v0.73

        pref.setRed(1.0, green: 0.8, blue: 0.0, forKey: kPSKTextColor)
        pref.setRed(0.0, green: 0.8, blue: 1.0, forKey: kPSKSentColor)
        pref.setRed(0.0, green: 0.0, blue: 0.0, forKey: kPSKBackgroundColor)
        pref.setRed(0.0, green: 1.0, blue: 0.0, forKey: kPSKPlotColor)

        configObj()?.setupDefaultPreferences(pref)

        pref.setFloat(1.0, forKey: kPSKSquelchA)
        pref.setFloat(1.0, forKey: kPSKSquelchB)

        for i in 0..<3 {
            (macroSheet[i] as? PSKMacros)?.setupDefaultPreferences(pref, option: Int32(i))
        }
    }

    private static let kState: [NSControl.StateValue] = [.off, .on]

    func updateFromAuralMonitorPlist(_ pref: Preferences!) {
        //  merge in values from the plist file, if any
        if let d = pref.dictionary(forKey: kAuralMonitor0) { auralMonitorPlist[0]?.dictionary().addEntries(from: d) }
        if let d = pref.dictionary(forKey: kAuralMonitor1) { auralMonitorPlist[1]?.dictionary().addEntries(from: d) }
        if let d = pref.dictionary(forKey: kAuralTransmitter) { auralMonitorPlist[2]?.dictionary().addEntries(from: d) }
        if let d = pref.dictionary(forKey: kAuralWideband) { auralMonitorPlist[3]?.dictionary().addEntries(from: d) }

        (masterMute as? NSButton)?.state = (pref.intValue(forKey: kMasterMute) == 1) ? .on : .off
        masterMuteChanged()
        (masterLevel as? NSControl)?.floatValue = pref.floatValue(forKey: kMasterVolume)
        masterLevelChanged()

        //  aural channel enable buttons
        for i in 0..<4 {
            let p = auralMonitorPlist[i]
            let button = auralAction[i].enableButton
            //  original indexed a 2-element table with (value & 3); non-zero => on
            button?.state = ((Int(p?.intValueForKey(kMonitorEnable) ?? 0) & 3) != 0) ? .on : .off
            enableChanged(button)
        }
        //  aural channel attenuators
        for i in 0..<4 {
            let p = auralMonitorPlist[i]
            let field = auralAction[i].attenuationField
            field?.floatValue = p?.floatValueForKey(kMonitorAttenuator) ?? 0
            attenuatorChanged(field)
        }
        //  aural channel fixed/float selection
        for i in 0..<3 {
            let p = auralMonitorPlist[i]
            let matrix = auralAction[i].floatMatrix
            matrix?.selectCell(atRow: Int(p?.intValueForKey(kMonitorFixSelect) ?? 0), column: 0)
            floatMatrixChanged(matrix)
        }
        //  aural channel fixed frequencies
        for i in 0..<3 {
            let p = auralMonitorPlist[i]
            let field = auralAction[i].fixedFrequency
            field?.floatValue = p?.floatValueForKey(kMonitorFrequency) ?? 0
            fixedFrequencyChanged(field)
        }
    }

    //  set up this Modem's setting from the Plist
    @objc(updateFromPlist:)
    override func updateFromPlist(_ pref: Preferences!) -> Bool {
        _ = super.updateFromPlist(pref)
        updateFromAuralMonitorPlist(pref)

        _ = rx1?.updateFromPlist(pref)
        _ = rx2?.updateFromPlist(pref)

        var fontName = pref.stringValue(forKey: kPSK1Font)
        var fontSize = pref.floatValue(forKey: kPSK1FontSize)
        receive1View?.setTextFont(fontName ?? "", size: fontSize, attribute: receive1TextAttribute)

        fontName = pref.stringValue(forKey: kPSK2Font)
        fontSize = pref.floatValue(forKey: kPSK2FontSize)
        receive2View?.setTextFont(fontName ?? "", size: fontSize, attribute: receive2TextAttribute)

        fontName = pref.stringValue(forKey: kPSKTxFont)
        fontSize = pref.floatValue(forKey: kPSKTxFontSize)
        transmitView?.setTextFont(fontName ?? "", size: fontSize, attribute: transmitTextAttribute!)

        //  v0.73
        waterfall?.setNoiseReductionState(pref.intValue(forKey: kPSKWaterfallNR) != 0)

        rx1Control?.setSquelchValue(pref.floatValue(forKey: kPSKSquelchA))
        rx2Control?.setSquelchValue(pref.floatValue(forKey: kPSKSquelchB))

        manager?.showSplash("Updating PSK configurations")
        _ = configObj()?.updateFromPlist(pref)

        manager?.showSplash("Loading PSK macros")
        for i in 0..<3 {
            _ = (macroSheet[i] as? PSKMacros)?.updateFromPlist(pref, option: Int32(i))
        }
        //  check slashed zero key
        useSlashedZero(pref.intValue(forKey: kSlashZeros) != 0)

        plistHasBeenUpdated = true                  //  v0.53d
        return true
    }

    func retrieveForAuralMonitorPlist(_ pref: Preferences!) {
        pref.setInt(((masterMute as? NSButton)?.state == .on) ? 1 : 0, forKey: kMasterMute)
        pref.setFloat((masterLevel as? NSControl)?.floatValue ?? 0, forKey: kMasterVolume)

        //  aural channel enable buttons
        for i in 0..<4 {
            let p = auralMonitorPlist[i]
            let button = auralAction[i].enableButton
            let n: Int32 = (button?.state == .on) ? 1 : 0
            p?.setInt(n, forKey: kMonitorEnable)
        }
        //  aural channel attenuators
        for i in 0..<4 {
            let p = auralMonitorPlist[i]
            let field = auralAction[i].attenuationField
            p?.setFloat(field?.floatValue ?? 0, forKey: kMonitorAttenuator)
        }
        //  aural channel fix/float selection
        for i in 0..<3 {
            let p = auralMonitorPlist[i]
            let matrix = auralAction[i].floatMatrix
            let n = Int32(matrix?.selectedRow ?? 0)
            p?.setInt(n, forKey: kMonitorFixSelect)
        }
        //  aural channel fixed frequency
        for i in 0..<3 {
            let p = auralMonitorPlist[i]
            let field = auralAction[i].fixedFrequency
            p?.setFloat(field?.floatValue ?? 0, forKey: kMonitorFrequency)
        }

        //  set subdictionaries into plist
        pref.setDictionary(auralMonitorPlist[0]?.dictionary() as? [AnyHashable: Any], forKey: kAuralMonitor0)
        pref.setDictionary(auralMonitorPlist[1]?.dictionary() as? [AnyHashable: Any], forKey: kAuralMonitor1)
        pref.setDictionary(auralMonitorPlist[2]?.dictionary() as? [AnyHashable: Any], forKey: kAuralTransmitter)
        pref.setDictionary(auralMonitorPlist[3]?.dictionary() as? [AnyHashable: Any], forKey: kAuralWideband)
    }

    //  retrieve the preferences that are in use
    @objc(retrieveForPlist:)
    override func retrieveForPlist(_ pref: Preferences!) {
        if plistHasBeenUpdated == false { return }      //  v0.53d
        super.retrieveForPlist(pref)
        retrieveForAuralMonitorPlist(pref)

        rx1?.retrieveForPlist(pref)
        rx2?.retrieveForPlist(pref)

        pref.setFloat(rx1Control?.squelchValue() ?? 0, forKey: kPSKSquelchA)
        pref.setFloat(rx2Control?.squelchValue() ?? 0, forKey: kPSKSquelchB)

        if ((NSApp.delegate as? AppDelegate)?.isLite() ?? false) == false {    //  v0.64d don't play with fonts of Lite window
            if let font = receive1View?.font {
                pref.setString(font.fontName, forKey: kPSK1Font)
                pref.setFloat(Float(font.pointSize), forKey: kPSK1FontSize)
            }
            if let font = receive2View?.font {
                pref.setString(font.fontName, forKey: kPSK2Font)
                pref.setFloat(Float(font.pointSize), forKey: kPSK2FontSize)
            }
            if let font = transmitView?.font {
                pref.setString(font.fontName, forKey: kPSKTxFont)
                pref.setFloat(Float(font.pointSize), forKey: kPSKTxFontSize)
            }
        }
        //  v0.73
        pref.setInt((waterfall?.noiseReductionState() == true) ? 1 : 0, forKey: kPSKWaterfallNR)

        configObj()?.retrieveForPlist(pref)
        for i in 0..<3 {
            (macroSheet[i] as? PSKMacros)?.retrieveForPlist(pref, option: Int32(i))
        }
    }

    //  need to add text colors to the two separate receive views
    @objc(setTextColor:sentColor:backgroundColor:plotColor:)
    override func setTextColor(_ inTextColor: NSColor!, sentColor sentTColor: NSColor!, backgroundColor bgColor: NSColor!, plotColor pColor: NSColor!) {
        super.setTextColor(inTextColor, sentColor: sentTColor, backgroundColor: bgColor, plotColor: pColor)
        receive1View?.setTextColor(textColor, attribute: receive1TextAttribute)
        receive2View?.setTextColor(textColor, attribute: receive2TextAttribute)
        receive1View?.backgroundColor = bgColor         //  v0.38
        receive2View?.backgroundColor = bgColor         //  v0.38
    }

    //  sideband state (set from PSKConfig's LSB/USB button).  NO = LSB
    @objc(selectAlternateSideband:)
    func selectAlternateSideband(_ state: Bool) {
        waterfall?.setSideband(state ? 1 : 0)
    }

    @objc override func sendMessageImmediately() {
        transmitCountLock?.lock()
        transmitCount += 1
        transmitCountLock?.unlock()
    }

    /* local */
    //  this gets periodically called
    @objc(timedOut:)
    func timedOut(_ timer: Timer!) {
        if charactersSinceTimerStarted == 0 {
            //  timed out!
            changeTransmitStateTo(false)
        }
        charactersSinceTimerStarted = 0
    }

    //  v0.70
    @objc(setUseShiftJIS:)
    func setUseShiftJIS(_ state: Bool) {
        (shiftJISTextField as? NSTextField)?.stringValue = state ? NSLocalizedString("Shift-JIS", comment: "") : ""
        rx1?.setUseShiftJIS(state)
        //  rx2 is always in ASCII
    }

    @objc(setUseRawForPSK:)
    func setUseRawForPSK(_ state: Bool) {
        rx1?.setUseRawForPSK(state)
        //  rx2 is always in ASCII
    }

    //  (Private API) v0.70 -- convert Unicode to other encodings
    @objc(transmitCharacterFilter:)
    func transmitCharacterFilter(_ uch: unichar) {
        let ch = Int(uch) & 0xffff

        var useShiftJIS = false
        let vfo = txControl?.selectedTransceiver() ?? 0
        if vfo == 0 { useShiftJIS = rx1?.useShiftJIS_() ?? false }

        if useShiftJIS {
            //  Send unicode as double byte Shift-JIS code
            configObj()?.transmitDoubleByteCharacter(Int32(unicodeToJis[ch * 2]), second: Int32(unicodeToJis[ch * 2 + 1]))
        } else {
            //  not Unicode
            var c = ch
            if c > 255 { c = Int(UInt8(ascii: ".")) }
            configObj()?.transmitCharacter(Int32(c))
        }
    }

    //  allow receive data to flush through the pipeline before changing text color
    //  and sending transmit buffer
    @objc(delayTransmit:)
    func delayTransmit(_ timer: Timer!) {
        transmitView?.select()
        //  send any pending storage
        transmitViewLock?.lock()
        if let storage = transmitView?.textStorage {
            let string = storage.string as NSString
            while indexOfUntransmittedText < unmarkedTextLength {
                if Int(indexOfUntransmittedText) >= string.length { break }   //  masked to avoid OOB
                let uch = string.character(at: Int(indexOfUntransmittedText))
                indexOfUntransmittedText += 1
                transmitCharacterFilter(uch)
                charactersSinceTimerStarted += 1
            }
        }
        transmitViewLock?.unlock()
    }

    @objc(checkTransmitBuffer:)
    func checkTransmitBuffer(_ timer: Timer!) {
        transmitViewLock?.lock()
        if indexOfUntransmittedText < unmarkedTextLength {
            if let storage = transmitView?.textStorage {
                let string = storage.string as NSString
                let total = Int32(string.length)
                while indexOfUntransmittedText < unmarkedTextLength {
                    if indexOfUntransmittedText >= total { break }        //  sanity check
                    let uch = string.character(at: Int(indexOfUntransmittedText))
                    indexOfUntransmittedText += 1
                    transmitCharacterFilter(uch)
                    charactersSinceTimerStarted += 1
                }
            }
        }
        transmitViewLock?.unlock()
    }

    @objc(transmitting)
    func transmitting() -> Bool {
        return transmitState
    }

    @objc(useSlashedZero:)
    override func useSlashedZero(_ state: Bool) {
        super.useSlashedZero(state)
        rx1?.useSlashedZero(state)
        rx2?.useSlashedZero(state)
    }

    @objc(selectTransceiver:andChangeTransmitStateTo:)
    override func selectTransceiver(_ transceiver: Transceiver!, andChangeTransmitStateTo transmit: Bool) {
        let index: Int32 = (transceiver === transceiver1) ? 0 : 1
        let control = inContestMode ? contestTxControl : txControl

        if index != (control?.selectedTransceiver() ?? -1) {
            control?.selectTransceiver(index)
        }
        enterTransmitMode(transmit)
    }

    @objc override func selectedTransceiver() -> Int32 {
        let control = inContestMode ? contestTxControl : txControl
        return (control?.selectedTransceiver() ?? 0) + 1
    }

    //  v0.89  also called from AppleScript
    @objc override func flushClickBuffer() {
        rx1?.clearClickBuffer()
        rx2?.clearClickBuffer()
    }

    //  Application sends this through the ModemManager when quitting
    @objc override func applicationTerminating() {
        ptt?.applicationTerminating()                //  v0.89
    }

    @objc(changeTransmitStateTo:)
    override func changeTransmitStateTo(_ state: Bool) {
        var indicatorState: Int32

        if state == false {     //  v0.66
            //  state is changed back to receive state, mark as backspace limit
            hardLimitForBackspace = indexOfUntransmittedText
        }
        transmitState = configObj()?.turnOnTransmission(state, button: transmitButton as? NSButton, mode: currentPSKMode()) ?? false     // v0.47

        if transmitState == true {
            executePTT(true)
            indicatorState = TxActive
            transmitView?.window?.makeFirstResponder(transmitView)
            timeout?.invalidate()
            charactersSinceTimerStarted = 0
            if manager?.useWatchdog() == true {
                timeout = Timer.scheduledTimer(timeInterval: 150, target: self, selector: #selector(timedOut(_:)), userInfo: self, repeats: true)
            }
            transmitBufferCheck = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(checkTransmitBuffer(_:)), userInfo: self, repeats: true)
            //  set text color in receive view and turn on transmit
            Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(delayTransmit(_:)), userInfo: self, repeats: false)
            flushClickBuffer()      //  v0.89
        } else {
            timeout?.invalidate()
            timeout = nil
            transmitBufferCheck?.invalidate()
            transmitBufferCheck = nil
            executePTT(false)
            transmitCountLock?.lock()
            transmitCount = 0
            transmitCountLock?.unlock()
            indicatorState = TxReady
            setSentColor(false, view: activeReceiveView, textAttribute: activeReceiveTextAttribute)
            transmitView?.select()
        }

        let xcvr = selectedReceiver()
        if xcvr == 0 {
            rx2?.setTransmitLightState(TxOff)
            rx1?.setTransmitLightState(indicatorState)
        } else {
            rx1?.setTransmitLightState(TxOff)
            rx2?.setTransmitLightState(indicatorState)
        }
    }

    @objc func setFrequencyDefined() {
        frequencyDefined = true
    }

    //  this overrides the method in Modem that is called from the app
    @objc(enterTransmitMode:)
    override func enterTransmitMode(_ state: Bool) {
        if !frequencyDefined { return }     //  return if the waterfall has not been previously clicked

        if state != transmitState {
            let xcvr = selectedReceiver()
            if state == true {
                //  immediately change state to transmit
                activeReceiveView = (xcvr == 0) ? receive1View : receive2View
                changeTransmitStateTo(state)
            } else {
                //  enter a %[rx] character into the stream
                transmitView?.insertInTextStorage(String(format: "%c", 5))  /* ^E */
                let rx = (xcvr == 0) ? rx1 : rx2
                rx?.setTransmitLightState(TxWait)
            }
        }
    }

    @objc(selectView)
    func selectView() {
        let xcvr = selectedReceiver()
        activeReceiveView = (xcvr == 0) ? receive1View : receive2View
    }

    /* local */
    @objc(canTransmit)
    func canTransmit() -> Bool {
        let xcvr = selectedReceiver()
        return (xcvr == 0) ? (rx1?.canTransmit() ?? false) : (rx2?.canTransmit() ?? false)
    }

    @objc func flushOutput() {
        transmitCountLock?.lock()
        transmitCount = 0
        transmitCountLock?.unlock()
        //  flush transmit view also
        indexOfUntransmittedText = Int32(transmitView?.textStorage?.length ?? 0)
        //  now flush whatever is in the apsk bit buffer
        configObj()?.flushTransmitBuffer()
    }

    //  this overrides the method in Modem
    @objc override func flushAndLeaveTransmit() {
        flushOutput()
        enterTransmitMode(false)
    }

    @objc(inputAttenuator:)
    override func inputAttenuator(_ config: ModemConfig!) -> NSSlider! {
        return inputAttenuatorOutlet
    }

    @objc func transmitButtonChanged() {
        let state = ((transmitButton as? NSButton)?.state == .on)

        if state {
            if !(configObj()?.soundInputActive() ?? false) {
                //  check if A/D is active
                (transmitButton as? NSButton)?.state = .off
                waterfall?.clearMarkers()
                Messages.alert(withMessageText: NSLocalizedString("Sound Card not active", comment: ""), informativeText: NSLocalizedString("Select Sound Card", comment: ""))
                return
            }
            if !canTransmit() {
                //  check if receive frequency has been selected
                (transmitButton as? NSButton)?.state = .off
                Messages.alert(withMessageText: NSLocalizedString("Selected PSK Transceiver not on", comment: ""), informativeText: NSLocalizedString("need to set xcvr", comment: ""))
                flushOutput()
                return
            }
        }
        enterTransmitMode(state)
    }

    @objc func squelchChanged() {
    }

    @objc func inputAttenuatorChanged() {
        configObj()?.inputSource()?.setDeviceLevel(inputAttenuatorOutlet)
    }

    @objc(flushTransmitStream:)
    func flushTransmitStream(_ sender: Any!) {
        flushOutput()
    }

    //  v0.97
    @objc func nextStationInTableView() {
        rx1?.nextStationInTableView()
    }

    //  v1.01c
    @objc func previousStationInTableView() {
        rx1?.previousStationInTableView()
    }

    //  v0.97
    @objc(openPSKTableView:)
    func openPSKTableView(_ state: Bool) {
        rx1?.enableTableView(state)
    }

    @objc(openTableView:)
    func openTableView(_ sender: Any!) {
        openPSKTableView(true)
    }

    //  Delegate of receiveView and transmitView
    func textView(_ textView: NSTextView, shouldChangeTextIn original: NSRange, replacementString replace: String?) -> Bool {
        var start = 0, total = 0, length = 0
        let rlen = (replace as NSString?)?.length ?? 0

        if textView === receiveView {
            if rlen != 0 {
                NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
                Messages.alert(withMessageText: NSLocalizedString("text is write only", comment: ""), informativeText: NSLocalizedString("cannot insert text", comment: ""))
                return false
            }
            return true
        }
        if textView === transmitView {
            if slashZero {
                //  v0.71 fetch string as Unicode
                length = rlen
                if length > 512 { length = 512 }
                var unicodeReplacement = [unichar](repeating: 0, count: 513)
                if let ns = replace as NSString? {
                    ns.getCharacters(&unicodeReplacement, range: NSRange(location: 0, length: length))
                }
                unicodeReplacement[length] = 0

                //  quick check for existence of zero
                var hasZero = false
                var i = 0
                while unicodeReplacement[i] != 0 {
                    if unicodeReplacement[i] == unichar(UInt8(ascii: "0")) { hasZero = true }
                    i += 1
                }

                if hasZero {
                    i = 0
                    while unicodeReplacement[i] != 0 {
                        if unicodeReplacement[i] == unichar(UInt8(ascii: "0")) { unicodeReplacement[i] = unichar(Phi) }
                        i += 1
                    }
                    //  replace zeros with phi and try again
                    let replacedNSString = NSString(characters: unicodeReplacement, length: length) as String
                    transmitView?.replaceCharacters(in: original, with: replacedNSString)
                    return false
                }
            }

            transmitViewLock?.lock()                    //  v0.64
            total = transmitView?.textStorage?.length ?? 0
            start = original.location
            length = original.length

            if length == total && rlen == 0 && transmitState == false {
                //  erase all
                transmitView?.clearAll()
                indexOfUntransmittedText = 0; unmarkedTextLength = 0
                hardLimitForBackspace = 0               // v0.66
                transmitViewLock?.unlock()
                return false
            }
            //  v0.95 don't do anything with double byte and umlauts; let Cocoa call -insertText in SendView
            if transmitView?.hasMarkedText() == true {
                transmitViewLock?.unlock()
                insertionRange = transmitView?.markedRange() ?? NSRange(location: 0, length: 0)
                return true
            }
            if length > 0 {
                if length > 1 {
                    //  v0.82
                    NSSound.beep()
                    transmitViewLock?.unlock()
                    return false
                }
                if (start + length) == total {
                    //  deleting <length> characters from end
                    if (total - length) < Int(hardLimitForBackspace) {          //  deleting past transmitted text v0.65
                        NSSound.beep()
                        transmitViewLock?.unlock()                              // 0.66
                        return false
                    }
                    if transmitState == true {
                        if rlen == 0 {
                            for _ in 0..<length { configObj()?.transmitCharacter(0x08) }
                        }
                        indexOfUntransmittedText -= Int32(length)   //  v0.70 don't "backspace" index if input method is busy
                    }
                    unmarkedTextLength = Int32(total - length)
                    transmitViewLock?.unlock()
                    return true
                }
                if transmitState == true {
                    NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
                    transmitViewLock?.unlock()
                    return false
                }
                //  not yet transmitted
                if original.location < Int(indexOfUntransmittedText) {
                    NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
                    Messages.alert(withMessageText: NSLocalizedString("text already sent", comment: ""), informativeText: NSLocalizedString("cannot insert after sending", comment: ""))
                    transmitViewLock?.unlock()
                    return false
                }
                //  should not get here, sanity check on lengths
                unmarkedTextLength = Int32(total); indexOfUntransmittedText = Int32(total)
                transmitViewLock?.unlock()
                return true
            }
            //  insertion length = 0 (single byte text)
            if start != total {
                //  inserting in the middle of the transmitView
                if transmitState == true {
                    //  always insert text at the end when in transmit state
                    NSSound.beep()
                    transmitView?.insertAtEnd(replace ?? "")
                    transmitViewLock?.unlock()
                    return false
                } else {
                    if original.location < Int(indexOfUntransmittedText) {
                        //  attempt to insert into text that has already been transmitted
                        NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
                        Messages.alert(withMessageText: NSLocalizedString("text already sent", comment: ""), informativeText: NSLocalizedString("cannot insert after sending", comment: ""))
                        transmitViewLock?.unlock()
                        return false
                    }
                    transmitViewLock?.unlock()
                    return true
                }
            }
            if rlen != 0 {
                //  character will be inserted when we return, which causes SendView to call -insertedText
                transmitViewLock?.unlock()
                insertionRange = original
                return true
            }
        }
        transmitViewLock?.unlock()
        return true
    }

    //  handle callsign clicks
    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange, toCharacterRange newSelectedCharRange: NSRange) -> NSRange {
        if textView === receive1View || textView === receive2View {
            //  cancel transmission if there is a repeating macro
            contestBar?.cancelIfRepeatingIsActive()                             // v0.32

            if let ev = textView as? ExchangeView, ev.getRightMouse() {          // v0.32
                if textView.lockFocusIfCanDraw() {
                    let range = captureCallsign(textView, willChangeSelectionFromCharacterRange: oldSelectedCharRange, toCharacterRange: newSelectedCharRange)
                    textView.unlockFocus()
                    return range
                }
            }
        }
        return newSelectedCharRange
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        let obj = notification.object as AnyObject?

        if obj === receive1View || obj === receive2View {
            captureSelection(obj as? NSTextView)
        }
        if contestBar?.textInsertedFromRepeat() == true { return }      //  v0.33
        callsignClickSuccessful(enableClick)
    }

    //  --- AppleScript support ---

    //  v0.64c - return spectrum
    @objc func spectrum() -> String! {
        return ""
    }

    @objc(modulationCodeFor:)
    override func modulationCode(for transceiver: Transceiver!) -> Int32 {
        let control = (transceiver === transceiver1) ? rx1Control : rx2Control
        let mode: Int32
        switch control?.pskMode() ?? kBPSK31 {
        case kQPSK31:
            mode = Int32(ModulationQPSK31)
        case kBPSK63:
            mode = Int32(ModulationBPSK63)
        case kQPSK63:
            mode = Int32(ModulationQPSK63)
        case kBPSK63 | 0x8:
            mode = Int32(ModulationBPSK125)
        case kQPSK63 | 0x8:
            mode = Int32(ModulationQPSK125)
        default:    //  kBPSK31
            mode = Int32(ModulationBPSK31)
        }
        return mode
    }

    @objc(setModulationCodeFor:to:)
    override func setModulationCode(for transceiver: Transceiver!, to code: Int32) {
        let control = (transceiver === transceiver1) ? rx1Control : rx2Control
        let mode: String
        switch code {
        case Int32(ModulationQPSK31):
            mode = "QPSK31"
        case Int32(ModulationBPSK63):
            mode = "BPSK63"
        case Int32(ModulationQPSK63):
            mode = "QPSK63"
        case Int32(ModulationBPSK125):
            mode = "BPSK125"
        case Int32(ModulationQPSK125):
            mode = "QPSK125"
        default:    //  ModulationBPSK31
            mode = "BPSK31"
        }
        control?.changeModeToString(mode)
    }

    @objc(frequencyFor:)
    override func frequencyFor(_ module: Module!) -> Float {
        let receiver = (module?.transceiver() === transceiver1) ? rx1 : rx2
        return (module?.isReceiver() == true) ? (receiver?.rxTone() ?? 0) : (receiver?.txTone() ?? 0)
    }

    @objc(setFrequency:module:)
    override func setFrequency(_ freq: Float, module: Module!) {
        let receiver = (module?.transceiver() === transceiver1) ? rx1 : rx2
        if module?.isReceiver() == true {
            receiver?.setAndDisplayRxTone(freq)
        } else {
            receiver?.setAndDisplayTxTone(freq)
            configObj()?.setTransmitFrequency(freq)
        }
    }

    @objc(setTimeOffset:module:)
    func setTimeOffset(_ offset: Float, module: Module!) {
        let receiver = (module?.transceiver() === transceiver1) ? rx1 : rx2
        if module?.isReceiver() == true {
            receiver?.setTimeOffset(offset)
        }
    }

    @objc(transmitString:)
    override func transmitString(_ s: UnsafePointer<CChar>!) {
        var p = s
        while let pp = p, pp.pointee != 0 {
            let uch = unichar(bitPattern: Int16(pp.pointee))
            transmitCharacterFilter(uch)
            p = pp + 1
        }
    }

    //  ------------ deprecated AppleScripts ----------------
    @objc(getRxOffset:)
    func getRxOffset(_ trx: Int32) -> Float {
        return (trx == 0) ? (rx1?.rxOffset() ?? 0) : (rx2?.rxOffset() ?? 0)
    }

    @objc(setRxOffset:freq:)
    func setRxOffset(_ trx: Int32, freq: Float) {
        if trx == 0 { rx1?.setAndDisplayRxOffset(freq) } else { rx2?.setAndDisplayRxOffset(freq) }
    }

    @objc(getTxOffset:)
    func getTxOffset(_ trx: Int32) -> Float {
        return (trx == 0) ? (rx1?.txOffset() ?? 0) : (rx2?.txOffset() ?? 0)
    }

    @objc(setTxOffset:freq:)
    func setTxOffset(_ trx: Int32, freq: Float) {
        if trx == 0 { rx1?.setAndDisplayTxOffset(freq) } else { rx2?.setAndDisplayTxOffset(freq) }
    }

    //  PSK (transmit) modulation
    @objc func getPskModulation() -> Int32 {
        let m: Int32
        switch currentPSKMode() {
        case kBPSK63:
            m = Int32(PSKModeBPSK63)
        case kQPSK31:
            m = Int32(PSKModeQPSK31)
        case kQPSK63:
            m = Int32(PSKModeQPSK63)
        default:    //  kBPSK31
            m = Int32(PSKModeBPSK31)
        }
        return m
    }

    @objc(changePskModulationTo:)
    func changePskModulationTo(_ modulation: Int32) {
        let index: Int32
        switch modulation {
        case Int32(PSKModeBPSK63):
            index = kBPSK63
        case Int32(PSKModeQPSK31):
            index = kQPSK31
        case Int32(PSKModeQPSK63):
            index = kQPSK63
        default:    //  PSKModeBPSK31
            index = kBPSK31
        }
        //  get the PSK controls for the "current" transceiver
        let trx = txControl?.selectedTransceiver() ?? 0
        let control = (trx == 0) ? rx1Control : rx2Control
        control?.changeModeToIndex(index)
    }

    //  v0.95 (delegate of SendView)
    //  Bump text length when text is inserted at the end of the buffer.
    @objc(insertedText:)
    func insertedText(_ string: String!) {
        unmarkedTextLength = Int32(insertionRange.location + ((string ?? "") as NSString).length)
    }

    //  v0.96c
    @objc(selectView:)
    override func selectView(_ index: Int32) {
        var pview: NSView? = nil
        switch index {
        case 1:
            pview = receive1View
        case 2:
            pview = receive2View
        case 0:
            pview = transmitView
        default:
            break
        }
        if let pview = pview { pview.window?.makeFirstResponder(pview) }
    }
}
