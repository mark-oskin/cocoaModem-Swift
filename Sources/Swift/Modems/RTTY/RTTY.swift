//
//  RTTY.swift
//  cocoaModem
//
//  Created by Kok Chen on Sun May 30 2004.
//  Swift port of RTTY.m / RTTY.h.
//
//  The single-channel RTTY mode tab.  RTTY : RTTYInterface : ContestInterface :
//  MacroInterface : Modem : CMPipe.  Instantiated by StdManager via
//  -initIntoTabView:manager:, loading the "RTTY" nib.
//
//  Port notes:
//   * The C struct RTTYConfigSet has NSString* members, so Swift cannot import
//     it (a C struct holding Obj-C object pointers is non-trivial to copy and is
//     dropped by the importer).  The -awakeFromModem: methods therefore take it
//     as an OpaquePointer.  We build the struct in raw memory with the verified
//     LP64 layout (see makeRTTYConfigSet).  The key strings are file-scope
//     NSString constants so the (unretained) pointers copied into the config
//     objects stay valid.
//   * Plist keys are #define'd Obj-C string literals in Plist.h and are not
//     importable to Swift, so they are re-declared here (matching Plist.h).
//   * Text attributes are UnsafeMutablePointer<TextAttribute> (TextAttribute is
//     a C struct; -newAttribute / -textAttribute return a pointer to it).
//

import Cocoa

//  --- Plist keys (Plist.h) ---
private let kRTTYInputDevice: NSString      = "RTTY Input Device"
private let kRTTYOutputDevice: NSString     = "RTTY Output Device"
private let kRTTYOutputLevel: NSString      = "RTTY Output Sound Level"
private let kRTTYOutputAttenuator: NSString = "RTTY Output Attenuator"
private let kRTTYTone: NSString             = "RTTY Tone Select"
private let kRTTYMark: NSString             = "RTTY Mark Frequencies"
private let kRTTYSpace: NSString            = "RTTY Space Frequencies"
private let kRTTYBaud: NSString             = "RTTY Baud Rate"
private let kRTTYSquelch: NSString          = "RTTY Squelch"
private let kRTTYActive: NSString           = "RTTY Active"
private let kRTTYStopBits: NSString         = "RTTY Stop Bits"
private let kRTTYMode: NSString             = "RTTY Mode"
private let kRTTYRxPolarity: NSString       = "RTTY Rx Polarity"
private let kRTTYTxPolarity: NSString       = "RTTY Tx Polarity"
private let kRTTYPrefs: NSString            = "RTTY Prefs"
private let kRTTYTextColor: NSString        = "RTTY Text Color"
private let kRTTYSentColor: NSString        = "RTTY Sent Color"
private let kRTTYBackgroundColor: NSString  = "RTTY Background Color"
private let kRTTYPlotColor: NSString        = "RTTY Plot Color"
private let kRTTYFSKSelection: NSString     = "RTTY FSK Selection"
private let kRTTYAuralMonitor: NSString     = "RTTY Aural Monitor"

private let kRTTYFont       = "RTTY Font"
private let kRTTYFontSize   = "RTTY Font Size"
private let kRTTYTxFont     = "RTTY Tx Font"
private let kRTTYTxFontSize = "RTTY Tx Font Size"
private let kSlashZeros     = "Null for Zero"

//  ModemSource.h: LEFTCHANNEL 0
private let kLeftChannel: Int32 = 0

//  ---------------------------------------------------------------------------
//  RTTYConfigSet builder (see file header).  Verified LP64 layout:
//     int channel        @0
//     NSString* [22]     @8, 16, ... 176   (inputDevice ... fskSelection)
//     Boolean usesAural  @184
//     NSString* aural    @192
//     sizeof == 200
//  Caller must .deallocate() the returned buffer after the -awakeFromModem:
//  call has copied the struct out.
//  ---------------------------------------------------------------------------
private let kRTTYConfigSetSize = 200

