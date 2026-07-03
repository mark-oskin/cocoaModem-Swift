//
//  MultiStereoATC.swift
//  cocoaModem
//
//  Created by Kok Chen on 2/25/05.
//
//  Swift port of MultiStereoATC.m.  A CMATC that derives clocking from an
//  independent (reference) channel: the DUT stream calls -importData, then the
//  reference stream calls -importClockData.  The heavy lifting is done by two
//  Swift RTTYDecoders (dut, ref); this class performs the sync balancing and
//  error accounting via AnalyzeConfig / AnalyzeScope.
//

import Cocoa

private let hammingWeight: [Int32] = [
    0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4,
    1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5
]

@objc(MultiStereoATC)
class MultiStereoATC: CMATC {

    internal var config: AnalyzeConfig?
    internal var scope: AnalyzeScope?

    internal var dut: RTTYDecoder!
    internal var ref: RTTYDecoder!

    internal let atcDummyData = UnsafeMutablePointer<CMATCPair>.allocate(capacity: 256)

    internal var refSync = RTTYByte()
    internal var dutSync = RTTYByte()
    internal var dutStartBitSearch: Int = 0
    internal var refStartBitSearch: Int = 0
    internal var dutSyncOffset: Int = 0
    internal var refSyncOffset: Int = 0
    internal var tickDiff: Int = 0
    internal var balance: Int = 0
    internal var savedByte: Int = 0
    internal var characterCount: Int = 0
    internal var estimate: Float = 0

    private static var lastSync: Int = 0

    //  reusable scope buffers (were stack arrays in the C code)
    private let refPairBuf = UnsafeMutablePointer<CMATCPair>.allocate(capacity: 256)
    private let dutPairBuf = UnsafeMutablePointer<CMATCPair>.allocate(capacity: 256)
    private let projPairBuf = UnsafeMutablePointer<CMATCPair>.allocate(capacity: 256)

    @objc override init() {
        super.init()
        config = nil
        scope = nil
        dut = RTTYDecoder(bitPeriod: 22.0)
        ref = RTTYDecoder(bitPeriod: 22.0)
        dutStartBitSearch = 0; refStartBitSearch = 0
        dutSyncOffset = 0; refSyncOffset = 0
        tickDiff = 0; balance = 0
        estimate = 15.0
        characterCount = 0
        atcDummyData.initialize(repeating: CMATCPair(), count: 256)
    }

    deinit {
        atcDummyData.deallocate()
        refPairBuf.deallocate()
        dutPairBuf.deallocate()
        projPairBuf.deallocate()
    }

    @objc(setConfigClient:)
    func setConfigClient(_ cfg: AnalyzeConfig?) {
        config = cfg
    }

    @objc(setScope:)
    func setScope(_ ascope: AnalyzeScope?) {
        scope = ascope
    }

