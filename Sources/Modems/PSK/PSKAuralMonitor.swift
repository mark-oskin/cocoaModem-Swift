//
//  PSKAuralMonitor.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/11/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//  Swift port of PSKAuralMonitor.m.  Subclass of ModemAuralMonitor (Swift).
//  The C `AuralChannel trxChannel[4]` value array is modelled as a Swift array
//  of a small final reference type (AuralChannel) so the embedded CMDDA fields
//  keep stable addresses that can be passed to -setDDA:/-updateDDA:.  Each
//  channel's CMFIR* bandpass filter (and the inherited CMFIR* lowpass filters)
//  are freed via CMDeleteFIR in deinit.
//

import Cocoa

//  One aural monitor channel.  A reference type so the two embedded CMDDA
//  synthesizers have persistent heap addresses (the original code takes the
//  address of trxChannel[n].carrier / .outputTone).
private final class AuralChannel {
    var enabled: Bool = false           //  enabled in UI
    var active: Bool = false            //  selected in waterfall
    var centerFrequency: Float = 0
    let carrier: UnsafeMutablePointer<CMDDA>
    var bandwidth: Float = 0
    var gain: Float = 0
    var isFloating: Bool = false
    var fixedFrequency: Float = 0
    let outputTone: UnsafeMutablePointer<CMDDA>
    var bandpassFilter: UnsafeMutablePointer<CMFIR>? = nil

    init() {
        carrier = UnsafeMutablePointer<CMDDA>.allocate(capacity: 1)
        carrier.initialize(to: CMDDA())
        outputTone = UnsafeMutablePointer<CMDDA>.allocate(capacity: 1)
        outputTone.initialize(to: CMDDA())
    }

    deinit {
        carrier.deallocate()
        outputTone.deallocate()
        if let f = bandpassFilter { CMDeleteFIR(f) }
    }
}

@objc(PSKAuralMonitor)
class PSKAuralMonitor: ModemAuralMonitor {

    private var pskSampling: Bool = false
    //  channel == 2 is transmit channel, channel == 3 is widebandChannel
    private var trxChannel: [AuralChannel] = (0..<4).map { _ in AuralChannel() }
    private var transmitChannel: Int32 = 0      //  receive channel (0,1) that we are transmitting on

    //  (Private API)
    private func setCenterFrequencyAndDDA(_ freq: Float, channel: Int32) {
        let p = trxChannel[Int(channel)]
        p.centerFrequency = freq
        if freq > 10 { setDDA(p.carrier, freq: freq) }
    }

    //  (Private API)
    private func setFixedFrequencyAndDDA(_ freq: Float, channel: Int32) {
        let p = trxChannel[Int(channel)]
        p.fixedFrequency = freq
        if freq > 10 { setDDA(p.outputTone, freq: freq) }
    }

    //  (Private API)
    private func initChannel(_ channel: Int32, atten attenuation: Float, hasNarrow: Bool) {
        let p = trxChannel[Int(channel)]
        p.enabled = false           //  enabled in UI
        p.active = false            //  selected in waterfall
        p.isFloating = true         //  no need to shift input frequency

        if hasNarrow {
            setCenterFrequencyAndDDA(1000, channel: channel)
            setFixedFrequencyAndDDA(800, channel: channel)
            p.bandwidth = 15
            p.bandpassFilter = CMFIRBandpassFilter(1000 - 15, 1000 + 15, 11025.0, 512)
        } else {
            p.centerFrequency = 0
            p.fixedFrequency = 0
            p.bandwidth = 0
            p.bandpassFilter = nil
        }
    }

    //  (Private API)
    private func makeLowpassFilters() {
        //  lowpass filters to pass up to PSK125
        for i in 0..<2 {
            rxLowpassIFilter[i] = CMFIRLowpassFilter(200.0, 11025.0, 512)
            rxLowpassQFilter[i] = CMFIRLowpassFilter(200.0, 11025.0, 512)
            txLowpassIFilter[i] = CMFIRLowpassFilter(200.0, 11025.0, 512)
            txLowpassQFilter[i] = CMFIRLowpassFilter(200.0, 11025.0, 512)
        }
    }

    override init() {
        super.init()
        pskSampling = false
        transmitChannel = 0
        initChannel(0, atten: 0, hasNarrow: true)   //  rx0
        initChannel(1, atten: 0, hasNarrow: true)   //  rx1
        initChannel(2, atten: 6, hasNarrow: true)   //  tx0 & tx1
        initChannel(3, atten: 10, hasNarrow: false) //  wideband
        makeLowpassFilters()
    }

