//
//  CMFSKMixer.swift
//  CoreDSP
//
//  Mixes bandpass-filtered audio down to mark and space split-complex
//  baseband (4 x 512-sample sub-arrays: mark-I, mark-Q, space-I, space-Q) for
//  the matched filter, using two independent local oscillators (CMDDA) driven
//  off the shared mssin/mscos/lssin/lscos tables -- same double-angle-formula
//  technique as CMNCO.sin/cos, transcribed verbatim.
//
//  Dropped relative to the original: the RTTYAuralMonitor feed and the
//  commented-out (dead, `/* ... */`) v0.88d AGC hook -- both UI/monitoring
//  side-effects with no bearing on the decoded bit stream.
//

import Foundation

final class CMFSKMixer: CMPipe {

    //  was `float analyticSignal[2048]` -- heap buffer so the stream's array pointer stays stable
    let analyticSignal = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
    //  local oscillators
    var mark = CMDDA()
    var space = CMDDA()

    override init() {
        super.init()
        analyticSignal.initialize(repeating: 0, count: 2048)

        var tonepair = CMTonePair(mark: 2125.0, space: 2295.0, baud: 45.45)
        //  set up CMDataStream
        data.pointee.array = analyticSignal
        data.pointee.samplingRate = Float(CMFs)
        data.pointee.samples = 512
        data.pointee.components = 1
        data.pointee.channels = 1
        setTonePair(&tonepair)
    }

    deinit {
        analyticSignal.deallocate()
    }

    //  theta is scaled so a full 18-bit number (262144) represents 2.pi radians
    private func setDDA(_ dda: inout CMDDA, freq: Float) {
        dda.freq = freq
        dda.deltaTheta = 262144.0 * Double(freq) / CMFs
        dda.theta = 0.0
        dda.cost = 1.0
        dda.sint = 0.0
    }

    //  update sine and cosine to the next time sample; return the analytic pair
    private func update(_ dda: inout CMDDA) -> CMAnalyticPair {
        var th = dda.theta + dda.deltaTheta
        dda.theta = th
        if th > 262144.0 {
            th -= 262144.0
            dda.theta = th
        }
        let t = Int(th)
        let mst = (t >> 10) & 0x3ff
        let lst = t & 0x3ff

        let sina = Double(mssin[mst])
        let cosa = Double(mscos[mst])
        let sinb = Double(lssin[lst])
        let cosb = Double(lscos[lst])
        //  sin(a+b) = sin(a)cos(b) + cos(a)sin(b)
        dda.sint = sina * cosb + cosa * sinb
        //  cos(a+b) = cos(a)cos(b) - sin(a)sin(b)
        dda.cost = cosa * cosb - sina * sinb

        return CMAnalyticPair(re: Float(dda.cost), im: Float(dda.sint))
    }

    func setTonePair(_ tonepair: UnsafePointer<CMTonePair>) {
        setDDA(&mark, freq: Float(tonepair.pointee.mark))
        setDDA(&space, freq: Float(tonepair.pointee.space))
    }

    //  bandpass filtered data arrives here and is sent to the matched filter as I/Q baseband data.
    override func importData(_ pipe: CMPipe!) {
        let inStream = pipe.stream()!
        data.pointee.sourceID = inStream.pointee.sourceID
        let array = inStream.pointee.array!

        //  form split complex terms for mark and space signals
        for i in 0..<512 {
            let x = array[i]
            var mVfo = update(&mark)
            analyticSignal[i] = x * mVfo.re
            analyticSignal[i + 512] = x * mVfo.im
            mVfo = update(&space)
            analyticSignal[i + 1024] = x * mVfo.re
            analyticSignal[i + 1536] = x * mVfo.im
        }
        exportData()
    }
}
