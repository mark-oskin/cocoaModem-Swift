//
//  CWPipeline.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/25/06.
//  Swift port of CWPipeline.m.
//
//  The C structs ElementType / MorseTiming and the ring/filter macros were
//  moved out of CWPipeline.h into CWPipelineTypes.h so they can be shared with
//  the remaining Objective-C code (CWMatchedFilter owns the pipelines and hands
//  ElementType* across the boundary).  CWMatchedFilter, CMFIR, CMFFT and the
//  Boxcar / FFT filter helpers all stay Objective-C.
//

import Cocoa

//  C truncates a float to (signed) int toward zero and lets out-of-range values
//  wrap.  Mirror that with a guarded conversion so an out-of-range or NaN value
//  never traps the way Swift's checked Int32(_:) would (see DisplayColor.cInt).
@inline(__always)
func cwFloatToInt32(_ x: Float) -> Int32 {
    if x.isNaN { return 0 }
    let t = x.rounded(.towardZero)
    if t >= 2147483647.0 { return Int32.max }
    if t <= -2147483648.0 { return Int32.min }
    return Int32(t)
}

//  #define dataThreshold 0.5 / #define FILTERLENGTH 1024 (CWPipelineTypes.h).
//  Kept as local Float/Int32 constants so the numeric semantics stay exact
//  (the imported C macros are Double / Int).
private let kDataThreshold: Float = 0.5
private let kFilterLength: Int32 = 1024

@objc(CWPipeline)
class CWPipeline: NSObject {

    private var client: CWMatchedFilter!

    //  base ivars used by the CWSpeedPipeline subclass (-updateFilter:) -- keep
    //  the exact names and make them reachable within the module.
    var iDecimateFilter: UnsafeMutablePointer<CMFIR>!
    var qDecimateFilter: UnsafeMutablePointer<CMFIR>!

    private var iAGCFilter: UnsafeMutablePointer<CMFIR>!
    private var qAGCFilter: UnsafeMutablePointer<CMFIR>!
    private var decimated = [Float](repeating: 0, count: 64)

    private var noiseBuffer = [Float](repeating: 0, count: 2048)
    private var dataBuffer = [Float](repeating: 0, count: 2048)
    private var noiseGate: Float = 0
    private var dataBufferIndex: Int32 = 0

    private var dataFilter0: UnsafeMutablePointer<CMFIR>!
    private var dataFilter1: UnsafeMutablePointer<CMFIR>!
    private var dataFilter2: UnsafeMutablePointer<CMFIR>!

    private var estimatedSpeed: Float = 0

    private var threshold: Float = 0
    private var smoothedThreshold: Float = 0
    private var dataElement = ElementType()
    private var previousElement = ElementType()
    private var currentElement = ElementType()
    private var squelch: Float = 0

    //  key states
    private var keyState: Int32 = 0
    private var keyInterval: Int32 = 0

    private var timeoutTime: Int32 = 0
    private var currentState: Int32 = 0

    //  [matchedFilter] -> importArray -> stateChangedTo -> processElement -> updateMorseElement -> newCharacter -> [MatchedFilter] -> [MorseDecoder] .
    @objc(initFromClient:)
    init(fromClient matchedFilter: CWMatchedFilter) {
        super.init()
        client = matchedFilter

        //  dataBuffer / noiseBuffer are already zero-filled.
        dataBufferIndex = 0

        iAGCFilter = BoxcarFilter(190, kFilterLength)
        adjustWaveshapedBoxcarFilter(iAGCFilter, 60)
        qAGCFilter = BoxcarFilter(190, kFilterLength)
        adjustWaveshapedBoxcarFilter(qAGCFilter, 60)

        iDecimateFilter = BoxcarFilter(190, kFilterLength)
        adjustWaveshapedBoxcarFilter(iDecimateFilter, 175)
        qDecimateFilter = BoxcarFilter(190, kFilterLength)
        adjustWaveshapedBoxcarFilter(qDecimateFilter, 175)

        //  post processing limited data filter
        dataFilter0 = BoxcarFilter(24, 24)
        dataFilter1 = BoxcarFilter(24, 24)
        dataFilter2 = BoxcarFilter(24, 24)

        keyState = 0
        initElement(&previousElement, state: 0, valid: false)
        initElement(&currentElement, state: 0, valid: false)
        initElement(&dataElement, state: 0, valid: false)

        //  thresholds -- allow fast qsb to be 20 dB deep.
        setSquelch(-30.0, fastQSB: -20.0, slowQSB: -35.0)
        keyInterval = 0
        timeoutTime = 0
        currentState = 0
    }

