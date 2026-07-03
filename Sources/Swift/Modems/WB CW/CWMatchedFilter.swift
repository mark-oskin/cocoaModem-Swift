//
//  CWMatchedFilter.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/3/06.
//  Swift port of CWMatchedFilter.m.
//
//  CW matched filter + Morse element decoder.  Subclass of CMFSKMatchedFilter,
//  but it does not use the base mark/space matched-filter path: analytic pairs
//  arrive through -importData: and are handed to two Swift pipelines
//  (CWPipeline / CWSpeedPipeline).  A background thread (updateSpeed:) estimates
//  the code speed.
//
//  Port notes:
//   * ElementType / MorseTiming are the shared C structs in CWPipelineTypes.h;
//     ElementType.valid is a DarwinBoolean (matching CWPipeline.swift).
//   * clearFloat/clearChar (Clears.h) are replaced by direct zeroing.
//   * -updateMorseElement:pipe: contained a `if ( 1 || latency == 0 )` guard that
//     is always true; the unreachable glitch-filter branch below it is not ported
//     (dead code).  `intervalBuffer`/`glitch` masks (& 0x1f) are preserved.
//   * `elementLength` collides with the -elementLength accessor selector; the
//     property keeps the name and the accessor is elementLengthValue().
//   * The background thread retains self forever (the C's while(1) thread did the
//     same) so this object is intentionally never deallocated.
//

import Cocoa

private let MAXINTERVALBUF: Int32 = 32

@objc(CWMatchedFilter)
class CWMatchedFilter: CMFSKMatchedFilter {

    internal weak var decoder: MorseDecoder?
    internal weak var receiver: CWReceiver?
    internal var fast: Bool = false

    internal var signal = [Float](repeating: 0, count: 4096)
    internal var cycle: Int32 = 0

    internal var decodePipeline: CWPipeline?
    internal var speedPipeline: CWSpeedPipeline?

    internal var intervalBuffer = [ElementType](repeating: ElementType(), count: Int(MAXINTERVALBUF))
    internal var intervalConsumer: Int32 = 0, intervalProducer: Int32 = 0
    internal var previousState: Int32 = 0

    internal var glitch = [ElementType](repeating: ElementType(), count: 4)

    internal var estimatedSpeed: Float = 0
    internal var latency: Int32 = 0             // 0 - no deglitch, 1 = don't wait for 6 elements before processing

    internal var estimateSpeed: NSConditionLock!
    internal var chosenSpeed: Int32 = 0
    internal var wpm: Float = 0
    internal var limited: Bool = false

    //	running estimate of element timing
    internal var elementLength: Float = 0, interSymbolLength: Float = 0, ditLength: Float = 0, dashLength: Float = 0
    internal var basicLength = [Float](repeating: 0, count: 2)
    internal var character = [CChar](repeating: 0, count: 65)
    internal var characterIndex: Int32 = 0
    internal var spacePrinted: Bool = false

    private func clearPipeline() {
        for i in 0..<32 { intervalBuffer[i].interval = 10000 }
        intervalProducer = 0; intervalConsumer = 0
        for i in 0..<4 { glitch[i].valid = false }
    }

    override init() {
        super.init()
        decoder = nil
        fast = false
        cycle = 0
        latency = 0
        spacePrinted = true

        for i in 0..<4096 { signal[i] = 0 }

        //  initial match filter set for 20 wpm
        estimatedSpeed = 20
        elementLength = Float(18 * 92.0 / Double(estimatedSpeed)); ditLength = elementLength
        interSymbolLength = 3 * elementLength; dashLength = interSymbolLength
        changeMatchedFilterToSpeed(estimatedSpeed, force: true)

        decodePipeline = CWPipeline(fromClient: self)
        speedPipeline = CWSpeedPipeline(fromClient: self)

        estimateSpeed = NSConditionLock(condition: 0)

        Thread.detachNewThreadSelector(#selector(updateSpeed(_:)), toTarget: self, with: self)

        characterIndex = 0
        clearPipeline()

        for i in 0..<65 { character[i] = 0 }
    }

    //  Sampled data from the complex mixer arrives here.
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        guard let stream = pipe.stream() else { return }
        let array = stream.pointee.array

        speedPipeline?.importArray(array)
        decodePipeline?.importArray(array)

        //  signal the speed estimating thread
        if cycle == 3 {
            estimateSpeed.lock()
            estimateSpeed.unlock(withCondition: 1)
        }
        cycle = (cycle &+ 1) & 0xf
    }