    deinit {
        //  free the inherited CMFIR* lowpass filters (channel bandpass filters
        //  are freed by AuralChannel.deinit)
        for i in 0..<2 {
            if let f = rxLowpassIFilter[i] { CMDeleteFIR(f) }
            if let f = rxLowpassQFilter[i] { CMDeleteFIR(f) }
            if let f = txLowpassIFilter[i] { CMDeleteFIR(f) }
            if let f = txLowpassQFilter[i] { CMDeleteFIR(f) }
        }
    }

    //  (Private API)
    private func mixAuralChannel(_ p: AuralChannel, from array: UnsafeMutablePointer<Float>, into outbuf: UnsafeMutablePointer<Float>) {
        var gain = p.gain * masterGain
        var filtered = [Float](repeating: 0, count: 512)
        CMPerformFIR(p.bandpassFilter, array, 512, &filtered)
        if p.isFloating {
            //  floating tone, simply mix bandpass output to aural output
            for i in 0..<512 { outbuf[i] += filtered[i] * gain }
        } else {
            //  fixed tone, translate tone
            var si = [Float](repeating: 0, count: 512)
            var sq = [Float](repeating: 0, count: 512)
            var lpi = [Float](repeating: 0, count: 512)
            var lpq = [Float](repeating: 0, count: 512)
            //  first mix down to baseband (si,sq)
            var q = p.carrier
            for i in 0..<512 {
                let vfo = updateDDA(q)
                let u = filtered[i]
                si[i] = vfo.re * u
                sq[i] = vfo.im * u
            }
            //  lowpass the baseband signal into (lpi,lpq)
            CMPerformFIR(rxLowpassIFilter[0], &si, 512, &lpi)
            CMPerformFIR(rxLowpassQFilter[0], &sq, 512, &lpq)
            //  remodulate to target frequency and mix into aural output
            q = p.outputTone
            gain *= 2
            for i in 0..<512 {
                let vfo = updateDDA(q)
                outbuf[i] += (vfo.re * lpq[i] - vfo.im * lpi[i]) * gain
            }
        }
    }

    //  (Private API)
    private func setAuralChannel(_ p: AuralChannel, usingMixer r: AuralChannel, from array: UnsafeMutablePointer<Float>, into outbuf: UnsafeMutablePointer<Float>) {
        var gain = p.gain * masterGain
        var filtered = [Float](repeating: 0, count: 512)
        CMPerformFIR(r.bandpassFilter, array, 512, &filtered)
        if p.isFloating {
            //  floating tone, simply mix bandpass output to aural output
            for i in 0..<512 { outbuf[i] = filtered[i] * gain }
        } else {
            //  fixed tone, translate tone
            var si = [Float](repeating: 0, count: 512)
            var sq = [Float](repeating: 0, count: 512)
            var lpi = [Float](repeating: 0, count: 512)
            var lpq = [Float](repeating: 0, count: 512)
            //  first mix down to baseband (si,sq)
            var q = r.carrier
            for i in 0..<512 {
                let vfo = updateDDA(q)
                let u = filtered[i]
                si[i] = vfo.re * u
                sq[i] = vfo.im * u
            }
            //  lowpass the baseband signal into (lpi,lpq)
            CMPerformFIR(rxLowpassIFilter[0], &si, 512, &lpi)
            CMPerformFIR(rxLowpassQFilter[0], &sq, 512, &lpq)
            //  remodulate to target frequency and mix into aural output
            q = p.outputTone
            gain *= 2
            for i in 0..<512 {
                let vfo = updateDDA(q)
                outbuf[i] = (vfo.re * lpq[i] - vfo.im * lpi[i]) * gain
            }
        }
    }

    //  data at 11025 s/s arrives here
    @objc(importWidebandData:)
    func importWidebandData(_ pipe: CMPipe) {
        if pskSampling == false { return }

        //  input wideband stream
        guard let array = pipe.stream()?.pointee.array else { return }

        var outbuf = [Float](repeating: 0, count: 512)

        //  accumulate components into output buffer
        //  Start by initializing the output buffer with the wideband buffer, or clear the output buffer
        var p = trxChannel[3]
        if p.enabled {
            let gain = p.gain * masterGain
            for i in 0..<512 { outbuf[i] = array[i] * gain }
        }
        //  (else: outbuf is already zero-filled)

        //  rx1
        p = trxChannel[0]
        if p.enabled && p.active { mixAuralChannel(p, from: array, into: &outbuf) }
        //  rx2
        p = trxChannel[1]
        if p.enabled && p.active { mixAuralChannel(p, from: array, into: &outbuf) }

        auralMonitor.addLeft(&outbuf, right: nil, samples: 512, client: self)
    }