    private func initElement(_ element: inout ElementType, state: Int32, valid: Bool) {
        element.state = state
        element.max = 0.0
        element.min = 1.0
        element.interval = 1
        element.valid = DarwinBoolean(valid)
    }

    private func getNoiseThresholdFromHistogram() {
        //  histogram[0..<240] correspond to the clearFloat( histogram, 240 ) in
        //  the original; the words above 240 are write-only (never read) so the
        //  full 256-slot buffer being zeroed here is equivalent.
        var histogram = [Float](repeating: 0, count: 256)
        var x: Float
        let idx = Int(dataBufferIndex)

        //  first check histogram of local levels
        var peak: Float = 0.0001
        for j in 0..<100 {
            let k = (idx + j - 101 + 2048) & 0x7ff
            x = noiseBuffer[k]
            if x > peak { peak = x }
        }
        for j in 0..<100 {
            let k = (idx + j - 101 + 2048) & 0x7ff
            var count = Int(cwFloatToInt32(noiseBuffer[k] / peak * 239.0))
            if count > 239 { count = 239 }
            histogram[count] += 0.003
            for kk in 1..<16 { histogram[count + kk] += 0.003 }
            var n = 16
            if n > count { n = count }
            var kk = 1
            while kk < n { histogram[count - kk] += 0.003; kk += 1 }
        }
        //  "signal" is sqrt(i*i+q*q) and therefore has a Rayleigh distribution if
        //  the original signal is Gaussian noise dominated.  Signal is considered
        //  noisy if middle third of the density function (histogram) is larger
        //  than high third of the density function.
        var low: Float = 0, middle: Float = 0, high: Float = 0
        for j in 0..<80 { low += histogram[j] }
        for j in 80..<150 { middle += histogram[j] }
        for j in 160..<240 { high += histogram[j] }

        x = middle / (high + middle)
        if x < 0.5 && high > 0.1 * low {
            noiseGate = 0.0
            //  now compute peak from the actual signal (instead of the noise
            //  gate signal, which goes through a different BPF)
            peak = 0.001
            for j in 0..<100 {
                let k = (idx + j - 101 + 2048) & 0x7ff
                x = dataBuffer[k]
                if x > peak { peak = x }
            }
            threshold = peak * 0.5
        } else {
            //  noisy, keep existing threshold
            noiseGate = 1.0
        }
    }

    @objc(importArray:)
    func importArray(_ array: UnsafeMutablePointer<Float>?) {
        guard let array = array else { return }

        var iFiltered = [Float](repeating: 0, count: 512)
        var qFiltered = [Float](repeating: 0, count: 512)
        var iDecimateFiltered = [Float](repeating: 0, count: 512)
        var qDecimateFiltered = [Float](repeating: 0, count: 512)

        //  At this point, sampling rate is 11025 s/s, lowpass I & Q channels
        //  (one Morse element at 50 wpm is approx 264 elements at 11025 s/s)
        CMPerformFIR(iAGCFilter, array, 512, &iFiltered)
        CMPerformFIR(qAGCFilter, array + 512, 512, &qFiltered)
        CMPerformFIR(iDecimateFilter, array, 512, &iDecimateFiltered)
        CMPerformFIR(qDecimateFilter, array + 512, 512, &qDecimateFiltered)

        //  Process data with 8:1 decimation (64 samples)
        for i in 0..<64 {
            let j = i * 8
            if (i % 32) == 0 { getNoiseThresholdFromHistogram() }

            var x = iFiltered[j]
            var y = qFiltered[j]
            noiseBuffer[Int(dataBufferIndex)] = sqrt(x * x + y * y)
            x = iDecimateFiltered[j]
            y = qDecimateFiltered[j]
            dataBuffer[Int(dataBufferIndex)] = sqrt(x * x + y * y)

            dataBufferIndex = (dataBufferIndex + 1) & 0x7ff

            //  pick data sample delayed by 92 samples in data buffer
            let t = (Int(dataBufferIndex) + 2048 - 92) & 0x7ff
            let signal = dataBuffer[t]

            smoothedThreshold = smoothedThreshold * 0.99 + threshold * 0.01
            x = (signal > smoothedThreshold) ? 1.0 : 0.0
            x = (CMSimpleFilter(dataFilter0, x) > kDataThreshold) ? 1.0 : 0.0
            x = (CMSimpleFilter(dataFilter1, x) > kDataThreshold) ? 1.0 : 0.0
            x = CMSimpleFilter(dataFilter2, x)
            if x > dataElement.max { dataElement.max = x }
            if x < dataElement.min { dataElement.min = x }
            let state: Int32 = (x > kDataThreshold) ? 1 : 0
            if state != dataElement.state {
                //  interval ended
                dataElement.valid = true
                stateChangedTo(dataElement)
                //  create next interval
                dataElement.state = state
                dataElement.interval = 1
                dataElement.max = 0.0
                dataElement.min = 1.0
            } else {
                dataElement.interval += 1
                if dataElement.state == 0 && dataElement.interval > 20 {
                    //  self imposed timeout to flush the last character, if it is
                    //  an interword, it is accumulated in -stateChangedTo:
                    stateChangedTo(dataElement)
                    dataElement.interval = 1
                }
            }
        }
    }

