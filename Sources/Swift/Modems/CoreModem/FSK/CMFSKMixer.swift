//
//  CMFSKMixer.swift
//  CoreModem
//
//  Created by Kok Chen on 10/25/05
//	(ported from cocoaModem, original file dated Wed Jun 09 2004)
//  Swift port of CMFSKMixer.{h,m}.  Mixes bandpass-filtered audio down to mark
//  and space split-complex baseband for the matched filter.
//

import Foundation

@objc(CMFSKMixer)
class CMFSKMixer: CMPipe {

    //  was `float analyticSignal[2048]` -- heap buffer so mixerStream.array stays stable
    internal let analyticSignal: UnsafeMutablePointer<Float>
    //  local oscillators
    internal var mark = CMDDA()
    internal var space = CMDDA()
    //  was `CMDataStream mixerStream` -- heap so `data` keeps a stable address
    internal let mixerStream: UnsafeMutablePointer<CMDataStream>
    internal var demodulator: CMFSKDemodulator?
    internal var auralMonitor: RTTYAuralMonitor?
    internal var config: ModemConfig?                       //  v0.88d

    override init() {
        analyticSignal = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
        analyticSignal.initialize(repeating: 0, count: 2048)
        mixerStream = UnsafeMutablePointer<CMDataStream>.allocate(capacity: 1)
        mixerStream.initialize(to: CMDataStream())
        super.init()

        var tonepair = CMTonePair(mark: 2125.0, space: 2295.0, baud: 45.45)
        demodulator = nil
        auralMonitor = nil
        //  set up CMDataStream
        data = mixerStream
        mixerStream.pointee.array = analyticSignal
        mixerStream.pointee.samplingRate = Float(CMFs)
        mixerStream.pointee.samples = 512
        mixerStream.pointee.components = 1
        mixerStream.pointee.channels = 1
        setTonePair(&tonepair)
    }

    deinit {
        analyticSignal.deallocate()
        mixerStream.deallocate()
    }

    //  theta is scaled so a full 18-bit number (262144) represents 2.pi radians
    func setDDA(_ dda: inout CMDDA, freq: Float) {
        dda.freq = freq
        dda.deltaTheta = 262144.0 * Double(freq) / CMFs
        dda.theta = 0.0
        dda.cost = 1.0
        dda.sint = 0.0
    }

    //  update sine and cosine to the next time sample; return the analytic pair
    private func update(_ dda: inout CMDDA) -> CMAnalyticPair {
        var th = (dda.theta + dda.deltaTheta)
        dda.theta = th
        if th > 262144.0 {
            th -= 262144.0
            dda.theta = th
        }
        let t = Int(th)
        let mst = (t >> 10)
        let lst = t & 0x3ff

        //  v0.76 performance tune
        let sina = Double(mssin[mst])
        let cosa = Double(mscos[mst])
        let sinb = Double(lssin[lst])
        let cosb = Double(lscos[lst])
        //  sin(a+b) = sin(a)cos(b) + cos(a)sin(b)
        dda.sint = sina * cosb + cosa * sinb
        //  cos(a+b) = cos(a)cos(b) - sin(a)sin(b)
        dda.cost = cosa * cosb - sina * sinb

        var p = CMAnalyticPair()
        p.re = Float(dda.cost)
        p.im = Float(dda.sint)
        return p
    }

    @objc(setTonePair:)
    func setTonePair(_ tonepair: UnsafePointer<CMTonePair>!) {
        setDDA(&mark, freq: Float(tonepair.pointee.mark))
        setDDA(&space, freq: Float(tonepair.pointee.space))
    }

    @objc(setDemodulator:)
    func setDemodulator(_ client: CMFSKDemodulator?) {
        demodulator = client
    }

    //  v0.88d
    @objc(setConfig:)
    func setConfig(_ cfg: ModemConfig?) {
        config = cfg
    }

    @objc(setAuralMonitor:)
    func setAuralMonitor(_ mon: RTTYAuralMonitor?) {
        auralMonitor = mon
    }

    //  bandpass filtered data arrives here and is sent to the matched filter as I/Q baseband data.
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        let inStream = pipe.stream()!
        mixerStream.pointee.sourceID = inStream.pointee.sourceID
        let array = inStream.pointee.array!

        var mag: Float = 0
        //  form split complex terms for mark and space signals
        for i in 0..<512 {
            var x = array[i]
            var mVfo = update(&mark)
            analyticSignal[i] = x * mVfo.re
            analyticSignal[i + 512] = x * mVfo.im
            mVfo = update(&space)
            analyticSignal[i + 1024] = x * mVfo.re
            analyticSignal[i + 1536] = x * mVfo.im

            // v0.88d AGC test
            x = abs(x)
            if x > mag { mag = x }
        }
        exportData()

        /*
        // v0.88d AGC -- "good place" is between 0.5 (with 6 dB headroom) and 0.35 (dynamic range of soundcard minus 9 dB)
        if ( mag > 0.5 || mag < 0.35 ) {
            [ config processAGC:mag ] ;
        }
        */
        _ = mag
    }
}
