//
//  LitePSK.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/2/07.
//  Swift port of LitePSK.m / LitePSK.h.
//
//  LitePSK : PSK.  The "Lite" single-window PSK modem.  StdManager instantiates
//  it via `LitePSK(into:manager:)` (@objc selector `initIntoTabView:manager:`),
//  loading the "LitePSK" nib.
//
//  Port note: the original -initIntoTabView:manager: called the three-arg
//  -initIntoTabView:nib:manager: super initializer directly with the "LitePSK"
//  nib (deliberately bypassing PSK's own two-arg init, so no PSK aural-monitor is
//  created for the Lite window).  That path is preserved here.
//

import Cocoa

@objc(LitePSK)
class LitePSK: PSK {

    @objc(initIntoTabView:manager:)
    override init?(into tabview: NSTabView!, manager mgr: ModemManager!) {
        mgr?.showSplash("Creating Lite PSK Modem")
        super.init(into: tabview, nib: "LitePSK", manager: mgr)
        manager = mgr
        transceivers = 2
    }
}
