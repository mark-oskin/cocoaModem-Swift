//
//  SITORRxControl.swift
//  cocoaModem
//
//  Created by Kok Chen on 2/6/06.
//  Swift port of SITORRxControl.m.
//
//  RTTYRxControl subclass for SITOR-B (100 baud).  Nib-loaded (loads the
//  "SITORRxControl" nib); the SITOR modem instantiates it with
//  -initIntoView:client:index:.  Base ivars (tonePair, memory, receiver, config,
//  ...) are accessed by their exact RTTYRxControl names.  The preferences methods
//  fully replace the base ones (they do not call super) and drive the C
//  RTTYConfigSet whose NSString* fields import as Unmanaged<NSString>.
//

import Cocoa

//  indicator states (were #defines in SITORRxControl.h)
private let kSITOROff: Int32 = 0
private let kSITOROn: Int32 = 1
private let kSITORWait: Int32 = 2
private let kSITORFEC: Int32 = 3
private let kSITORError: Int32 = 4

@objc(SITORRxControl)
class SITORRxControl: RTTYRxControl {

    @objc var lockedIndicator: NSTextField!

    var onColor: NSColor!
    var waitColor: NSColor!
    var offColor: NSColor!
    var errorColor: NSColor!
    var fecColor: NSColor!

    //  Client is DualRTTY or RTTY

    //  Usually not initialized here, but at awakeFromNib
    @objc(initIntoView:client:index:)
    override init?(intoView view: NSView?, client modem: Modem?, index: Int32) {
        super.init()
        if Bundle.main.loadNibNamed("SITORRxControl", owner: self, topLevelObjects: nil) {
            //  loadNib should have set up controlView connection
            if let view = view, let cv = controlView {
                view.addSubview(cv)
                auxWindow?.title = (index == 0) ? "Receiver A" : "Receiver B"
                setupWithClient(modem, index: index)
                activeIndicator?.backgroundColor = NSColor.gray
                return
            }
        }
        return nil
    }

