//
//  MFSK16Modulator.swift
//  CoreDSP
//
//  Swift port of MFSK16Modulator.m.  MFSK16 uses the full 10-stage
//  interleaver; everything else is inherited from MFSKModulator.
//

import Foundation

final class MFSK16Modulator: MFSKModulator {

    override func setInterleaverStages(_ stages: Int32) {
        interleaverStages = 10
    }
}