    //  data at 11025 s/s arrives here
    @objc(importTransmitData:)
    func importTransmitData(_ array: UnsafeMutablePointer<Float>) {
        if pskSampling == false { return }

        let p = trxChannel[2]
        if p.enabled && p.active {
            //  input wideband stream
            var outbuf = [Float](repeating: 0, count: 512)
            setAuralChannel(p, usingMixer: trxChannel[Int(transmitChannel)], from: array, into: &outbuf)
            auralMonitor.addLeft(nil, right: &outbuf, samples: 512, client: self)
        }
    }

    @objc(transmitOnReceiver:)
    func transmit(onReceiver n: Int32) {
        transmitChannel = n & 1
    }

    //  (Private API)
    private func shouldBeSampling() -> Bool {
        //  unqualified NO if muted or interface not visible
        if demodulatorIsActive == false || muted == true { return false }
        //  otherwise check wideband (can be on even when not clicked)
        if trxChannel[3].enabled == true { return true }

        //  now check if a channel is enabled and clicked
        for i in 0..<3 {
            if trxChannel[i].enabled == true && trxChannel[i].active == true { return true }
        }
        return false
    }

    //  (Private API)
    private func updateSamplingState() {
        let wasSampling = pskSampling
        let isSampling = shouldBeSampling()
        if wasSampling != isSampling {
            if isSampling { auralMonitor.addClient(self) } else { auralMonitor.removeClient(self) }
            pskSampling = isSampling
        }
    }

    @objc(setMute:)
    func setMute(_ state: Bool) {
        muted = state
        updateSamplingState()
    }

    @objc(setMasterGain:)
    func setMasterGain(_ value: Float) {
        masterGain = value * value
    }

    @objc(setModemActive:)
    func setModemActive(_ state: Bool) {
        demodulatorIsActive = state
        updateSamplingState()
    }

    //  channel: 0, 1 = receivers, 2 = transmitter
    @objc(setFloating:forChannel:)
    func setFloating(_ state: Bool, forChannel channel: Int32) {
        if channel == 0 || channel == 1 || channel == 2 {
            trxChannel[Int(channel)].isFloating = state
        }
    }

    //  channel: 0, 1 = receivers, 2 = transmitter
    @objc(setFixedFrequency:forChannel:)
    func setFixedFrequency(_ freq: Float, forChannel channel: Int32) {
        if channel == 0 || channel == 1 || channel == 2 {
            setFixedFrequencyAndDDA(freq, channel: channel)
        }
    }

    //  channel: 0, 1 = receivers, 2 = transmitter, 3 = wideband
    @objc(setEnable:channel:)
    func setEnable(_ state: Bool, channel: Int32) {
        if channel >= 0 && channel <= 3 {
            trxChannel[Int(channel)].enabled = state
            updateSamplingState()
        }
    }

    //  (Private API)
    private func setScalarGain(_ scalar: Float, channel: Int32) {
        if channel >= 0 && channel <= 3 {
            trxChannel[Int(channel)].gain = scalar
        }
    }

    //  channel: 0 = receiver, 1 = transmitter, 2 = background, 3 = master
    @objc(setAttenuation:channel:)
    func setAttenuation(_ db: Float, channel: Int32) {
        setScalarGain(Float(pow(10.0, Double(fabsf(db)) * (-0.05))), channel: channel)   //  v0.88 fabs()
    }

    //  set frequency and activate
    @objc(setCenterFrequency:bandwidth:channel:)
    func setCenterFrequency(_ freq: Float, bandwidth: Float, channel: Int32) {
        let p = trxChannel[Int(channel)]
        if p.centerFrequency != freq || p.bandwidth != bandwidth {
            CMUpdateFIRBandpassFilter(p.bandpassFilter, freq - bandwidth, freq + bandwidth)
            setCenterFrequencyAndDDA(freq, channel: channel)
            p.bandwidth = bandwidth
        }
        trxChannel[Int(channel)].active = true
        trxChannel[2].active = true             //  also make tx active
        updateSamplingState()
    }

    @objc(disactivateChannel:)
    func disactivateChannel(_ channel: Int32) {
        if channel == 0 || channel == 1 || channel == 2 {
            trxChannel[Int(channel)].active = false
            trxChannel[2].active = (trxChannel[0].active && trxChannel[1].active)   //  update tx active
            updateSamplingState()
        }
    }
}