    override func awakeFromNib() {
        spectrumView = nil
        waterfall = nil
        monitor = nil
        tonePair.mark = 2125
        tonePair.space = 2295
        tonePair.baud = 100.0
        sideband = 0
        rxPolarity = 0; txPolarity = 0
        activeTransmitter = false
        vfoOffset = 0; ritOffset = 0

        setInterface(bandwidthMatrix, to: #selector(bandwidthChanged))
        setInterface(demodulatorModeMatrix, to: #selector(demodulatorModeChanged))
        setInterface(squelchSlider, to: #selector(squelchChanged))

        setInterface(rxPolarityButton, to: #selector(rxPolarityChanged))
        setInterface(markFreq, to: #selector(tonePairChanged))
        setInterface(shiftField, to: #selector(shiftChanged))
        setInterface(baudRateBox, to: #selector(baudRateChanged))

        setInterface(memorySelectMenu, to: #selector(tonePairSelected))
        setInterface(inputAttenuator, to: #selector(inputAttenuatorChanged))

        onColor = NSColor.green
        waitColor = NSColor.yellow
        fecColor = NSColor.orange
        errorColor = NSColor.red
        offColor = NSColor.gray

        setIndicator(kSITOROff)
    }

    @objc(setIndicator:)
    func setIndicator(_ state: Int32) {
        let color: NSColor
        switch state {
        case kSITORWait:
            color = waitColor
        case kSITOROn:
            color = onColor
        case kSITORFEC:
            color = fecColor
        case kSITORError:
            color = errorColor
        default:    //  kSITOROff
            color = offColor
        }
        lockedIndicator?.backgroundColor = color
    }

    //  set up to use SITOR Receiver
    @objc(setupWithClient:index:)
    override func setupWithClient(_ modem: Modem?, index: Int32) {
        uniqueID = index
        client = modem as? RTTY
        setupDefaultFilters()

        receiver = SITORReceiver(receiver: index, modem: modem)
        //  set up receiver connections
        monitor = RTTYMonitor()
        monitor.setTitle("SITOR Monitor")

        (receiver as? SITORReceiver)?.setControl(self)
        receiver.setSquelch(squelchSlider)
        receiver.setReceiveView(exchangeView)
        receiver.setDemodulatorModeMatrix(demodulatorModeMatrix)
        receiver.setBandwidthMatrix(bandwidthMatrix)
    }

    @objc(setupDefaultFilters)
    override func setupDefaultFilters() {
        tonePair = CMTonePair(mark: 2125.0, space: 2295.0, baud: 45.45)

        memory[0].mark = 2125; memory[0].space = 2295; memory[0].baud = 100.0
        memory[1].mark = 2110; memory[1].space = 2310; memory[1].baud = 100.0
        memory[2].mark = 1300; memory[2].space = 1470; memory[2].baud = 100.0
        memory[3].mark = 1615; memory[3].space = 1785; memory[3].baud = 100.0
        selectedTone = 0

        setTuningIndicatorState(true)
        //  receive views
        receiveTextAttribute = exchangeView?.newAttribute()
        exchangeView?.delegate = client as? NSTextViewDelegate
    }

    //  ---- preferences ----
    //  preferences maintainence, called from RTTYConfig.m
    //  setup default preferences (keys are found in Plist.h)

    //  local
    private func toneString(_ f: [Int32]) -> String {
        return String(format: "%d,%d,%d,%d", f[0], f[1], f[2], f[3])
    }

    //  local
    private func baudString(_ f: [Float]) -> String {
        return String(format: "%.2f,%.2f,%.2f,%.2f", f[0], f[1], f[2], f[3])
    }

    //  local
    private func decodeToneString(_ str: String, into p: inout [Int32]) {
        let parts = str.components(separatedBy: ",")
        for i in 0..<min(4, parts.count) {
            p[i] = Int32(parts[i].trimmingCharacters(in: .whitespaces)) ?? p[i]
        }
    }

    //  local
    private func decodeBaudString(_ str: String, into p: inout [Float]) {
        let parts = str.components(separatedBy: ",")
        for i in 0..<min(4, parts.count) {
            p[i] = Float(parts[i].trimmingCharacters(in: .whitespaces)) ?? p[i]
        }
    }

    //  NSString keys stored inside the C RTTYConfigSet struct import as Unmanaged.
    private func cfgKey(_ u: Unmanaged<NSString>?) -> String {
        return (u?.takeUnretainedValue() as String?) ?? ""
    }

    @objc(setupDefaultPreferences:config:)
    override func setupDefaultPreferences(_ pref: Preferences!, config cfg: ModemConfig!) {
        var f = [Float](repeating: 0, count: 4)
        var g = [Int32](repeating: 0, count: 4)

        config = cfg
        guard let rtcfg = config as? RTTYConfig else { return }
        let set = rtcfg.configSetPointer()

        //  get sidebandMenu interface from RTTYConfig
        sidebandMenu = rtcfg.sidebandMenu
        setInterface(sidebandMenu, to: #selector(tonePairChanged))

        pref.setInt(selectedTone, forKey: cfgKey(set.pointee.tone))      // tone memory
        pref.setInt(0, forKey: cfgKey(set.pointee.sideband))
        pref.setInt(0, forKey: cfgKey(set.pointee.rxPolarity))

        for i in 0..<4 { g[i] = Int32(memory[i].mark) }
        pref.setString(toneString(g), forKey: cfgKey(set.pointee.mark))

        for i in 0..<4 { g[i] = Int32(memory[i].space) }
        pref.setString(toneString(g), forKey: cfgKey(set.pointee.space))

        for i in 0..<4 { f[i] = Float(memory[i].baud) }
        pref.setString(baudString(f), forKey: cfgKey(set.pointee.baud))

        pref.setFloat(0.6, forKey: cfgKey(set.pointee.squelch))

        if auxWindow != nil && set.pointee.controlWindow != nil {
            if uniqueID != 0 {
                //  offset sub control a little
                var frame = auxWindow.frame
                frame.origin.y += 20
                frame.origin.x += 20
                auxWindow.setFrame(frame, display: false)
            }
            pref.setString(auxWindow.frameDescriptor, forKey: cfgKey(set.pointee.controlWindow))
        }
    }

    @objc(updateFromPlist:config:)
    override func updateFromPlist(_ pref: Preferences!, config cfg: ModemConfig!) {
        var f = [Float](repeating: 0, count: 4)
        var g = [Int32](repeating: 0, count: 4)

        config = cfg
        guard let rtcfg = config as? RTTYConfig else { return }
        let set = rtcfg.configSetPointer()

        if auxWindow != nil && set.pointee.controlWindow != nil {
            auxWindow.setFrame(from: pref.stringValue(forKey: cfgKey(set.pointee.controlWindow)))
        }

        decodeToneString(pref.stringValue(forKey: cfgKey(set.pointee.mark)), into: &g)
        for i in 0..<4 { memory[i].mark = Double(g[i]) }

        decodeToneString(pref.stringValue(forKey: cfgKey(set.pointee.space)), into: &g)
        for i in 0..<4 { memory[i].space = Double(g[i]) }

        decodeBaudString(pref.stringValue(forKey: cfgKey(set.pointee.baud)), into: &f)
        for i in 0..<4 { memory[i].baud = Double(f[i]) }

        if receiver != nil { receiver.setSquelchValue(pref.floatValue(forKey: cfgKey(set.pointee.squelch))) }

        selectedTone = pref.intValue(forKey: cfgKey(set.pointee.tone))
        if selectedTone > 3 { selectedTone = 0 }
        memorySelectMenu?.selectItem(at: Int(selectedTone))

        //  menus for tone pair polarities
        sidebandMenu?.selectItem(at: Int(pref.intValue(forKey: cfgKey(set.pointee.sideband))))
        rxPolarityButton?.state = (pref.intValue(forKey: cfgKey(set.pointee.rxPolarity)) == 0) ? .off : .on
        //  tone pair table selection
        markFreq?.intValue = Int32(memory[Int(selectedTone)].mark)
        shiftField?.intValue = Int32(fabs(memory[Int(selectedTone)].space - memory[Int(selectedTone)].mark + 0.1))
        setBaudRateField(Float(memory[Int(selectedTone)].baud))
        //  now set internal variables
        fetchTonePairFromMemory()
        updateTonePairInformation()
    }

    @objc(retrieveForPlist:config:)
    override func retrieveForPlist(_ pref: Preferences!, config cfg: ModemConfig!) {
        var f = [Float](repeating: 0, count: 4)
        var g = [Int32](repeating: 0, count: 4)

        config = cfg
        guard let rtcfg = config as? RTTYConfig else { return }
        let set = rtcfg.configSetPointer()

        if auxWindow != nil && set.pointee.controlWindow != nil {
            pref.setString(auxWindow.frameDescriptor, forKey: cfgKey(set.pointee.controlWindow))
        }
        for i in 0..<4 { g[i] = Int32(memory[i].mark) }
        pref.setString(toneString(g), forKey: cfgKey(set.pointee.mark))

        for i in 0..<4 { g[i] = Int32(memory[i].space) }
        pref.setString(toneString(g), forKey: cfgKey(set.pointee.space))

        for i in 0..<4 { f[i] = Float(memory[i].baud) }
        pref.setString(baudString(f), forKey: cfgKey(set.pointee.baud))

        pref.setInt(selectedTone, forKey: cfgKey(set.pointee.tone))      // tone memory
        pref.setInt(sideband, forKey: cfgKey(set.pointee.sideband))
        pref.setInt(rxPolarity, forKey: cfgKey(set.pointee.rxPolarity))

        if receiver != nil { pref.setFloat(receiver.squelchValue(), forKey: cfgKey(set.pointee.squelch)) }
    }
}