    //  latestElement is only read (the original passed a pointer but never wrote
    //  through it), so the port takes it by value.
    private func stateChangedTo(_ latestElement: ElementType) {
        if latestElement.interval <= 0 { return }

        if latestElement.state == currentElement.state {
            //  actual state did not change, accumulate into current element
            currentElement.interval += latestElement.interval
            if latestElement.max > currentElement.max { currentElement.max = latestElement.max }
            if latestElement.min < currentElement.min { currentElement.min = latestElement.min }

            if currentElement.state == 0 && currentElement.interval > client.interWord() / 2 {
                //  flush a word without waiting until the next character to come along
                if previousElement.valid.boolValue {
                    withUnsafeMutablePointer(to: &previousElement) { processElement($0) }
                }
                previousElement.valid = false

                //currentElement.interval *= 2;
                withUnsafeMutablePointer(to: &currentElement) { processElement($0) }
                currentElement.interval = 0
            }
            return
        } else {
            //  state apparently changed, check if currentElement (the one before
            //  this latest interval) looks like noise
            let noisy = (currentElement.state == 0) ? (currentElement.min > 0.05) : (currentElement.max < 0.95)

            if noisy {
                //  merge up to three elements if middle element is noisy
                currentElement.state = latestElement.state
                currentElement.interval += latestElement.interval
                if latestElement.max > currentElement.max { currentElement.max = latestElement.max }
                if latestElement.min < currentElement.min { currentElement.min = latestElement.min }
                //  merge previousElement into current element if previousElement is valid
                if previousElement.valid.boolValue {
                    currentElement.interval += previousElement.interval
                    if previousElement.max > currentElement.max { currentElement.max = previousElement.max }
                    if previousElement.min < currentElement.min { currentElement.min = previousElement.min }
                }
                previousElement.valid = false
                return
            } else {
                //  new state received, flush out previousElement if valid...
                if previousElement.valid.boolValue {
                    withUnsafeMutablePointer(to: &previousElement) { processElement($0) }
                }
                //  ... and copy currentElement into previousElement...
                previousElement = currentElement
                currentElement = latestElement
            }
        }
    }

    @objc(processElement:)
    func processElement(_ element: UnsafeMutablePointer<ElementType>?) {
        //  process element for CWPipeline
        //  CWSpeedPipeline has a different -processElement method
        client.updateMorseElement(element, pipe: self)
    }

    @objc(updateFilter:)
    func updateFilter(_ elementLength: Int32) {
        //  adjust matched filter
        //  max matched filter is for approx 12 wpm
        //  matched filter at 11025, while element is defined at 11025/8 sampling rate
        var filterLength = elementLength &* 8
        if filterLength > 1010 { filterLength = 1010 }
        else if filterLength < 200 { filterLength = 200 }

        adjustWaveshapedBoxcarFilter(iDecimateFilter, filterLength)
        adjustWaveshapedBoxcarFilter(qDecimateFilter, filterLength)
    }

    //  squelch value (0.0 means fully squelched)
    @objc(setSquelch:fastQSB:slowQSB:)
    func setSquelch(_ db: Float, fastQSB: Float, slowQSB: Float) {
        squelch = Float(pow(10.0, Double(db) / 20.0) * 0.25)
        threshold = squelch
        smoothedThreshold = squelch
    }

    @objc(newClick)
    func newClick() {
    }
}
