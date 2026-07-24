//
//  RTTYATC.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 2/27/07.
//
//  Swift port of RTTYATC.m.  A CMATC variant that additionally copies the AGC
//  streams into a long (approx 6 second) double ring buffer for experimental
//  ring-based decoding.  NOTE (from the original): "this is not currently used,
//  see CMATC.h" -- the ring scan (scanRingForSync) always returns false, so the
//  HASSYNC path and extractCharacterFromRing never execute.
//
//  The character-decoding overrides (checkForCharacter / exportCharacter /
//  decodeCharacterFrom / scanForBadTransitions) in the C file were byte-identical
//  to CMATC's and unreachable from -importData, so they are inherited here rather
//  than duplicated.  The CMATCRing struct only ever used its data[] member, so the
//  ring is stored as three plain CMATCPair buffers.
//

import Cocoa

private let ATCRINGMASK: Int = 0x1fff
private let ATCRINGSIZE: Int = ATCRINGMASK + 1
private let HASSYNC: Int32 = 0x1
private let HASSPACE: Int32 = 0x2

@objc(RTTYATC)
class RTTYATC: CMATC {

    internal var characterPeriod: Float = 0
    internal var fixedCharacterAdvance: Int32 = 0
    internal var firstStopBit: Int32 = 0

    //  three ring buffers (each ATCRINGSIZE*2 long: ring + its trailing copy)
    private var ring: [UnsafeMutablePointer<CMATCPair>] = []
    internal var producer: Int64 = 0
    internal var consumer: Int64 = 0
    internal var decodeConsumer: Int64 = 0
    internal var ringState: Int32 = 0

    private func ringData(_ i: Int) -> UnsafeMutablePointer<CMATCPair> { return ring[i] }

    @objc override init() {
        ring = (0..<3).map { _ -> UnsafeMutablePointer<CMATCPair> in
            let p = UnsafeMutablePointer<CMATCPair>.allocate(capacity: ATCRINGSIZE * 2)
            p.initialize(repeating: CMATCPair(), count: ATCRINGSIZE * 2)
            return p
        }
        super.init()
        producer = 0
        consumer = 0
        decodeConsumer = 0
        ringState = 0
    }

    deinit {
        for p in ring { p.deallocate() }
    }

    //  compute an offset start/stop bit
    override func setBitSampling(fromBaudRate baudrate: Float) {
        super.setBitSampling(fromBaudRate: baudrate)
        characterPeriod = Float(Double(bitTime) * (Double(bitsPerCharacter) + 2.5))
        fixedCharacterAdvance = Int32(characterPeriod)
        firstStopBit = Int32(Double(bitTime) * (Double(bitsPerCharacter) + 1.5))
    }

    //  previous sync position is at "offset" (a float)
    func extractCharacterFromRing() {
        //  original body is entirely under #ifdef LATER -- no-op
    }

    //  Check the ring buffer from startIndex for a start bit; return the index,
    //  or -1 if not found (currently unreachable dead code).
    func findSync(_ ringData: UnsafeMutablePointer<CMATCPair>, start startIndex0: Int64, available available0: Int) -> Int64 {
        var startIndex = startIndex0
        var available = available0
        var bestIndex = 0

        var i = 0
        while i < available {
            let startOffset = Int(startIndex) + i
            let r = ringData + (startOffset & ATCRINGMASK)
            let start = r[Int(startBit)].mark - r[Int(startBit)].space
            if start < 0 {
                var stop = r[Int(stopBit)].mark - r[Int(stopBit)].space
                if stop > 0 {
                    stop = r[Int(firstStopBit)].mark - r[Int(firstStopBit)].space
                    if stop > 0 {
                        //  found potential character start, now fine tune
                        if i == 0 {
                            startIndex += Int64(ATCRINGSIZE) + 16
                            available += 16
                        } else {
                            available = available - i + 16
                        }
                        if available > 32 { available = 32 }

                        var best = r[Int(firstStopBit)].mark - r[Int(firstStopBit)].space + r[Int(stopBit)].mark - r[Int(stopBit)].space - r[Int(startBit)].mark + r[Int(startBit)].space
                        bestIndex = startOffset

                        var ii = 0
                        while ii < available {
                            let so = Int(startIndex) + ii
                            let rr = ringData + (so & ATCRINGMASK)
                            let st = rr[Int(startBit)].mark - rr[Int(startBit)].space
                            if st < 0 {
                                let sp = rr[Int(stopBit)].mark - rr[Int(stopBit)].space
                                if sp > 0 {
                                    let test = rr[Int(firstStopBit)].mark - rr[Int(firstStopBit)].space + rr[Int(stopBit)].mark - rr[Int(stopBit)].space - rr[Int(startBit)].mark + rr[Int(startBit)].space
                                    if test > best { best = test; bestIndex = so }
                                }
                            }
                            ii += 1
                        }
                        return Int64(bestIndex)
                    }
                }
            }
            i += 1
        }
        return -1
    }

    //  Look for a potential start-stop (currently always fails).
    @objc(scanRingForSync:)
    func scanRingForSync(_ startingPosition: Int32) -> Bool {
        return false
    }

    //  NOTE: sampling rate here is Fs/8, 256 samples per frame.
    override func importData(_ pipe: CMPipe!) {
        let stream = pipe.stream()
        bitStreamPtr.pointee.sourceID = stream!.pointee.sourceID
        var samples = Int(stream!.pointee.samples)
        if samples > 256 { samples = 256 }

        var m: UnsafeMutablePointer<Float>
        var s: UnsafeMutablePointer<Float>
        if invert {
            s = stream!.pointee.array!
            m = stream!.pointee.array! + samples
        } else {
            m = stream!.pointee.array!
            s = stream!.pointee.array! + samples
        }

        //  copy input data into tail of buffer (split complex -> ATCpair)
        var p = inputData + 512
        for _ in 0..<256 {
            p.pointee.mark = m.pointee; m += 1
            p.pointee.space = s.pointee; s += 1
            p += 1
        }

        //  AGC streams
        updateAGC(input, agc + 0)
        updateAGC(input, agc + 1)
        updateAGC(input, agc + 2)

        (atcBuffer as? CMATCBuffer)?.atcData(agc + 2)

        //  move tail to head of buffers
        let size = MemoryLayout<CMATCPair>.size * 512
        memcpy(inputData, inputData + 256, size)
        for i in 0..<3 { memcpy(agcData(i), agcData(i) + 256, size) }

        //  copy the AGC buffers into the double ring buffers
        let rsize = MemoryLayout<CMATCPair>.size * samples
        let base = Int(producer & Int64(ATCRINGMASK))
        for i in 0..<3 {
            memcpy(ringData(i) + base, agcData(i), rsize)
            memcpy(ringData(i) + base + ATCRINGSIZE, agcData(i), rsize)
        }
        producer = producer + Int64(samples)

        if (ringState & HASSYNC) == 0 {
            print("consumer at \(Int(consumer)) starting to scan for sync")

            let limit = Int32(Float(producer - decodeConsumer) - characterPeriod * 4)

            //  check for sync through available ring samples
            var i: Int32 = 0
            while i < limit {
                if scanRingForSync(Int32(decodeConsumer + Int64(i))) { break }
                i += 8
            }
        }

        if (ringState & HASSYNC) != 0 {
            extractCharacterFromRing()
        }
    }
}
