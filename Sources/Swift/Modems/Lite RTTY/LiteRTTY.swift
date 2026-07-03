//
//  LiteRTTY.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/2/07.
//  Swift port of LiteRTTY.m / LiteRTTY.h.
//
//  LiteRTTY : WFRTTY.  The single-receiver "Lite" RTTY window (its `b` channel is
//  a dummy).  StdManager instantiates it via `LiteRTTY(into:manager:)`
//  (@objc selector `initIntoTabView:manager:`), loading the "LiteRTTY" nib, and
//  immediately calls -showControlWindow:.
//
//  Port notes:
//   * Like the other WFRTTY subclasses, the original two-arg
//     -initIntoTabView:manager: forwarding to a three-arg
//     -initIntoTabView:manager:nib: workhorse is collapsed into the single
//     designated `init?(into:manager:)`, which reaches the plain base nib loader
//     via `super.init(into:nib:manager:)` (NOT WFRTTY's own receiver setup) and
//     then builds its own LiteRTTYControl receiver.
//   * `isLite` (owned by WFRTTY) is set true right after super.init.
//   * All original ivars keep their exact names; `id` outlets are @objc AnyObject!,
//     reached via optional-chaining message sends (NIL-TOLERANCE).
//

import Cocoa

//  ModemSource.h
private let LEFTCHANNEL: Int32 = 0

//  --- Plist keys (Plist.h) ---
private let kWFRTTYMainDevice: NSString          = "WFRTTY Input Device A"
private let kWFRTTYOutputDevice: NSString        = "WFRTTY Output Device"
private let kWFRTTYOutputLevel: NSString         = "WFRTTY Output Sound Level"
private let kWFRTTYOutputAttenuator: NSString    = "WFRTTY Output Attenuator"
private let kWFRTTYMainTone: NSString            = "WFRTTY Main Tone Select"
private let kWFRTTYMainMark: NSString            = "WFRTTY Main Mark Frequencies"
private let kWFRTTYMainSpace: NSString           = "WFRTTY Main Space Frequencies"
private let kWFRTTYMainBaud: NSString            = "WFRTTY Main Baud Rate"
private let kWFRTTYMainControlWindow: NSString   = "WFRTTY Control Window A"
private let kWFRTTYMainSquelch: NSString         = "WFRTTY Squelch A"
private let kWFRTTYMainActive: NSString          = "WFRTTY Active A"
private let kWFRTTYMainStopBits: NSString        = "WFRTTY Stop Bits A"
private let kWFRTTYMainMode: NSString            = "WFRTTY Mode A"
private let kWFRTTYMainRxPolarity: NSString      = "WFRTTY Main Rx Polarity"
private let kWFRTTYMainTxPolarity: NSString      = "WFRTTY Main Tx Polarity"
private let kWFRTTYMainPrefs: NSString           = "WFRTTY Prefs A"
private let kWFRTTYMainTextColor: NSString       = "WFRTTY Text Color 1"
private let kWFRTTYMainSentColor: NSString       = "WFRTTY Sent Color 1"
private let kWFRTTYMainBackgroundColor: NSString = "WFRTTY Background Color 1"
private let kWFRTTYMainPlotColor: NSString       = "WFRTTY Plot Color 1"
private let kWFRTTYMainOffset: NSString          = "WFRTTY Offset A"
private let kWFRTTYMainFSKSelection: NSString    = "WFRTTY FSK Selection A"
private let kWFRTTYMainAuralMonitor: NSString    = "WFRTTY Aural Monitor A"

@objc(LiteRTTY)
class LiteRTTY: WFRTTY {

    //  --- IBOutlets (id) ---
    @objc var txLockButton: AnyObject!
    @objc var oscilloscope: AnyObject!
    internal var controlWindowOpen: Bool = false

    //  =======================================================================
    //  Initialization
    //  =======================================================================

