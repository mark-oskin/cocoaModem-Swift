//
//  PSKControl.swift
//  cocoaModem
//
//  Created by Kok Chen on Sun Sep 12 2004.
//  Swift port of PSKControl.m.
//

import Cocoa

@objc(PSKControl)
class PSKControl: NSObject {

    //  kBPSK31, etc, from CMPSKModes.h (mirrored here as the header is not
    //  visible to Swift).
    private static let kBPSK31: Int32 = 0
    private static let kBPSK63: Int32 = 1
    private static let kQPSK31: Int32 = 2
    private static let kQPSK63: Int32 = 3
    //  kBPSK31, etc, psk125 has the 0x8 bit turned on
    private static let pskIndexMap: [Int32] = [0, 1, 0x8 | 1, 2, 3, 0x8 | 3]

    //  IBOutlet id  (receiver controls)
    @objc var controlView: NSView!
    @objc var title: NSTextField!
    @objc var modeMenu: NSPopUpButton!
    @objc var afcCheckbox: NSButton!
    @objc var squelchControl: NSControl!

    private var psk: PSK!
    private var receiver: PSKReceiver!
    private var index: Int32 = 0
    private var afcCheckboxState: Bool = false
    private var squelchControlValue: Float = 0
    private var pskModeValue: Int32 = 0

    private func setInterface(_ object: NSControl, to selector: Selector) {
        object.action = selector
        object.target = self
    }

    @objc(initIntoView:client:index:)
    init?(intoView view: NSView?, client modem: Modem?, index inIndex: Int32) {
        super.init()
        receiver = nil
        afcCheckboxState = false
        squelchControlValue = 2.0
        psk = modem as? PSK
        index = inIndex
        pskModeValue = PSKControl.kBPSK31
        if Bundle.main.loadNibNamed("PSKControl", owner: self, topLevelObjects: nil) {
            // loadNib should have set up controlView connection
            if let view = view, let cv = controlView { view.addSubview(cv) }
            title?.stringValue = String(format: "Xcvr %d", index + 1)

            if let m = modeMenu { setInterface(m, to: #selector(modeMenuChanged)) }
            if let s = squelchControl { setInterface(s, to: #selector(squelchChanged)) }
            if let a = afcCheckbox { setInterface(a, to: #selector(afcCheckboxChanged)) }
            return
        }
        return nil
    }

    @objc(setPSKReceiver:)
    func setPSKReceiver(_ rx: PSKReceiver?) {
        receiver = rx
    }

    @objc(setAFCState:)
    func setAFCState(_ state: DarwinBoolean) {
        afcCheckboxState = state.boolValue
        afcCheckbox?.state = state.boolValue ? .on : .off
    }

    @objc func afcEnabled() -> DarwinBoolean {
        return DarwinBoolean(afcCheckboxState)
    }

    @objc func squelchValue() -> Float {
        return squelchControlValue
    }

    @objc(setSquelchValue:)
    func setSquelchValue(_ value: Float) {
        squelchControl?.floatValue = value
        squelchControlValue = value
    }

    @objc func squelchChanged() {
        squelchControlValue = squelchControl?.floatValue ?? 0
    }

    //  change mode to @"BPSK31", etc
    @objc(changeModeToString:)
    func changeModeToString(_ mode: String) {
        guard let menu = modeMenu else { return }
        let n = menu.numberOfItems
        for i in 0..<n {
            if mode == menu.itemTitle(at: i) {
                menu.selectItem(at: i)
                changeModeToIndex(Int32(i))
            }
        }
    }

    //  kBPSK31, etc, psk125 has the 0x8 bit turned on
    @objc func pskMode() -> Int32 {
        guard let menu = modeMenu else { return pskModeValue }

        //  v0.88  sanity check
        var n = menu.indexOfSelectedItem
        if n < 0 {
            n = 0
            menu.selectItem(at: 0)
            receiver?.setPSKMode(PSKControl.pskIndexMap[0])
        }
        pskModeValue = PSKControl.pskIndexMap[n]
        return pskModeValue
    }

    //  v0.64f  added psk125
    //  change mode to index in the mode menu (0 = BPSK31, etc)
    @objc(changeModeToIndex:)
    func changeModeToIndex(_ n: Int32) {
        //  PSK125 masquerades as PSK63, with the 0x8 flag turned on
        //  0,1,2 => 0,1,1
        //  3,4,5 => 2,3,3
        var idx = n
        if idx > 5 { idx = 0 }              //  sanity check

        pskModeValue = PSKControl.pskIndexMap[Int(idx)]
        receiver?.setPSKMode(pskModeValue)
    }

    @objc func afcCheckboxChanged() {
        afcCheckboxState = (afcCheckbox?.state == .on)
    }

    @objc func modeMenuChanged() {
        if psk.transmitting() {
            //  don't allow mode switching while transmitting!  Stay with current setting
            //  v0.64f -- added psk125 menu
            var indx: Int
            switch pskModeValue & 0x3 {
            case PSKControl.kBPSK63:
                indx = 1
            case PSKControl.kQPSK31:
                indx = 3
            case PSKControl.kQPSK63:
                indx = 5
            default:                        //  kBPSK31
                indx = 0
            }
            if (pskModeValue & 0x8) != 0 { indx += 1 }
            modeMenu?.selectItem(at: indx)
            return
        }
        changeModeToIndex(Int32(modeMenu?.indexOfSelectedItem ?? 0))
    }

    @objc(setTxFrequency:)
    func setTxFrequency(_ sender: Any?) {
        if let receiver = receiver { receiver.setTransmitFrequencyToReceiveFrequency() }
    }
}
