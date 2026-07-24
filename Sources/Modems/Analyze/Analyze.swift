//
//  Analyze.swift
//  cocoaModem
//
//  Created by Kok Chen on 2/22/05.
//  Swift port of Analyze.m / Analyze.h.
//
//  The Analyze mode tab.  Analyze : Modem.  It is instantiated by StdManager via
//  -initIntoTabView:manager: and loads the "Analyze" nib.
//
//  Port notes:
//   * Every original ivar keeps its EXACT name.  The `id` outlets become
//     `@objc var … : AnyObject!` and are messaged through optional chaining /
//     casts; the RTTYTransceiver `a` is the shared Swift reference type declared
//     in Modem.swift (`let a = RTTYTransceiver()`).
//   * RTTYRxControl, RTTYReceiver, RTTYConfig, Spectrum and AnalyzeScope are all
//     already Swift and are used through their concrete types (`config` is cast
//     to RTTYConfig — AnalyzeConfig is its subclass).  RTTYStereoReceiver is
//     still Objective-C, so its two extra selectors (setScope:/setFileRepeat:)
//     are messaged through a small informal @objc protocol on a.receiver.
//   * The `RTTYConfigSet set` aggregate built in -awakeFromNib is reproduced
//     field-by-field in the SAME positional order as the original C aggregate
//     initialiser (see the CONFIG-SET note below).
//

import Cocoa

//  ---------------------------------------------------------------------------
//  RTTYConfigSet carries __unsafe_unretained NSString* key members, which Swift
//  imports as Unmanaged<NSString>.  Analyze populates the set with the plist-key
//  #defines (imported as String).  passUnretained on a transient bridge would
//  dangle before -awakeFromModem: reads it, so bridged keys are held for the
//  process lifetime in this store (mirrors RTTY.swift's file-scope NSString
//  constants).  Keys are compile-time constants, so this never grows unbounded.
private var kAnalyzeKeyStore: [NSString] = []
private func aKey(_ s: String) -> Unmanaged<NSString> {
    let ns = s as NSString
    kAnalyzeKeyStore.append(ns)
    return Unmanaged.passUnretained(ns)
}

//  ---------------------------------------------------------------------------
//  RTTYStereoReceiver-specific selectors (a.receiver is typed RTTYReceiver; the
//  runtime object is its still-Objective-C RTTYStereoReceiver subclass).
//  ---------------------------------------------------------------------------
@objc private protocol AnalyzeStereoReceiverInformal {
    @objc(setScope:) func setScope(_ scope: Any!)
    @objc(setFileRepeat:) func setFileRepeat(_ state: Bool)
}

//  Spectrum plot popup index tables (were file-static C arrays in Analyze.m).
private let kAnalyzeTimeConstants: [Float] = [ 0.2, 0.5, 1.5, 4.0 ]
private let kAnalyzeRanges: [Float] = [ 40.0, 60.0, 80.0 ]

@objc(Analyze)
class Analyze: Modem {

    //  --- IBOutlets (id) ---
    @objc var spectrum: AnyObject!
    @objc var timeConstant: AnyObject!
    @objc var dynamicRange: AnyObject!

    @objc var rxctrl: AnyObject!

    //  plot
    @objc var scope: AnyObject!

    @objc var thread: Thread!
    //  shared RTTYTransceiver reference type (defined in Modem.swift)
    let a = RTTYTransceiver()

    //  RTTY Prefs
    @objc var usos: Bool = false
    @objc var bell: Bool = false
    @objc var robust: Bool = false
    @objc var repeatState: Bool = false

    //  =======================================================================
    //  Initialization
    //  =======================================================================

    @objc(initIntoTabView:manager:)
    override init?(into tabview: NSTabView!, manager mgr: ModemManager!) {
        mgr.showSplash("Creating Analysis Modem")

        super.init(into: tabview, nib: "Analyze", manager: mgr)

        //  super loaded the nib (and connected the outlets / ran -awakeFromNib)
        let control = rxctrl as? RTTYRxControl
        control?.setupWithClient(self, index: 0)
        a.control = control
        a.receiver = a.control?.receiver_()
        (a.receiver as AnyObject?)?.setScope?(scope)
        a.view = a.control?.view()
        //  RTTYTransceiver.textAttribute and -[RTTYRxControl textAttribute] are
        //  both TextAttribute* — store the pointer directly.
        a.textAttribute = a.control?.textAttribute()
        a.control?.setName("")

        a.receiver?.setReceiveView(control?.view())

        manager = mgr
    }