    @objc(initIntoTabView:manager:)
    override init?(into tabview: NSTabView!, manager mgr: ModemManager!) {
        mgr?.showSplash("Creating Lite RTTY Modem")
        super.init(into: tabview, nib: "LiteRTTY", manager: mgr)
        isLite = true
        manager = mgr
        controlWindowOpen = false       //  initially hide control window; reset after Prefs is checked

        let ellipseFatness: Float = 0.9

        let setA = makeWFRTTYConfigSet(channel: LEFTCHANNEL,
            [ kWFRTTYMainDevice, kWFRTTYOutputDevice, kWFRTTYOutputLevel, kWFRTTYOutputAttenuator,
              kWFRTTYMainTone, kWFRTTYMainMark, kWFRTTYMainSpace, kWFRTTYMainBaud, kWFRTTYMainControlWindow,
              kWFRTTYMainSquelch, kWFRTTYMainActive, kWFRTTYMainStopBits, kWFRTTYMainMode, kWFRTTYMainRxPolarity,
              kWFRTTYMainTxPolarity, kWFRTTYMainPrefs, kWFRTTYMainTextColor, kWFRTTYMainSentColor,
              kWFRTTYMainBackgroundColor, kWFRTTYMainPlotColor, kWFRTTYMainOffset, kWFRTTYMainFSKSelection ],
            usesRTTYAuralMonitor: true, auralMonitor: kWFRTTYMainAuralMonitor)

        //  initialize txConfig before rxConfigs
        (txConfig as AnyObject?)?.awakeFromModem?(setA, rttyRxControl: a.control)
        ptt = (txConfig as? RTTYTxConfig)?.pttObject()

        a.isAlive = true
        a.control = LiteRTTYControl(intoView: receiverA as? NSView, client: self, index: 0)
        a.receiver = a.control?.receiver_()
        a.receiver?.createClickBuffer()
        a.view = a.control?.view()
        currentRxView = a.view
        a.view?.setValue(self, forKey: "delegate")          //  text selections, etc
        a.textAttribute = a.control?.textAttribute()
        a.control?.setName(NSLocalizedString("Main Receiver", comment: ""))
        a.control?.setEllipseFatness(ellipseFatness)
        (configA as AnyObject?)?.awakeFromModem?(setA, rttyRxControl: a.control, txConfig: txConfig as? RTTYTxConfig)
        (configA as AnyObject?)?.setChannel?(0)
        control[0] = a.control
        configObjs[0] = configA
        txLocked[0] = false

        if let ctrl = a.control {
            var tonepair = ctrl.baseTonePair()
            (waterfallA as AnyObject?)?.setTonePairMarker?(&tonepair, index: 0)
        }

        //  lite version's dummy B channel
        b.isAlive = false
        b.control = RTTYRxControl(intoView: receiverB as? NSView, client: self, index: 1)
        (receiverB as? NSView)?.window?.orderOut(self)      //  v0.64c
        b.receiver = b.control?.receiver_()
        b.view = b.control?.view()
        b.textAttribute = b.control?.textAttribute()
        b.control?.setName("Unused Receiver")
        control[1] = b.control
        configObjs[1] = nil
        txLocked[1] = false

        (configTab as AnyObject?)?.setValue(self, forKey: "delegate")

        //  AppleScript text callback
        a.receiver?.registerModule(transceiver1?.receiver())
        a.transmitModule = transceiver1?.transmitter()
        if !isLite {
            b.receiver?.registerModule(transceiver2?.receiver())
            b.transmitModule = transceiver2?.transmitter()
        }
        (oscilloscope as? NSView)?.window?.hidesOnDeactivate = false

        setA.deallocate()
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
        //  Wire the window delegate via KVC: LiteRTTY implements the @objc
        //  windowShouldClose: (overriding the base) but does not formally declare
        //  NSWindowDelegate — declaring it would clash with the base's Any!-typed
        //  override.  The delegate callbacks dispatch by selector at runtime.
        (receiverA as? NSView)?.window?.setValue(self, forKey: "delegate")
    }

    @objc(changeMarkersInSpectrum:)
    func changeMarkersInSpectrum(_ inControl: RTTYRxControl!) {
        var tonepair = inControl?.rxTonePair() ?? CMTonePair()
        (oscilloscope as AnyObject?)?.setTonePairMarker?(&tonepair)
        (oscilloscope as AnyObject?)?.selectTimeConstant?(2)
    }

    @objc(drawSpectrum:)
    func drawSpectrum(_ pipe: CMPipe!) {
        if (oscilloscope as? NSView)?.window?.isVisible == true {
            (oscilloscope as AnyObject?)?.addData?(pipe.stream(), isBaudot: true, timebase: 0)
        }
    }

    @objc(transmitIsLocked:)
    override func transmitIsLocked(_ index: Int32) -> Bool {
        if index == 0 {
            return ((txLockButton as? NSButton)?.state == .on)
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
        if ((manager as AnyObject?)?.nameOfSelectedTabView?() as String?) != "RTTY" { return }   //  v0.64c

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
        if (sender as AnyObject?) === ((receiverA as? NSView)?.window) { controlWindowOpen = false }
        return true
    }

    //  v0.64c show spectrum AppleScript
    @objc(setShowSpectrum:)
    override func setShowSpectrum(_ state: Bool) {
        if state { (oscilloscope as? NSView)?.window?.orderFront(self) } else { (oscilloscope as? NSView)?.window?.orderOut(self) }
    }

    //  v0.64c
    @objc(spectrumPosition)
    override func spectrumPosition() -> NSAppleEventDescriptor {
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
        if point?.numberOfItems == 2, let win = (oscilloscope as? NSView)?.window {
            var frame = win.frame
            frame.origin.x = CGFloat(point.atIndex(1)?.int32Value ?? 0)
            frame.origin.y = CGFloat(point.atIndex(2)?.int32Value ?? 0)
            win.setFrame(frame, display: true)
        }
    }

    //  v0.64c - show controls AppleScript
    @objc(setShowControls:)
    override func setShowControls(_ state: Bool) {
        showControlWindow(state)
    }

    //  v0.64c
    @objc(controlsPosition)
    override func controlsPosition() -> NSAppleEventDescriptor {
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
        if point?.numberOfItems == 2, let win = (receiverA as? NSView)?.window {
            var frame = win.frame
            frame.origin.x = CGFloat(point.atIndex(1)?.int32Value ?? 0)
            frame.origin.y = CGFloat(point.atIndex(2)?.int32Value ?? 0)
            win.setFrame(frame, display: true)
        }
    }

    //  v0.65 - send ^E directly only if Lite interface
    @objc(enterTransmitMode:)
    override func enterTransmitMode(_ state: Bool) {
        if state != transmitState {
            if state {
                super.enterTransmitMode(state)
            } else {
                //  enter a %[rx] character into the stream
                (txConfig as? RTTYTxConfig)?.transmitCharacter(5)   //  ^E  v0.56d
                (transmitLight as AnyObject?)?.setBackgroundColor?(NSColor.yellow)
            }
        }
    }
}