    //  the DUT stream calls this point; afterwards the reference stream calls importClockData
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
        dut.addSamples(Int32(samples), mark: m, space: s)
    }

    @objc(importClockData:)
    func importClockData(_ pipe: CMTappedPipe!) {
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
        ref.addSamples(Int32(samples), mark: m, space: s)
        checkForCharacter()
    }

    override func checkForCharacter() {
        var checkSync = RTTYByte()
        var dataByte: Int

        for _ in 0..<256 {
            tickDiff += 1
            refSync.tick += 1
            dutSync.tick += 1
            dutStartBitSearch -= 1
            refStartBitSearch -= 1

            dutSyncOffset -= 1
            refSyncOffset -= 1

            //  first check if we have a sync in the dut channel
            if dutStartBitSearch <= 0 {

                dut.validateSyncForMarkOffset(0, spaceOffset: 0, sync: &dutSync)

                if dutSync.confidence > 0.4 {
                    //  strong sync
                } else {
                    dut.bestAsyncForMarkOffset(5, spaceOffset: 5, sync: &dutSync)
                }

                dut.checkSyncForMarkOffset(0, spaceOffset: 0, sync: &checkSync)
                if checkSync.frameSync.boolValue && checkSync.confidence > 0.66 {
                    config?.setSyncState(2)
                } else {
                    config?.setSyncState(0)
                }

                if dutSync.frameSync.boolValue && dutSync.confidence > 0.66 {
                    MultiStereoATC.lastSync = dutSync.tick + Int(dutSync.offset)
                    //  fetch data
                    dutSyncOffset = Int(dutSync.offset)
                    dutSync.syncTick = Int(dutSync.offset) + dutSync.tick
                    dutStartBitSearch = 196 + dutSyncOffset
                    dataByte = 0
                    let atc = (dut.mark().agcAtOffset(Int32(dutSyncOffset)) - dut.space().agcAtOffset(Int32(dutSyncOffset))) * 0.5
                    var j = 4
                    while j >= 0 {
                        let bit = ((dut.markAtBit(Int32(j), offset: Int32(dutSyncOffset)) - dut.spaceAtBit(Int32(j), offset: Int32(dutSyncOffset)) - atc) > 0) ? 1 : 0
                        dataByte = (dataByte << 1) + bit
                        j -= 1
                    }

                    var tSync = RTTYByte()
                    dut.bestAsyncForMarkOffset(Int32(dutSyncOffset - 8), spaceOffset: Int32(dutSyncOffset - 8), sync: &tSync)

                    characterCount += 1
                    exportCharacter(Int32(dataByte), buffer: atcDummyData)

                    if scope != nil {
                        ref.getBuffer(refPairBuf, markOffset: Int32(refSyncOffset), spaceOffset: Int32(refSyncOffset))
                        scope?.addReference(refPairBuf)
                        dut.getBuffer(dutPairBuf, markOffset: Int32(dutSyncOffset), spaceOffset: Int32(dutSyncOffset))
                        scope?.addDUT(dutPairBuf)
                        dut.getBuffer(projPairBuf, markOffset: Int32(dutSyncOffset), spaceOffset: Int32(dutSyncOffset))
                        scope?.addCompensated(projPairBuf)
                    }
                    if balance == 0 {
                        tickDiff = 0
                        balance = 1
                        savedByte = dataByte
                    } else {
                        if balance > 0 {
                            config?.frameError(1)       // two dut syncs in a row
                            tickDiff = 0
                            balance = 1
                            savedByte = dataByte
                        } else {
                            if tickDiff < 30 {
                                balance = 0
                                config?.accumBits(5)
                                if savedByte != dataByte {
                                    exportCharacter(-1, buffer: atcDummyData)
                                    config?.accumErrorBits(hammingWeight[(savedByte ^ dataByte) & 0x1f])
                                }
                            } else {
                                config?.frameError(2)   // missed dut sync
                                tickDiff = 0
                                balance = 1
                                savedByte = dataByte
                            }
                        }
                    }
                }
            }

            //  now check if we have a sync in the ref channel
            if refStartBitSearch <= 0 {
                ref.bestAsyncForMarkOffset(0, spaceOffset: 0, sync: &refSync)
                if refSync.frameSync.boolValue && refSync.confidence > 0.5 {
                    //  fetch data
                    refSyncOffset = Int(refSync.offset)
                    refSync.syncTick = refSync.tick
                    refSync.tick = 0
                    refStartBitSearch = 192 + refSyncOffset
                    dataByte = 0
                    var j = 4
                    while j >= 0 {
                        let bit = ((ref.markAtBit(Int32(j), offset: Int32(refSyncOffset)) - ref.spaceAtBit(Int32(j), offset: Int32(refSyncOffset))) > 0) ? 1 : 0
                        dataByte = (dataByte << 1) + bit
                        j -= 1
                    }
                    if balance == 0 {
                        tickDiff = 0
                        balance = -1
                        savedByte = dataByte
                    } else {
                        if balance < 0 {
                            config?.frameError(3)       // two ref syncs in a row
                            tickDiff = 0
                            balance = -1
                            savedByte = dataByte
                        } else {
                            if tickDiff < 30 {
                                balance = 0
                                config?.accumBits(5)
                                if savedByte != dataByte {
                                    exportCharacter(-1, buffer: atcDummyData)
                                    config?.accumErrorBits(hammingWeight[(savedByte ^ dataByte) & 0x1f])
                                }
                            } else {
                                config?.frameError(4)   // extra dut sync
                                tickDiff = 0
                                balance = -1
                                savedByte = dataByte
                            }
                        }
                    }
                }
            }
            ref.advance()
            dut.advance()
        }
    }
}
