//
//  CWMixer.swift
//  CoreDSP
//
//  Swift port of the old app's CWMixer.swift: mixes real audio to complex
//  baseband via a local oscillator at the mark (tone) frequency.
//
//  PORT FINDING: the original mixed a raw sample through a hand-rolled DDA
//  (CMDDA, reading the mssin/mscos/lssin/lscos tables directly) and *also*
//  lowpass-filtered the result through a CW-bandwidth-selected FIR bank
//  (iFilter256/512/768/1024, -setCWBandwidth:) into iIF/qIF. But that filtered
//  output was only ever handed to the aural "listen-through" monitor
//  (`if isAural { receiver.received(iIF, quadrature: qIF, ...) ; return }`).
//  The actual decode chain reads `mixerStream.pointee.array`, which stayed
//  bound to the *unfiltered* mixed `analyticSignal` for the entire lifetime of
//  the mixer (-exportData() is called after the filters run, but
//  mixerStream.array is never reassigned to iIF/qIF) -- so that lowpass bank
//  was dead code for decoding even in the original. Since this port drops the
//  aural monitor (a loudspeaker feature, out of scope for a headless DSP
//  core), the lowpass bank has no remaining reader and is not transplanted;
//  CWPipeline's own AGC/decimate filters do the actual band-limiting for
//  decode, exactly as they did in the original.
//
//  CMPCO (already in CoreDSP, default output scale 1.0) computes bit-identical
//  sin/cos pairs from the same mssin/mscos/lssin/lscos tables the original's
//  CMDDA read directly, so it is reused here instead of re-deriving CMDDA.
//

import Foundation

final class CWMixer {

    private let mark = CMPCO()

    init() {
        mark.setCarrier(1500.0)
    }

    func setMarkFrequency(_ freq: Float) {
        mark.setCarrier(freq)
    }

    /// Mix one 512-sample real block to baseband; `iOut`/`qOut` each receive 512 samples.
    func importBlock(_ input: UnsafePointer<Float>, iOut: UnsafeMutablePointer<Float>, qOut: UnsafeMutablePointer<Float>) {
        for i in 0..<512 {
            let x = input[i]
            let mVfo = mark.nextVCOPair()
            iOut[i] = x * mVfo.re
            qOut[i] = x * mVfo.im
        }
    }
}