private func makeRTTYConfigSet(channel: Int32, _ fields: [NSString?],
                               usesRTTYAuralMonitor: Bool, auralMonitor: NSString?) -> UnsafeMutablePointer<UInt8> {
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: kRTTYConfigSetSize)
    buf.initialize(repeating: 0, count: kRTTYConfigSetSize)
    let raw = UnsafeMutableRawPointer(buf)
    raw.storeBytes(of: channel, toByteOffset: 0, as: Int32.self)
    for (i, s) in fields.enumerated() {
        let bits = s.map { UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
        raw.storeBytes(of: bits, toByteOffset: 8 &+ i &* 8, as: UInt.self)
    }
    raw.storeBytes(of: usesRTTYAuralMonitor ? UInt8(1) : UInt8(0), toByteOffset: 184, as: UInt8.self)
    let ab = auralMonitor.map { UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
    raw.storeBytes(of: ab, toByteOffset: 192, as: UInt.self)
    return buf
}

@objc(RTTY)
class RTTY: RTTYInterface, NSTextViewDelegate {

    //  outlet from RTTY.nib
    @objc var ctrl: AnyObject!

    //  RTTY : ContestInterface : MacroPanel : Modem : NSObject
    @objc(initIntoTabView:manager:)
    override init?(into tabview: NSTabView!, manager mgr: ModemManager!) {
        mgr.showSplash("Creating RTTY Modem")

        super.init(into: tabview, nib: "RTTY", manager: mgr)

        transmitChannel = 0
        isBreakin = false

        //  RTTYConfigSet (channel + 22 NSString* + usesAural + auralMonitor)
        let set = makeRTTYConfigSet(channel: kLeftChannel,
            [ kRTTYInputDevice, kRTTYOutputDevice, kRTTYOutputLevel, kRTTYOutputAttenuator,
              kRTTYTone, kRTTYMark, kRTTYSpace, kRTTYBaud, nil, kRTTYSquelch, kRTTYActive,
              kRTTYStopBits, kRTTYMode, kRTTYRxPolarity, kRTTYTxPolarity, kRTTYPrefs,
              kRTTYTextColor, kRTTYSentColor, kRTTYBackgroundColor, kRTTYPlotColor, nil,
              kRTTYFSKSelection ],
            usesRTTYAuralMonitor: true, auralMonitor: kRTTYAuralMonitor)

        //  initialize txConfig before rxConfig
        (txConfig as? RTTYTxConfig)?.awakeFromModem(UnsafeMutablePointer<RTTYConfigSet>(OpaquePointer(set)), rttyRxControl: a.control)
        ptt = (txConfig as? RTTYTxConfig)?.pttObject()

        b.isAlive = false
        let rxControl = ctrl as? RTTYRxControl
        rxControl?.setupWithClient(self, index: 0)
        a.isAlive = true
        a.control = rxControl
        a.receiver = a.control?.receiver
        a.view = a.control?.view()
        a.textAttribute = a.control?.textAttribute()
        a.control?.setName(NSLocalizedString("Main Receiver", comment: ""))
        a.control?.useAsTransmitTonePair(true)

        (config as? RTTYConfig)?.awakeFromModem(UnsafeMutablePointer<RTTYConfigSet>(OpaquePointer(set)), rttyRxControl: a.control,
                                       txConfig: txConfig as? RTTYTxConfig)
        set.deallocate()

        currentRxView = a.control?.view()
        a.receiver?.setReceiveView(currentRxView)

        //  AppleScript text callback
        a.receiver?.registerModule(transceiver1?.receiver())
        a.transmitModule = transceiver1?.transmitter()

        manager = mgr
    }

    override func awakeFromNib() {
        ident = NSLocalizedString("RTTY", comment: "")

        awakeFromContest()
        //  use QSO transmitview
        (contestTab as? NSTabView)?.selectTabViewItem(at: 0)

        //  actions
        (transmitButton as? NSControl)?.action = #selector(transmitButtonChanged)
        (transmitButton as? NSControl)?.target = self

        initCallsign()
        initColors()
        //  RTTY macros moved to StdManager

        a.control?.setTuningIndicatorState(true)
        //  prefs
        usos = false; robust = false
        bell = true
        charactersSinceTimerStarted = 0
        timeout = nil
        transmitBufferCheck = nil
        thread = Thread.current
        //  transmit view
        indexOfUntransmittedText = 0
        transmitState = false; sentColor = false
        transmitCount = 0
        transmitCountLock = NSLock()

        transmitTextAttribute = transmitView?.newAttribute()
        transmitView?.delegate = self
        //  receive view
        receiveTextAttribute = receiveView?.newAttribute()
        receiveView?.delegate = self
    }

    //  set rxControl to be the first data client for data
    @objc(dataClient)
    override func dataClient() -> CMTappedPipe! {
        return ctrl as? CMTappedPipe
    }

    override func updateSourceFromConfigInfo() {
        manager?.showSplash("Updating RTTY sound source")
        a.control?.setupRTTYReceiver()
        (txConfig as? RTTYTxConfig)?.checkActive()
        (config as? RTTYConfig)?.checkActive()
    }

    @objc(setIgnoreNewline:)
    override func setIgnoreNewline(_ state: Bool) {
        receiveView?.setIgnoreNewline(state)
    }

    @objc(configObj:)
    override func configObj(_ index: Int32) -> ModemConfig! {
        //  always return the single config (DualRTTY overrides with two separate configs)
        return config as? ModemConfig
    }

    @objc(configObj)
    func configObj() -> RTTYConfig! {
        return config as? RTTYConfig
    }

    //  display RTTY Monitor
    @objc func showScope() {
        a.control?.showMonitor()
    }

    @objc(hideScopeOnDeactivation:)
    func hideScopeOnDeactivation(_ hide: Bool) {
        a.control?.hideMonitorOnDeactivation(hide)
    }

    @objc(setTextColor:sentColor:backgroundColor:plotColor:)
    override func setTextColor(_ inTextColor: NSColor!, sentColor sentTColor: NSColor!, backgroundColor bgColor: NSColor!, plotColor pColor: NSColor!) {
        super.setTextColor(inTextColor, sentColor: sentTColor, backgroundColor: bgColor, plotColor: pColor)
        a.control?.setPlotColor(plotColor)
    }

    //  before Plist is read in
    @objc(setupDefaultPreferences:)
    override func setupDefaultPreferences(_ pref: Preferences!) {
        super.setupDefaultPreferences(pref)

        pref.setString("Verdana", forKey: kRTTYFont)
        pref.setFloat(14.0, forKey: kRTTYFontSize)
        pref.setString("Verdana", forKey: kRTTYTxFont)
        pref.setFloat(14.0, forKey: kRTTYTxFontSize)

        pref.setRed(1.0, green: 0.8, blue: 0.0, forKey: kRTTYTextColor as String)
        pref.setRed(0.0, green: 0.8, blue: 1.0, forKey: kRTTYSentColor as String)
        pref.setRed(0.0, green: 0.0, blue: 0.0, forKey: kRTTYBackgroundColor as String)
        pref.setRed(0.0, green: 1.0, blue: 0.0, forKey: kRTTYPlotColor as String)

        (config as? RTTYConfig)?.setupDefaultPreferences(pref, rttyRxControl: a.control)
    }

    //  set up this Modem's setting from the Plist
    @objc(updateFromPlist:)
    override func updateFromPlist(_ pref: Preferences!) -> Bool {
        _ = super.updateFromPlist(pref)

        var fontName = pref.stringValue(forKey: kRTTYFont)
        var fontSize = pref.floatValue(forKey: kRTTYFontSize)
        receiveView?.setTextFont(fontName ?? "", size: fontSize, attribute: receiveTextAttribute!)

        fontName = pref.stringValue(forKey: kRTTYTxFont)
        fontSize = pref.floatValue(forKey: kRTTYTxFontSize)
        transmitView?.setTextFont(fontName ?? "", size: fontSize, attribute: transmitTextAttribute!)

        manager?.showSplash("Updating RTTY configurations")
        _ = (config as? RTTYConfig)?.updateFromPlist(pref, rttyRxControl: a.control)

        //  check slashed zero key
        useSlashedZero(pref.intValue(forKey: kSlashZeros) != 0)

        plistHasBeenUpdated = true                      //  v0.53d
        return true
    }

    //  retrieve the preferences that are in use
    @objc(retrieveForPlist:)
    override func retrieveForPlist(_ pref: Preferences!) {
        if plistHasBeenUpdated == false { return }      //  v0.53d
        super.retrieveForPlist(pref)

        if let font = receiveView?.font {
            pref.setString(font.fontName, forKey: kRTTYFont)
            pref.setFloat(Float(font.pointSize), forKey: kRTTYFontSize)
        }
        if let font = transmitView?.font {
            pref.setString(font.fontName, forKey: kRTTYTxFont)
            pref.setFloat(Float(font.pointSize), forKey: kRTTYTxFontSize)
        }

        (config as? RTTYConfig)?.retrieveForPlist(pref, rttyRxControl: a.control)
    }

    @objc(inputAttenuator:)
    override func inputAttenuator(_ config: ModemConfig!) -> NSSlider! {
        if ctrl != nil {
            return (ctrl as? RTTYRxControl)?.inputAttenuator
        }
        return nil
    }

    //  v0.96c
    @objc(selectView:)
    override func selectView(_ index: Int32) {
        var pview: NSView? = nil
        switch index {
        case 1:
            pview = receiveView
        case 0:
            pview = transmitView
        default:
            break
        }
        if let pview = pview {
            pview.window?.makeFirstResponder(pview)
        }
    }
}
