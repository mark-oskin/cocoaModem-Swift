//
//  RTTYMPFilter.swift
//  cocoaModem
//
//  Created by Kok Chen on Mon Jun 21 2004.
//  Swift port of RTTYMPFilter.m.
//
//  Matched filter for Multipath.  Pulse width set in -initBitWidth during
//  initialization (otherwise defaulted to 0.75 of a data bit by the base).
//

import Cocoa

@objc(RTTYMPFilter)
class RTTYMPFilter: RTTYMatchedFilter {

    @objc(initBitWidth:baud:)
    convenience init(bitWidth w: Float, baud baudrate: Float) {
        self.init()
        width = w
        baud = baudrate
        setDataRate(baud)
    }

    //  pulse width set in -initBitWidth during initialization (otherwise defaulted to 0.75 of a data bit)
    @objc(setDataRate:)
    override func setDataRate(_ rate: Float) {
        enabled = false
        baud = rate
        let n = Int32(CMFsMP / Double(rate) * Double(width))
        let m = dotPrKernelSize(n + 256)
        if let k = kernel { k.deallocate() }
        kernel = createMatchedFilterKernel(n, m)

        markIFilter = setupFilter(markIFilter, length: m)
        markQFilter = setupFilter(markQFilter, length: m)
        spaceIFilter = setupFilter(spaceIFilter, length: m)
        spaceQFilter = setupFilter(spaceQFilter, length: m)
        enabled = true
        mux = 0
    }
}

private let CMFsMP: Double = 11025.0    // CMFs
