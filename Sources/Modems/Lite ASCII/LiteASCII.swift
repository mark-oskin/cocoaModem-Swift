//
//  LiteASCII.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/31/10.
//  Copyright 2010 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of LiteASCII.m / LiteASCII.h.  LiteASCII : ASCII : WFRTTY : ...
//  The single-receiver "Lite" ASCII-RTTY mode tab (loads the "LiteASCII" nib).
//
//  Port notes:
//   * As with ASCII, the Objective-C two-arg -initIntoTabView:manager: and its
//     three-arg -initIntoTabView:manager:nib: workhorse are collapsed into the
//     one designated `init?(into:manager:)` (the three-arg was only ever called
//     by the two-arg).  `isLite` is set to true right after `super.init(...)`
//     so the `if !isLite` guard in the body sees the correct value (the MRC
//     original set it in the two-arg before forwarding).
//   * LiteASCII's own construction fully replaces ASCII's, so it does NOT call
//     ASCII's designated init and (matching the original) does not re-set
//     `isASCIIModem` / `bitsPerCharacter` here.
//   * `id` IBOutlets are reached via AnyObject optional-chaining; delegates are
//     wired with KVC (see ASCII.swift note).
//

import Cocoa

//  Channel constant (ModemSource.h: #define LEFTCHANNEL 0)
private let LEFTCHANNEL: Int32 = 0

//  --- Plist keys (Plist.h #define'd @"..." macros; the "A"/main-channel set) ---
private let kASCIIMainDevice          = "ASCII Input Device A"
private let kASCIIOutputDevice        = "ASCII Output Device"
private let kASCIIOutputLevel         = "ASCII Output Sound Level"
private let kASCIIOutputAttenuator    = "ASCII Output Attenuator"
private let kASCIIMainTone            = "ASCII Main Tone Select"
private let kASCIIMainMark            = "ASCII Main Mark Frequencies"
private let kASCIIMainSpace           = "ASCII Main Space Frequencies"
private let kASCIIMainBaud            = "ASCII Main Baud Rate"
private let kASCIIMainControlWindow   = "ASCII Control Window A"
private let kASCIIMainSquelch         = "ASCII Squelch A"
private let kASCIIMainActive          = "ASCII Active A"
private let kASCIIMainStopBits        = "ASCII Stop Bits A"
private let kASCIIMainMode            = "ASCII Mode A"
private let kASCIIMainRxPolarity      = "ASCII Main Rx Polarity"
private let kASCIIMainTxPolarity      = "ASCII Main Tx Polarity"
private let kASCIIMainPrefs           = "ASCII Prefs A"
private let kASCIIMainTextColor       = "ASCII Text Color 1"
private let kASCIIMainSentColor       = "ASCII Sent Color 1"
private let kASCIIMainBackgroundColor = "ASCII Background Color 1"
private let kASCIIMainPlotColor       = "ASCII Plot Color 1"
private let kASCIIMainOffset          = "ASCII Offset A"
private let kASCIIMainFSKSelection    = "ASCII FSK Selection A"
private let kASCIIMainAuralMonitor    = "ASCII Aural Monitor A"

@objc(LiteASCII)
class LiteASCII: ASCII {

    //  --- LiteASCII ivars (exact names) ---
    @objc var txLockButton: AnyObject!              //  IBOutlet id
    @objc var oscilloscope: AnyObject!              //  IBOutlet id
    var controlWindowOpen: Bool = false

    //  =======================================================================
    //  Initialization
    //  =======================================================================