    @objc(newClick:)
    func newClick(_ delta: Float) {
        if abs(delta) > 30.0 {
            clearPipeline()
            if estimatedSpeed < 15 || estimatedSpeed > 30 {
                estimatedSpeed = 22
                elementLength = Float(18 * 92.0 / Double(estimatedSpeed)); ditLength = elementLength
                interSymbolLength = 3 * elementLength; dashLength = interSymbolLength
                changeMatchedFilterToSpeed(estimatedSpeed, force: true)
            }
        }
        cycle = 0
        receiver?.setCWSpeed(0, limited: false)
    }

    //  since UI can be involved, -setCWSpeed: is performed in the main thread
    @objc(updateInMainThread)
    func updateInMainThread() {
        changeMatchedFilterToSpeed(wpm, force: false)
        receiver?.setCWSpeed(wpm, limited: limited)
    }

    //  Thread for speed estimation.
    @objc(updateSpeed:)
    func updateSpeed(_ client: Any?) {
        while true {
            autoreleasepool {
                estimateSpeed.lock(whenCondition: 1)
                estimateSpeed.unlock(withCondition: 0)

                let estimate = speedPipeline?.estimateMorseTiming() ?? MorseTiming()
                let speed = estimate.speed

                if speed > 4 && speed < 101 {

                    //  if auto speed, try estimate the parameters
                    if chosenSpeed == 0 /* auto */ {
                        let change = abs(speed - wpm)
                        wpm = (change < 0.5) ? (wpm * 0.5 + speed * 0.5) : speed
                        //  average it out a little
                        elementLength = elementLength * 0.5 + estimate.interElement * 0.5; basicLength[0] = elementLength
                        ditLength = estimate.dit; basicLength[1] = ditLength
                        dashLength = estimate.dash
                        interSymbolLength = estimate.interSymbol
                        //  check to see if we really need to update
                        if abs(estimatedSpeed - wpm) > 0.25 {
                            limited = false
                            self.performSelector(onMainThread: #selector(updateInMainThread), with: nil, waitUntilDone: false)
                        }
                    } else {
                        //  user selected speed
                        var ratio = speed / Float(chosenSpeed)
                        if ratio > 1.0 { ratio = 1.0 / ratio }
                        if ratio > 0.8 {
                            let change = abs(speed - wpm)
                            wpm = (change < 0.5) ? (wpm * 0.5 + speed * 0.5) : speed
                            //  average it out a little
                            elementLength = elementLength * 0.5 + estimate.interElement * 0.5; basicLength[0] = elementLength
                            ditLength = estimate.dit; basicLength[1] = ditLength
                            dashLength = estimate.dash
                            interSymbolLength = estimate.interSymbol
                            //  check to see if we really need to update
                            if abs(estimatedSpeed - wpm) > 0.25 {
                                limited = false
                                self.performSelector(onMainThread: #selector(updateInMainThread), with: nil, waitUntilDone: false)
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
                                self.performSelector(onMainThread: #selector(updateInMainThread), with: nil, waitUntilDone: false)
                            }
                        }
                    }
                }
            }
        }
    }

    func newCharacter(_ string: UnsafePointer<CChar>, length: Int32, wordSpacing spacing: Int32) {
        decoder?.newCharacter(string, length: length, wordSpacing: spacing)
    }

    @objc(interWord)
    func interWord() -> Int32 {
        return Int32(elementLength * 6)
    }

    //  A new Morse element is determined from the state (keyed or unkeyed) and duration (in units of 0.74 ms).
    func updateDeglitchedMorseElement(_ element: UnsafeMutablePointer<ElementType>, pipe: CWPipeline?) {
        var string = [CChar](repeating: 0, count: 32)
        var keyInterval = [Float](repeating: 0, count: 32)
        var keyCount = 0
        var lastUnkeyElement: Int32 = 0

        let longElement = Int32(elementLength * 2.0)

        intervalBuffer[Int(intervalProducer)] = element.pointee
        intervalProducer = (intervalProducer &+ 1) & 0x1f

        //  find how many elements have not yet been processed
        var n = intervalProducer - intervalConsumer
        if n < 0 { n += MAXINTERVALBUF }

        // v0.33 flush word, and add low latency
        if n < 10 && latency > 1 {      //  wait for at least 10 element-pairs before processing
            let flush = (element.pointee.state == 0) && (element.pointee.interval > longElement * 3 / 4)
            if !flush { return }
        }

        // now check for any long unkeyed element that has not been consumed
        keyCount = 0
        var k = intervalConsumer

        while true {
            if k == intervalProducer { return }         //  did not find an intercharacter or interword element

            let e = intervalBuffer[Int(k)]
            k = (k &+ 1) & 0x1f

            if e.state == 0 {
                lastUnkeyElement = e.interval
                if lastUnkeyElement > longElement {
                    if keyCount <= 0 {
                        //  no keyed element... output a space if it has not already been emited
                        if !spacePrinted { newCharacter("", length: 0, wordSpacing: 1) }
                        spacePrinted = true
                        //  long unkeyed element received with no keyed element, toss the interval
                        intervalConsumer = k
                        return
                    }
                    while intervalBuffer[Int(k)].state == 0 {
                        if k == intervalProducer { return }     //  did not find an intercharacter or interword element
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
        if keyCount <= 0 { return }                     //  end of character not seen

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
            string[i] = (keyInterval[i] < v) ? 0x2e /* '.' */ : 0x2d /* '-' */
        }
        string[keyCount] = 0

        //  character retrieved, update the consumer pointer
        intervalConsumer = k
        spacePrinted = (lastUnkeyElement > wordInterval)
        newCharacter(&string, length: Int32(keyCount), wordSpacing: Int32(spacePrinted ? 1 : 0))
    }

    //  callback from CWPipeline when a new Morse element is determined
    @objc(updateMorseElement:pipe:)
    func updateMorseElement(_ element: UnsafeMutablePointer<ElementType>?, pipe: CWPipeline) {
        guard let element = element else { return }
        if pipe !== decodePipeline || element.pointee.interval == 0 { return }

        //  v0.33 -- `if ( 1 || latency == 0 )` is always true; the glitch-filter
        //  branch that followed it is unreachable and is not ported.
        updateDeglitchedMorseElement(element, pipe: pipe)
    }

    @objc(changeCodeSpeedTo:)
    func changeCodeSpeed(to speed: Int32) {
        chosenSpeed = speed
        if speed <= 0 { return }
        //  if it is not auto speed, set matched filters for the chosen speed
        changeMatchedFilterToSpeed(Float(speed) * 1.0, force: true)
    }

    @objc(setLatency:)
    func setLatency(_ value: Int32) {
        latency = value
    }

    //  pick a matched filter for the code speed
    @objc(changeMatchedFilterToSpeed:force:)
    func changeMatchedFilterToSpeed(_ speed: Float, force forced: Bool) {
        if !forced && abs(estimatedSpeed - speed) < 0.25 { return }

        estimatedSpeed = speed
        decodePipeline?.updateFilter(Int32(331 * 0.85 * 5.0 / Double(estimatedSpeed)))
    }

    @objc(setDecoder:receiver:)
    func setDecoder(_ client: MorseDecoder?, receiver rx: CWReceiver?) {
        decoder = client
        receiver = rx
    }

    @objc(setSquelch:fastQSB:slowQSB:)
    func setSquelch(_ db: Float, fastQSB: Float, slowQSB: Float) {
        decodePipeline?.setSquelch(db, fastQSB: fastQSB, slowQSB: slowQSB)
        speedPipeline?.setSquelch(db, fastQSB: fastQSB, slowQSB: slowQSB)
    }

    @objc(elementLength)
    func elementLengthValue() -> Int32 {
        return Int32(elementLength)
    }
}
