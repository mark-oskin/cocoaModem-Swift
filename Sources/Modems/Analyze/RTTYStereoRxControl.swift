//
//  RTTYStereoRxControl.swift
//  cocoaModem
//
//  Created by Kok Chen on 2/25/05.
//  Swift port of RTTYStereoRxControl.m.
//
//  RTTYRxControl subclass for the Analyze mode.  It is instantiated by the
//  "Analyze" nib (connected to Analyze's `rxctrl` outlet), so it needs no
//  -initIntoView:; the nib sets its outlets and Analyze calls -setupWithClient:.
//  Base ivars (receiver, config, tuningView, memory, ...) are accessed by exact
//  RTTYRxControl names.
//

import Cocoa

@objc(RTTYStereoRxControl)
class RTTYStereoRxControl: RTTYRxControl {

    @objc var refChannelMenu: NSPopUpButton!
    @objc var dutChannelMenu: NSPopUpButton!

    /* local */
    func updateChannels() {
        (receiver as? RTTYStereoReceiver)?.setReference(Int32(refChannelMenu?.indexOfSelectedItem ?? 0), dut: Int32(dutChannelMenu?.indexOfSelectedItem ?? 0))
        let refPipe = (receiver as? RTTYStereoReceiver)?.refPipe_()
        //  reproduce the ObjC (CMTappedPipe*)tuningView cast: CrossedEllipse is an
        //  NSImageView that responds to the @objc importData: selector the tap uses.
        if let tv = tuningView {
            refPipe?.setTap(unsafeBitCast(tv, to: CMPipe.self))
        }
    }

    @objc(setupRTTYReceiver)
    override func setupRTTYReceiver() {
        (receiver as? RTTYStereoReceiver)?.setupReceiverChain(config?.inputSource(), config: config as? AnalyzeConfig)
        let refPipe = (receiver as? RTTYStereoReceiver)?.refPipe_()
        if let tv = tuningView {
            refPipe?.setTap(unsafeBitCast(tv, to: CMPipe.self))
        }
    }

    @objc(setupDefaultFilters)
    override func setupDefaultFilters() {
        super.setupDefaultFilters()
        memory[2].mark = 1615; memory[2].space = 1785
        memory[3].mark = 1000; memory[3].space = 830
    }

    @objc(setupWithClient:index:)
    override func setupWithClient(_ modem: Modem?, index: Int32) {
        uniqueID = index
        client = modem as? RTTY

        setupDefaultFilters()
        config = modem?.configObj(index)
        receiver = RTTYStereoReceiver(receiver: index, modem: modem)
        //  set up receiver connections
        updateChannels()
        receiver.setSquelch(squelchSlider)
        receiver.setReceiveView(exchangeView)
        receiver.setDemodulatorModeMatrix(demodulatorModeMatrix)
        receiver.setBandwidthMatrix(bandwidthMatrix)
    }

    @objc(channelMenuChanged:)
    func channelMenuChanged(_ sender: Any?) {
        updateChannels()
    }
}