    @objc(initIntoTabView:manager:)
    override init?(into tabview: NSTabView!, manager mgr: ModemManager!) {
        mgr?.showSplash("Creating Lite ASCII Modem")

        super.init(into: tabview, nib: "LiteASCII", manager: mgr)

        isLite = true                       //  (was set in the two-arg before forwarding)
        manager = mgr
        controlWindowOpen = false           //  initially hide control window; reset after Prefs

        let ellipseFatness: Float = 0.9

        var setA = RTTYConfigSet()
        setA.channel = LEFTCHANNEL
        setA.inputDevice = cmConfigKey(kASCIIMainDevice)
        setA.outputDevice = cmConfigKey(kASCIIOutputDevice)
        setA.outputLevel = cmConfigKey(kASCIIOutputLevel)
        setA.outputAttenuator = cmConfigKey(kASCIIOutputAttenuator)
        setA.tone = cmConfigKey(kASCIIMainTone)
        setA.mark = cmConfigKey(kASCIIMainMark)
        setA.space = cmConfigKey(kASCIIMainSpace)
        setA.baud = cmConfigKey(kASCIIMainBaud)
        setA.controlWindow = cmConfigKey(kASCIIMainControlWindow)
        setA.squelch = cmConfigKey(kASCIIMainSquelch)
        setA.active = cmConfigKey(kASCIIMainActive)
        setA.stopBits = cmConfigKey(kASCIIMainStopBits)
        setA.sideband = cmConfigKey(kASCIIMainMode)
        setA.rxPolarity = cmConfigKey(kASCIIMainRxPolarity)
        setA.txPolarity = cmConfigKey(kASCIIMainTxPolarity)
        setA.prefs = cmConfigKey(kASCIIMainPrefs)
        setA.textColor = cmConfigKey(kASCIIMainTextColor)
        setA.sentColor = cmConfigKey(kASCIIMainSentColor)
        setA.backgroundColor = cmConfigKey(kASCIIMainBackgroundColor)
        setA.plotColor = cmConfigKey(kASCIIMainPlotColor)
        setA.vfoOffset = cmConfigKey(kASCIIMainOffset)
        setA.fskSelection = cmConfigKey(kASCIIMainFSKSelection)
        setA.usesRTTYAuralMonitor = true
        setA.auralMonitor = cmConfigKey(kASCIIMainAuralMonitor)

        //  initialize txConfig before rxConfigs (a.control is still nil here)
        txConfig?.awakeFromModem?(&setA, rttyRxControl: a.control)
        ptt = txConfig?.pttObject?() ?? nil

        //  --- main receiver (a) ---
        a.isAlive = true
        a.control = LiteASCIIControl(intoView: receiverA as? NSView, client: self, index: 0)
        a.receiver = a.control?.receiver
        a.receiver?.createClickBuffer()
        a.view = a.control?.view()
        currentRxView = a.view
        a.view?.setValue(self, forKey: "delegate")          //  text selections, etc
        a.textAttribute = a.control?.textAttribute()
        a.control?.setName(NSLocalizedString("Main Receiver", comment: ""))
        a.control?.setEllipseFatness(ellipseFatness)
        configA?.awakeFromModem?(&setA, rttyRxControl: a.control, txConfig: txConfig as? RTTYTxConfig)
        configA?.setChannel?(0)
        control[0] = a.control
        configObjs[0] = configA as? WFRTTYConfig
        txLocked[0] = false

        if let ctrl = a.control {
            var tonepair = ctrl.baseTonePair()
            waterfallA?.setTonePairMarker?(&tonepair, index: 0)
        }

        //  --- lite version's dummy B channel ---
        b.isAlive = false
        b.control = RTTYRxControl(intoView: receiverB as? NSView, client: self, index: 1)
        (receiverB as? NSView)?.window?.orderOut(self)      //  v0.64c
        b.receiver = b.control?.receiver
        b.view = b.control?.view()
        b.textAttribute = b.control?.textAttribute()
        b.control?.setName("Unused Receiver")
        control[1] = b.control
        configObjs[1] = nil
        txLocked[1] = false

        (configTab as? NSTabView)?.setValue(self, forKey: "delegate")

        //  AppleScript text callback
        a.receiver?.registerModule(transceiver1?.receiver())
        a.transmitModule = transceiver1?.transmitter()
        if !isLite {
            b.receiver?.registerModule(transceiver2?.receiver())
            b.transmitModule = transceiver2?.transmitter()
        }
        (oscilloscope as? NSView)?.window?.hidesOnDeactivate = false
    }

