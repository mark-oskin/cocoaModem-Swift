//
//  CWMatchedFilter.swift
//  CoreDSP
//
//  Swift port of the old app's CWMatchedFilter.swift: owns the decode
//  pipeline (CWPipeline) and the speed-estimating pipeline (CWSpeedPipeline),
//  merges consecutive Morse elements into a dot/dash string per character
//  (-updateDeglitchedMorseElement), and adapts the decode filter's assumed
//  element length to the estimated code speed.
//
//  CONCURRENCY NOTE: the original ran speed estimation on a detached
//  background thread woken by an NSConditionLock every 4 buffers
//  (`cycle == 3`), then pushed results back to the UI thread via
//  -performSelector(onMainThread:). There is no UI thread in this headless
//  DSP core, so the estimate is simply computed synchronously on the same
//  cadence, right where the original signaled the thread to wake up. This is
//  a simplification of the concurrency model only -- the estimation math
//  itself (CWSpeedPipeline.estimateMorseTiming) is transplanted verbatim.
//

import Foundation

final class CWMatchedFilter {

    weak var decoder: CWMorseDecoder?

    private var cycle: Int32 = 0

    private var decodePipeline: CWPipeline!
    private var speedPipeline: CWSpeedPipeline!

    private var intervalBuffer = [CWElementType](repeating: CWElementType(), count: 32)
    private var intervalConsumer: Int32 = 0, intervalProducer: Int32 = 0

    private var latency: Int32 = 0   // 0 - no deglitch, 1 = don't wait for 6 elements before processing

    private var estimatedSpeed: Float = 20
    private var chosenSpeed: Int32 = 0   //  0 == auto speed
    private var wpm: Float = 20
    private(set) var limited: Bool = false

    //  running estimate of element timing
    private var elementLength: Float = 0, interSymbolLength: Float = 0, ditLength: Float = 0, dashLength: Float = 0
    private var basicLength = [Float](repeating: 0, count: 2)
    private var spacePrinted: Bool = true

    /// Current adaptive speed estimate (wpm); mirrors the original's
    /// -setCWSpeed:limited: callback into the UI speed readout.
    var currentWPM: Float { wpm }

    private func clearIntervalBuffer() {
        for i in 0..<32 { intervalBuffer[i].interval = 10000 }
        intervalProducer = 0; intervalConsumer = 0
    }

    //  [mixer] -> importBlock -> stateChangedTo -> processElement -> updateMorseElement -> newCharacter -> [decoder]
    init() {
        //  initial match filter set for 20 wpm
        elementLength = Float(18 * 92.0 / Double(estimatedSpeed)); ditLength = elementLength
        interSymbolLength = 3 * elementLength; dashLength = interSymbolLength

        decodePipeline = CWPipeline(fromClient: self)
        speedPipeline = CWSpeedPipeline(fromClient: self)
        changeMatchedFilterToSpeed(estimatedSpeed, force: true)

        clearIntervalBuffer()
    }

    //  Baseband I/Q from CWMixer arrives here.
    func importBlock(_ iArray: UnsafePointer<Float>, _ qArray: UnsafePointer<Float>) {
        speedPipeline.importArray(iArray, qArray)
        decodePipeline.importArray(iArray, qArray)

        if cycle == 3 {
            updateSpeedEstimate()
        }
        cycle = (cycle &+ 1) & 0xf
    }

    func newClick(_ delta: Float) {
        if abs(delta) > 30.0 {
            clearIntervalBuffer()
            if estimatedSpeed < 15 || estimatedSpeed > 30 {
                estimatedSpeed = 22
                elementLength = Float(18 * 92.0 / Double(estimatedSpeed)); ditLength = elementLength
                interSymbolLength = 3 * elementLength; dashLength = interSymbolLength
                changeMatchedFilterToSpeed(estimatedSpeed, force: true)
            }
        }
        cycle = 0
    }

    //  was the body of -updateSpeed:'s autoreleasepool block, minus the thread/lock wrapper
    private func updateSpeedEstimate() {
        let estimate = speedPipeline.estimateMorseTiming()
        let speed = estimate.speed
        guard speed > 4 && speed < 101 else { return }

        if chosenSpeed == 0 /* auto */ {
            let change = abs(speed - wpm)
            wpm = (change < 0.5) ? (wpm * 0.5 + speed * 0.5) : speed
            elementLength = elementLength * 0.5 + estimate.interElement * 0.5; basicLength[0] = elementLength
            ditLength = estimate.dit; basicLength[1] = ditLength
            dashLength = estimate.dash
            interSymbolLength = estimate.interSymbol
            if abs(estimatedSpeed - wpm) > 0.25 {
                limited = false
                changeMatchedFilterToSpeed(wpm, force: false)
            }
        } else {
            //  user selected speed
            var ratio = speed / Float(chosenSpeed)
            if ratio > 1.0 { ratio = 1.0 / ratio }
            if ratio > 0.8 {
                let change = abs(speed - wpm)
                wpm = (change < 0.5) ? (wpm * 0.5 + speed * 0.5) : speed
                elementLength = elementLength * 0.5 + estimate.interElement * 0.5; basicLength[0] = elementLength
                ditLength = estimate.dit; basicLength[1] = ditLength
                dashLength = estimate.dash
                interSymbolLength = estimate.interSymbol
                if abs(estimatedSpeed - wpm) > 0.25 {
                    limited = false
                    changeMatchedFilterToSpeed(wpm, force: false)
                }
            } else {
                limited = true
                var trySpeed = speed
                if Double(trySpeed) > Double(chosenSpeed) / 0.8 { trySpeed = Float(Double(chosenSpeed) / 0.8) }
                else if Double(trySpeed) < Double(chosenSpeed) * 0.8 { trySpeed = Float(Double(chosenSpeed) * 0.8) }
                elementLength = Float(18 * 92.0 / Double(trySpeed)); ditLength = elementLength
                interSymbolLength = 3 * elementLength; dashLength = interSymbolLength
                let change = abs(trySpeed - wpm)
                wpm = (change < 0.5) ? (wpm * 0.5 + trySpeed * 0.5) : trySpeed
                if abs(estimatedSpeed - wpm) > 0.25 {
                    changeMatchedFilterToSpeed(wpm, force: false)
                }
            }
        }
    }

