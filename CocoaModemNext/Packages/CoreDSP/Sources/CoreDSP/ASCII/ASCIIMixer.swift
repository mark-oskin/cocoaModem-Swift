//
//  ASCIIMixer.swift
//  CoreDSP
//
//  Downconverts bandpass-filtered 11025 Hz audio to baseband mark/space
//  analytic (I/Q) pairs for the matched filter.  Faithful transplant of
//  CMFSKMixer's downconversion algorithm
//  (Sources/Swift/Modems/CoreModem/FSK/CMFSKMixer.swift), stripped of the
//  RTTYAuralMonitor / ModemConfig AGC hooks that don't apply to a headless
//  DSP core (those were UI/monitor-only side channels, not decode-critical).
//

import Foundation

final class ASCIIMixer: CMPipe {

    //  "split complex" baseband mark/space signal: [markRe(512) markIm(512) spaceRe(512) spaceIm(512)]
    private let analyticSignal = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
    private var mark = ASCIIDDA()
    private var space = ASCIIDDA()
    private let mixerStream: UnsafeMutablePointer<CMDataStream> = {
        let p = UnsafeMutablePointer<CMDataStream>.allocate(capacity: 1)
        p.initialize(to: CMDataStream())
        return p
    }()

    override init() {
        super.init()
        analyticSignal.initialize(repeating: 0, count: 2048)
        data = mixerStream
        mixerStream.pointee.array = analyticSignal
        mixerStream.pointee.samplingRate = Float(kCMFs)
        mixerStream.pointee.samples = 512
        mixerStream.pointee.components = 1
        mixerStream.pointee.channels = 1
        setTonePair(mark: 2125.0, space: 2295.0)
    }

    deinit {
        analyticSignal.deallocate()
        mixerStream.deallocate()
    }

    private func setDDA(_ dda: inout ASCIIDDA, freq: Float) {
        dda.freq = freq
        dda.deltaTheta = kPeriod * Double(freq) / kCMFs
        dda.theta = 0
        dda.cost = 1
        dda.sint = 0
    }

    func setTonePair(mark markHz: Double, space spaceHz: Double) {
        setDDA(&mark, freq: Float(markHz))
        setDDA(&space, freq: Float(spaceHz))
    }

    //  update sine/cosine to the next time sample using the same shifted/masked
    //  double-angle table trick as CMNCO.sin/cos, operating on the shared
    //  mssin/lssin/mscos/lscos tables (CoreModem.swift).
    private func update(_ dda: inout ASCIIDDA) -> CMAnalyticPair {
        var th = dda.theta + dda.deltaTheta
        if th > kPeriod { th -= kPeriod }
        dda.theta = th
        let t = Int(th)
        let mst = t >> 10
        let lst = t & 0x3ff
        let sina = Double(mssin[mst]); let cosa = Double(mscos[mst])
        let sinb = Double(lssin[lst]); let cosb = Double(lscos[lst])
        //  sin(a+b) = sin(a)cos(b) + cos(a)sin(b)
        dda.sint = sina * cosb + cosa * sinb
        //  cos(a+b) = cos(a)cos(b) - sin(a)sin(b)
        dda.cost = cosa * cosb - sina * sinb
        return CMAnalyticPair(re: Float(dda.cost), im: Float(dda.sint))
    }

    //  bandpass-filtered data arrives here and is sent to the matched filter
    //  as I/Q baseband data.
    override func importData(_ pipe: CMPipe!) {
        guard let inStream = pipe.stream(), let array = inStream.pointee.array else { return }
        mixerStream.pointee.sourceID = inStream.pointee.sourceID

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
