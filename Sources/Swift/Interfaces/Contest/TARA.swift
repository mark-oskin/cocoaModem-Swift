//
//  TARA.swift
//  cocoaModem
//
//  Created by Kok Chen on 12/4/04.
//
//  Swift port of TARA.m.  TARA RTTY contest (uses the RTTY Roundup engine).
//

import Cocoa

@objc(TARA)
class TARA: RTTYRoundup {

    override func setupFields() {
        super.setupFields()
        if master != nil { master?.setCabrilloContestName("TARA-RTTY") }
    }
}