    //  intercept setVisible call to determine if modem is chosen
    @objc(setVisibleState:)
    override func setVisibleState(_ visible: Bool) {
        super.setVisibleState(visible)
        if visible {
            if controlWindowOpen { (receiverA as? NSView)?.window?.orderFront(self) }
        } else {
            //  hide RTTY control
            (receiverA as? NSView)?.window?.orderOut(self)
        }
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        setInterface(txLockButton as? NSControl, to: #selector(txLockChanged))
        (receiverA as? NSView)?.window?.setValue(self, forKey: "delegate")
    }

    @objc(changeMarkersInSpectrum:)
    func changeMarkersInSpectrum(_ inControl: RTTYRxControl!) {
        guard let inControl = inControl else { return }
        var tonepair = inControl.rxTonePair()
        oscilloscope?.setTonePairMarker?(&tonepair)
        oscilloscope?.selectTimeConstant?(2)
    }

    @objc(drawSpectrum:)
    func drawSpectrum(_ pipe: CMPipe!) {
        if (oscilloscope as? NSView)?.window?.isVisible == true {
            oscilloscope?.addData?(pipe.stream(), isBaudot: true, timebase: 0)
        }
    }

    @objc(transmitIsLocked:)
    override func transmitIsLocked(_ index: Int32) -> Bool {
        if index == 0 {
            return (txLockButton as? NSButton)?.state == .on
        }
        return super.transmitIsLocked(index)
    }

    @objc(setTransmitLockButton:toState:)
    override func setTransmitLockButton(_ index: Int32, toState locked: Bool) {
        if index == 0 {
            (txLockButton as? NSButton)?.state = locked ? .on : .off
            return
        }
        super.setTransmitLockButton(index, toState: locked)
    }

    @objc(showControlWindow:)
    func showControlWindow(_ state: Bool) {
        if manager?.nameOfSelectedTabView() != "ASCII" { return }

        if state {
            (receiverA as? NSView)?.window?.orderFront(self)
        } else {
            (receiverA as? NSView)?.window?.orderOut(self)
        }
        controlWindowOpen = state
    }

    @objc(openControlWindow:)
    func openControlWindow(_ sender: Any!) {
        showControlWindow(true)
    }

    @objc(openSpectrumWindow:)
    func openSpectrumWindow(_ sender: Any!) {
        (oscilloscope as? NSView)?.window?.orderFront(self)
    }

    @objc(windowShouldClose:)
    override func windowShouldClose(_ sender: Any!) -> Bool {
        if (sender as AnyObject?) === (receiverA as? NSView)?.window { controlWindowOpen = false }
        return true
    }

    //  v0.64c show spectrum AppleScript
    @objc(setShowSpectrum:)
    override func setShowSpectrum(_ state: Bool) {
        if state { (oscilloscope as? NSView)?.window?.orderFront(self) }
        else { (oscilloscope as? NSView)?.window?.orderOut(self) }
    }

    //  v0.64c
    @objc override func spectrumPosition() -> NSAppleEventDescriptor! {
        let point = (oscilloscope as? NSView)?.window?.frame.origin ?? .zero
        let x = Int32(point.x + 0.5)
        let y = Int32(point.y + 0.5)

        let desc = NSAppleEventDescriptor.list()
        desc.insert(NSAppleEventDescriptor(int32: x), at: 1)
        desc.insert(NSAppleEventDescriptor(int32: y), at: 2)
        return desc
    }

    //  v0.64c
    @objc(setSpectrumPosition:)
    override func setSpectrumPosition(_ point: NSAppleEventDescriptor!) {
        if point?.numberOfItems == 2, let window = (oscilloscope as? NSView)?.window {
            var frame = window.frame
            frame.origin.x = CGFloat(point.atIndex(1)?.int32Value ?? 0)
            frame.origin.y = CGFloat(point.atIndex(2)?.int32Value ?? 0)
            window.setFrame(frame, display: true)
        }
    }

    //  v0.64c - show controls AppleScript
    @objc(setShowControls:)
    override func setShowControls(_ state: Bool) {
        showControlWindow(state)
    }

    //  v0.64c
    @objc override func controlsPosition() -> NSAppleEventDescriptor! {
        let point = (receiverA as? NSView)?.window?.frame.origin ?? .zero
        let x = Int32(point.x + 0.5)
        let y = Int32(point.y + 0.5)

        let desc = NSAppleEventDescriptor.list()
        desc.insert(NSAppleEventDescriptor(int32: x), at: 1)
        desc.insert(NSAppleEventDescriptor(int32: y), at: 2)
        return desc
    }

    //  v0.64c
    @objc(setControlsPosition:)
    override func setControlsPosition(_ point: NSAppleEventDescriptor!) {
        if point?.numberOfItems == 2, let window = (receiverA as? NSView)?.window {
            var frame = window.frame
            frame.origin.x = CGFloat(point.atIndex(1)?.int32Value ?? 0)
            frame.origin.y = CGFloat(point.atIndex(2)?.int32Value ?? 0)
            window.setFrame(frame, display: true)
        }
    }

    //  v0..65 - send ^E directly only if Lite interface
    @objc(enterTransmitMode:)
    override func enterTransmitMode(_ state: Bool) {
        if state != transmitState {
            if state == true {
                super.enterTransmitMode(state)
            } else {
                //  enter a %[rx] character into the stream
                txConfig?.transmitCharacter?(5)     //  ^E, v0.56d
                transmitLight?.setBackgroundColor?(NSColor.yellow)
            }
        }
    }
}
