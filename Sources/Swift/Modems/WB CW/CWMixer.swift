//
//  CWMixer.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/3/06.
//  Swift port of CWMixer.{h,m}.  Mixes audio to complex baseband, lowpass
//  filters I/Q, and either feeds the aural receiver or the demodulator chain.
//

import Foundation

@objc(CWMixer)
class CWMixer: CMPipe {

    internal let analyticSignal: UnsafeMutablePointer<Float>   // was float[1024], split complex, 512 samples
    //  local oscillators
    internal var mark = CMDDA()
    internal var space = CMDDA()
    internal let mixerStream: UnsafeMutablePointer<CMDataStream>  // was CMDataStream (heap for stable address)
    internal var iFilter: UnsafeMutablePointer<CMFIR>?
    internal var qFilter: UnsafeMutablePointer<CMFIR>?
    internal var iFilter256: UnsafeMutablePointer<CMFIR>?
    internal var qFilter256: UnsafeMutablePointer<CMFIR>?
    internal var iFilter512: UnsafeMutablePointer<CMFIR>?
    internal var qFilter512: UnsafeMutablePointer<CMFIR>?
    internal var iFilter768: UnsafeMutablePointer<CMFIR>?
    internal var qFilter768: UnsafeMutablePointer<CMFIR>?
    internal var iFilter1024: UnsafeMutablePointer<CMFIR>?
    internal var qFilter1024: UnsafeMutablePointer<CMFIR>?
    internal let iIF: UnsafeMutablePointer<Float>   // was float[512]
    internal let qIF: UnsafeMutablePointer<Float>   // was float[512]
    internal var receiver: CWReceiver?
    internal var isAural: Bool

    override init() {
        analyticSignal = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        analyticSignal.initialize(repeating: 0, count: 1024)
        mixerStream = UnsafeMutablePointer<CMDataStream>.allocate(capacity: 1)
        mixerStream.initialize(to: CMDataStream())
        iIF = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        iIF.initialize(repeating: 0, count: 512)
        qIF = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        qIF.initialize(repeating: 0, count: 512)
        isAural = false
        super.init()

        var tonepair = CMTonePair(mark: 1500.0, space: 0.0, baud: 45.45)
        receiver = nil
        isAural = false
        //  set up CMDataStream
        data = mixerStream
        mixerStream.pointee.array = analyticSignal
        mixerStream.pointee.samplingRate = Float(CMFs)
        mixerStream.pointee.samples = 512
        mixerStream.pointee.components = 1
        mixerStream.pointee.channels = 1
        setTonePair(&tonepair)

        iFilter256 = CMFIRLowpassFilter(300, Float(CMFs), 256)
        qFilter256 = CMFIRLowpassFilter(300, Float(CMFs), 256)

        iFilter512 = CMFIRLowpassFilter(300, Float(CMFs), 512)
        qFilter512 = CMFIRLowpassFilter(300, Float(CMFs), 512)

        iFilter768 = CMFIRLowpassFilter(300, Float(CMFs), 768)
        qFilter768 = CMFIRLowpassFilter(300, Float(CMFs), 768)

        iFilter1024 = CMFIRLowpassFilter(300, Float(CMFs), 1500)
        qFilter1024 = CMFIRLowpassFilter(300, Float(CMFs), 1500)

        iFilter = iFilter256
        qFilter = qFilter256
    }

    deinit {
        //  CMFIR objects were never freed in the original -dealloc; leave them.
        analyticSignal.deallocate()
        mixerStream.deallocate()
        iIF.deallocate()
        qIF.deallocate()
    }

    @objc(setReceiver:)
    func setReceiver(_ cwReceiver: CWReceiver?) {
        receiver = cwReceiver
    }

    @objc(setAural:)
    func setAural(_ state: Bool) {
        isAural = state
    }

    @objc(setCWBandwidth:)
    func setCWBandwidth(_ halfwidth: Float) {
        if halfwidth > 149 {
            //  bandwidth >= 300 Hz (300, 350, 400, 500)
            iFilter = iFilter256
            qFilter = qFilter256
        } else {
            if halfwidth > 76 {
                // bandwidth 153 Hz - 299 Hz (200, 250)
                iFilter = iFilter512
                qFilter = qFilter512
            } else {
                if halfwidth > 41 {
                    // bandwidth 82 Hz to 152 Hz (100, 150)
                    iFilter = iFilter768
                    qFilter = qFilter768
                } else {
                    //  bandwidth 81 Hz and below (30, 60)
                    iFilter = iFilter1024
                    qFilter = qFilter1024
                }
            }
        }
        CMUpdateFIRLowpassFilter(iFilter, halfwidth)
        CMUpdateFIRLowpassFilter(qFilter, halfwidth)
    }

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

        let sina = Double(mssin[mst])
        let cosa = Double(mscos[mst])
        let sinb = Double(lssin[lst])
        let cosb = Double(lscos[lst])
        dda.sint = sina * cosb + cosa * sinb
        dda.cost = cosa * cosb - sina * sinb

        var p = CMAnalyticPair()
        p.re = Float(dda.cost)
        p.im = Float(dda.sint)
        return p
    }

    func setDDA(_ dda: inout CMDDA, freq: Float) {
        dda.freq = freq
        dda.deltaTheta = 262144.0 * Double(freq) / CMFs
        dda.theta = 0.0
        dda.cost = 1.0
        dda.sint = 0.0
    }

    @objc(setTonePair:)
    func setTonePair(_ tonepair: UnsafePointer<CMTonePair>!) {
        setDDA(&mark, freq: Float(tonepair.pointee.mark))
    }

    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        let inStream = pipe.stream()!
        mixerStream.pointee.sourceID = inStream.pointee.sourceID
        let array = inStream.pointee.array!

        //  form split complex terms for mark and space signals
        for i in 0..<512 {
            let x = array[i]
            let mVfo = update(&mark)
            analyticSignal[i] = x * mVfo.re
            analyticSignal[i + 512] = x * mVfo.im
        }
        CMPerformFIR(iFilter, analyticSignal, 512, iIF)
        CMPerformFIR(qFilter, analyticSignal + 512, 512, qIF)

        if isAural {
            //  send to aural monitor
            if let receiver = receiver { receiver.received(iIF, quadrature: qIF, wide: array, samples: 512) }
            return
        }
        //  otherwise, pass mixer output to demodulator chain
        exportData()
    }
}