    func interWord() -> Int32 {
        return Int32(elementLength * 6)
    }

    //  A new Morse element is determined from the state (keyed or unkeyed) and duration (in units of ~0.74 ms).
    private func updateDeglitchedMorseElement(_ element: CWElementType) {
        var string = [UInt8](repeating: 0, count: 32)
        var keyInterval = [Float](repeating: 0, count: 32)
        var keyCount = 0
        var lastUnkeyElement: Int32 = 0

        let longElement = Int32(elementLength * 2.0)

        intervalBuffer[Int(intervalProducer)] = element
        intervalProducer = (intervalProducer &+ 1) & 0x1f

        //  find how many elements have not yet been processed
        var n = intervalProducer - intervalConsumer
        if n < 0 { n += 32 }

        //  v0.33 flush word, and add low latency
        if n < 10 && latency > 1 {   //  wait for at least 10 element-pairs before processing
            let flush = (element.state == 0) && (element.interval > longElement * 3 / 4)
            if !flush { return }
        }

        //  now check for any long unkeyed element that has not been consumed
        keyCount = 0
        var k = intervalConsumer

        while true {
            if k == intervalProducer { return }   //  did not find an intercharacter or interword element

            let e = intervalBuffer[Int(k)]
            k = (k &+ 1) & 0x1f

            if e.state == 0 {
                lastUnkeyElement = e.interval
                if lastUnkeyElement > longElement {
                    if keyCount <= 0 {
                        //  no keyed element... output a space if it has not already been emitted
                        if !spacePrinted { decoder?.newCharacter("", wordSpacing: 1) }
                        spacePrinted = true
                        //  long unkeyed element received with no keyed element, toss the interval
                        intervalConsumer = k
                        return
                    }
                    while intervalBuffer[Int(k)].state == 0 {
                        if k == intervalProducer { return }   //  did not find an intercharacter or interword element
                        lastUnkeyElement += intervalBuffer[Int(k)].interval
                        k = (k &+ 1) & 0x1f
                        if Float(lastUnkeyElement) > elementLength * 7 { break }
                    }
                    break
                }
            } else {
                keyInterval[keyCount] = Float(e.interval)   //  accumulate keyed intervals for decoding
                keyCount += 1
            }
        }
        if keyCount <= 0 { return }   //  end of character not seen

        //  now check for the character spacing, e.g. take care of moderate Farnsworth spacing
        let u = Float(longElement) * 2.0
        var count = 0
        var sum: Float = 0.0
        for i in 0..<32 {
            let e = intervalBuffer[i]
            if e.interval < 5000 && e.interval > 12 {
                if e.state == 0 {
                    if e.interval > longElement && Float(e.interval) < u {
                        sum += Float(e.interval)
                        count += 1
                    }
                }
            }
        }
        let wordInterval: Int32 = (count > 0) ? Int32(1.8 * Double(sum) / Double(count)) : Int32(elementLength * 5.0)

        let v = (ditLength + dashLength) * 0.5
        for i in 0..<keyCount {
            string[i] = (keyInterval[i] < v) ? UInt8(ascii: ".") : UInt8(ascii: "-")
        }

        //  character retrieved, update the consumer pointer
        intervalConsumer = k
        spacePrinted = (lastUnkeyElement > wordInterval)
        let sequence = String(decoding: string[0..<keyCount], as: UTF8.self)
        decoder?.newCharacter(sequence, wordSpacing: spacePrinted ? 1 : 0)
    }

    //  callback from CWPipeline when a new Morse element is determined
    func updateMorseElement(_ element: inout CWElementType, pipe: CWPipeline) {
        guard pipe === decodePipeline, element.interval != 0 else { return }

        //  v0.33 -- `if ( 1 || latency == 0 )` in the original is always true; the
        //  glitch-filter branch that followed it is unreachable and is not ported.
        updateDeglitchedMorseElement(element)
    }

    func changeCodeSpeed(to speed: Int32) {
        chosenSpeed = speed
        if speed <= 0 { return }
        //  if it is not auto speed, set matched filters for the chosen speed
        changeMatchedFilterToSpeed(Float(speed), force: true)
    }

    func setLatency(_ value: Int32) {
        latency = value
    }

    //  pick a matched filter for the code speed
    func changeMatchedFilterToSpeed(_ speed: Float, force forced: Bool) {
        if !forced && abs(estimatedSpeed - speed) < 0.25 { return }

        estimatedSpeed = speed
        decodePipeline.updateFilter(Int32(331 * 0.85 * 5.0 / Double(estimatedSpeed)))
    }

    func setSquelch(_ db: Float, fastQSB: Float, slowQSB: Float) {
        decodePipeline.setSquelch(db, fastQSB: fastQSB, slowQSB: slowQSB)
        speedPipeline.setSquelch(db, fastQSB: fastQSB, slowQSB: slowQSB)
    }

    var elementLengthValue: Int32 { Int32(elementLength) }
}
