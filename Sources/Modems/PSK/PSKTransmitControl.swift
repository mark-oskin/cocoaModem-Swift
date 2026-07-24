//
//  PSKTransmitControl.swift
//  cocoaModem
//
//  Created by Kok Chen on Sun Sep 12 2004.
//  Swift port of PSKTransmitControl.m.  PSKTransmitControl remains an
//  NSObject subclass; PSK, PSKReceiver and Modem stay Objective-C (their
//  headers are in the bridging header).
//

import Cocoa

@objc(PSKTransmitControl)
class PSKTransmitControl: NSObject {

    //  IBOutlet id  (transmitter controls) -- wired by the nib via KVC
    @objc var controlView: NSView!             //  transmitter controls
    @objc var vfoMenu: NSPopUpButton!

    //  base ivars used by the PSKContestTxControl subclass
    var psk: PSK!
    var receiver: PSKReceiver!
    var index: Int32 = 0

    private func setInterface(_ object: NSControl, to selector: Selector) {
        object.action = selector
        object.target = self
    }

    //  Plain designated initializer so the PSKContestTxControl subclass can
    //  call `super.init()` (mirrors the original -[super init]); it does not
    //  reuse the base's nib-loading initializer.
    override init() {
        super.init()
    }

    @objc(initIntoView:client:)
    init?(intoView view: NSView?, client modem: Modem?) {
        super.init()
        receiver = nil
        psk = modem as? PSK
        index = 0
        if Bundle.main.loadNibNamed("PSKTransmitControl", owner: self, topLevelObjects: nil) {
            // loadNib should have set up controlView connection
            if let view = view, let cv = controlView { view.addSubview(cv) }
            index = Int32(vfoMenu?.selectedItem?.tag ?? 0)
            return
        }
        return nil
    }

    override func awakeFromNib() {
        if let m = vfoMenu { setInterface(m, to: #selector(vfoMenuChanged)) }
    }

    @objc func selectedTransceiver() -> Int32 {
        let n = Int32(vfoMenu?.selectedItem?.tag ?? 0)
        if let psk = psk {
            if let p = psk.auralMonitor() {
                p.transmit(onReceiver: n)
            }
        }
        return n
    }

    //  index == 0 or 1
    @objc(selectTransceiver:)
    func selectTransceiver(_ new: Int32) {
        guard let menu = vfoMenu else { return }
        let old = Int32(menu.selectedItem?.tag ?? 0)
        if old == new { return }

        let n = menu.numberOfItems
        for i in 0..<n {
            if Int32(menu.item(at: i)?.tag ?? 0) == new {
                menu.selectItem(at: i)
                psk?.transceiverChanged()
                index = Int32(i)
                return
            }
        }
    }

    @objc func vfoMenuChanged() {
        guard let psk = psk else { return }
        let newIndex = Int32(vfoMenu?.indexOfSelectedItem ?? 0)
        if psk.transmitting() {
            if index != newIndex { vfoMenu?.selectItem(at: Int(index)) }
        } else {
            psk.transceiverChanged()
            index = newIndex
        }
    }
}