    override func awakeFromNib() {
        //  CONFIG-SET note:  the original Analyze.m built this C aggregate with a
        //  positional initialiser that supplied only 23 of RTTYConfigSet's 25
        //  fields.  Because RTTYConfigSet carries rxPolarity/txPolarity fields
        //  that Analyze does not use, the trailing keys land two slots "early"
        //  (e.g. kAnalyzePrefs falls into `rxPolarity`).  This is reproduced
        //  VERBATIM below so behaviour is identical to the Objective-C original.
        var set = RTTYConfigSet()
        set.channel = 2                                 // stereo
        set.inputDevice = aKey(kAnalyzeInputDevice)
        set.outputDevice = aKey(kAnalyzeOutputDevice)
        set.outputLevel = aKey(kAnalyzeOutputLevel)
        set.outputAttenuator = aKey(kAnalyzeOutputAttenuator)
        set.tone = aKey(kAnalyzeTone)
        set.mark = aKey(kAnalyzeMark)
        set.space = aKey(kAnalyzeSpace)
        set.baud = aKey(kAnalyzeBaud)
        //  controlWindow left nil
        set.squelch = aKey(kAnalyzeSquelch)
        set.active = aKey(kAnalyzeActive)
        set.stopBits = aKey(kAnalyzeStopBits)
        set.sideband = aKey(kAnalyzeMode)
        set.rxPolarity = aKey(kAnalyzePrefs)
        set.txPolarity = aKey(kAnalyzeTextColor)
        set.prefs = aKey(kAnalyzeSentColor)
        set.textColor = aKey(kAnalyzeBackgroundColor)
        set.sentColor = aKey(kAnalyzePlotColor)
        //  backgroundColor, plotColor, vfoOffset, fskSelection left nil
        set.usesRTTYAuralMonitor = false
        //  auralMonitor left nil

        ident = "Analyze"
        modemTabItem?.label = "Analyze"

        (config as? RTTYConfig)?.awakeFromModem(&set, rttyRxControl: rxctrl, txConfig: nil)

        initColors()
        //  prefs
        usos = false
        robust = false
        bell = true
        thread = Thread.current
    }

    func setupSpectrum() {
        a.control?.setSpectrumView(spectrum as? Spectrum)
        //  clamp popup indices to the static tables (avoids Swift OOB traps;
        //  the Objective-C code indexed the C arrays without bounds checks)
        let t = max(0, min(kAnalyzeTimeConstants.count - 1, (timeConstant as? NSPopUpButton)?.indexOfSelectedItem ?? 0))
        let dr = max(0, min(kAnalyzeRanges.count - 1, (dynamicRange as? NSPopUpButton)?.indexOfSelectedItem ?? 0))
        (spectrum as? Spectrum)?.setTimeConstant(kAnalyzeTimeConstants[t], dynamicRange: kAnalyzeRanges[dr])
        (spectrum as? Spectrum)?.clearPlot()
    }

    override func updateSourceFromConfigInfo() {
        manager?.showSplash("Updating Analysis sound source")
        a.control?.setupRTTYReceiver()
        setupSpectrum()
    }

    @objc(selectBandwidth:)
    func selectBandwidth(_ index: Int32) {
        a.receiver?.selectBandwidth(index)
    }

    @objc(selectDemodulator:)
    func selectDemodulator(_ index: Int32) {
        a.receiver?.selectDemodulator(index)
    }

    @objc(setVisibleState:)
    override func setVisibleState(_ visible: Bool) {
        config?.updateVisibleState?(visible)
        a.receiver?.enableReceiver(visible)
    }

    @objc(setupDefaultPreferences:)
    override func setupDefaultPreferences(_ pref: Preferences!) {
        super.setupDefaultPreferences(pref)

        pref.setString("Verdana", forKey: kAnalyzeFont)
        pref.setFloat(14.0, forKey: kAnalyzeFontSize)

        (config as? RTTYConfig)?.setupDefaultPreferences(pref, rttyRxControl: a.control)
    }

    //  set up this Modem's setting from the Plist
    @objc(updateFromPlist:)
    override func updateFromPlist(_ pref: Preferences!) -> Bool {
        _ = super.updateFromPlist(pref)

        let fontName = pref.stringValue(forKey: kAnalyzeFont)
        let fontSize = pref.floatValue(forKey: kAnalyzeFontSize)
        if let attr = a.control?.textAttribute() {
            a.view?.setTextFont(fontName ?? "", size: fontSize, attribute: attr)
        }

        plistHasBeenUpdated = true                      //  v0.53d
        return true
    }

    //  retrieve the preferences that are in use
    @objc(retrieveForPlist:)
    override func retrieveForPlist(_ pref: Preferences!) {
        if plistHasBeenUpdated == false { return }       //  v0.53d
        super.retrieveForPlist(pref)

        let font = a.view?.font
        pref.setString(font?.fontName, forKey: kAnalyzeFont)
        pref.setFloat(Float(font?.pointSize ?? 0), forKey: kAnalyzeFontSize)
    }

    @objc(repeatButtonPushed:)
    func repeatButtonPushed(_ sender: Any!) {
        repeatState = (sender as? NSButton)?.state == .on
        (a.receiver as AnyObject?)?.setFileRepeat?(repeatState)
    }

    @objc(spectrumOptionChanged:)
    func spectrumOptionChanged(_ sender: Any!) {
        setupSpectrum()
    }
}
