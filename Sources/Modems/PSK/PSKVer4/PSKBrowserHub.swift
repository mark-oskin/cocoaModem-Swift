//
//  PSKBrowserHub.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 10/26/08.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//  Swift port of PSKBrowserHub.m.  (Slot/Row C structs live in
//  PSKBrowserTypes.h so they can be shared with the Swift PSKBrowserTable.)
//
//  Buffer notes: the big / pointer-shared buffers keep the exact C sizes and are
//  UnsafeMutablePointers freed in deinit -- liteBuffer[512*64], spectrum[4096],
//  peak[1000] and jisToUnicode[65536*2].  The small work arrays inside
//  inspectBrowserSpectrum stay Swift arrays with the original fixed sizes.
//
//  Ownership note: LinkedArray keeps its objects UNRETAINED (matching the original
//  MRC design).  The created LitePSKDemodulators are therefore held strongly here
//  in `allDemodulators` (never removed) so their opaque pointers stay valid, exactly
//  as the original relied on the +1 alloc that was never released.
//

import Cocoa

//  PSKBrowserTable implements the (informal) NSTableView data-source / delegate
//  @objc methods but does not itself declare the conformances; declare them here so
//  the table's dataSource / delegate can be assigned from Swift.
extension PSKBrowserTable: NSTableViewDataSource {}
extension PSKBrowserTable: NSTableViewDelegate {}

@objc(PSKBrowserHub)
class PSKBrowserHub: PSKHub, NSWindowDelegate {

    //  LitePSKDemodulator userIndex errors
    private static let FREQOUTOFRANGE: Int32 = -3
    private static let LOWERROWBUSY: Int32 = -4
    private static let UPPERROWBUSY: Int32 = -5
    private static let SLOTINUSE: Int32 = -6
    private static let TOOCLOSETONEIGHBOR: Int32 = -7

    //  mini-click buffer, used to accumulate 32,768 samples (4.096 seconds) for spectrum
    private let liteBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 512 * 64)
    private var bufferIndex: Int32 = 0          //  index into 64 512-sample segments of the liteBuffer
    private var currentID: Int32 = 0
    private var scanIndex: Int32 = 0            //  v0.97

    //  TableView LitePSKDemodulators
    private var sortedDemodulators: LinkedArray!
    private var idleDemodulators: LinkedArray!
    private var removedDemodulators: LinkedArray!
    private var demodBusy: NSLock!
    private var pskBrowserSkipBuffer: NSLock!
    //  strong owner of every demodulator created (LinkedArray holds them unretained)
    private var allDemodulators: [LitePSKDemodulator] = []

    //  multi-PSK demodulators
    private var skipMultipleDemodulators: Bool = true
    private var savedSkipMultipleDemodulators: Bool = true   //  save between visible and non-visible interface
    private var squelch: Float = 0

    //  browser view
    private var table: NSTableView!
    private var browserTable: PSKBrowserTable!
    private var refreshedRow: Int32 = 0
    private var started: Bool = false

    private let peak = UnsafeMutablePointer<Float>.allocate(capacity: 1000)
    private let spectrum = UnsafeMutablePointer<Float>.allocate(capacity: 4096)  //  4096 == 4000 Hz

    //  fft
    private var fft: UnsafeMutablePointer<CMFFT>!

    //  v0.70
    private var useShiftJIS_: Bool = false
    //  unsigned char jisToUnicode[65536*2]
    private let jisToUnicode = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536 * 2)

    private var mainThread: Thread!
    private var debugPrint: Bool = false

    //  C truncated (finite) float->int toward zero; guard NaN/inf (see DisplayColor.cInt).
    private func cInt(_ x: Float) -> Int32 {
        if !x.isFinite { return 0 }
        if x >= 2147483647.0 { return Int32.max }
        if x <= -2147483648.0 { return Int32.min }
        return Int32(x)
    }

    //  ------------------------------------------------------------------------
    //  Minimal designated initializer.  Allocates the C buffers so deinit is always
    //  valid; -initHub fills in the values.
    override init() {
        super.init()
        liteBuffer.initialize(repeating: 0, count: 512 * 64)
        spectrum.initialize(repeating: 0, count: 4096)
        peak.initialize(repeating: 0, count: 1000)
        jisToUnicode.initialize(repeating: 0, count: 65536 * 2)
    }

    //  Mirrors -[PSKBrowserHub initHub], which calls [super init] (NOT [super
    //  initHub]) and then does its own setup.  The @objc(initHub) selector is
    //  preserved exactly and overrides PSKHub's.
    @objc(initHub) override convenience init(hub: ()) {
        self.init()

        useShiftJIS_ = false            // v0.70
        mainThread = Thread.current
        demodBusy = NSLock()
        pskBrowserSkipBuffer = NSLock()
        dataPipe = DataPipe(capacity: Int32(2048 * MemoryLayout<Float>.size))
        setupResampler()
        bufferIndex = 0
        receiver = nil
        table = nil
        currentID = 0
        scanIndex = 0
        hasBrowser = true
        enabled = false
        squelch = Float((1.0 - 0.8) * 0.75 + 0.25)
        debugPrint = false
        refreshedRow = 0
        started = false
        savedSkipMultipleDemodulators = true
        skipMultipleDemodulators = true

        //  TableView demodulators (sorted by frequency)
        sortedDemodulators = LinkedArray(capacity: 64, ident: "demods")
        idleDemodulators = LinkedArray(capacity: 64, ident: "idle")
        removedDemodulators = LinkedArray(capacity: 64, ident: "removed")
        for i in 0..<1000 { peak[i] = 0.001 }

        //  create some demodulators; this can grow later
        for _ in 0..<16 {
            let demod = LitePSKDemodulator(client: self, uniqueID: currentID)
            currentID += 1
            allDemodulators.append(demod)
            idleDemodulators.addObject(demod)
        }
        //  spectrum for signal capture.
        //  sampling rate is 8000 samples/sec, each bin is 0.9765 Hz wide.
        fft = FFTSpectrum(13, true)
    }

    deinit {
        if let sorted = sortedDemodulators {
            let count = sorted.count()
            for i in 0..<count {
                if let demod = sorted.object(at: i) as? LitePSKDemodulator {
                    _ = releaseDemodulator(demod)
                }
            }
        }
        if let fft = fft { CMDeleteFFT(fft) }
        liteBuffer.deallocate()
        spectrum.deallocate()
        peak.deallocate()
        jisToUnicode.deallocate()
    }

    //  don't really release it, simply make it idle and place it in the idleDemodulator list
    private func releaseDemodulator(_ demod: LitePSKDemodulator) -> Int32 {
        let result = demod.setToIdle()
        idleDemodulators.addObject(demod)
        return result
    }

    //  check first to see if already have a demodulator in the idle list and use that
    private func allocDemodulator() -> LitePSKDemodulator {
        while idleDemodulators.count() > 0 {
            guard let demod = idleDemodulators.object(at: 0) as? LitePSKDemodulator else { break }
            idleDemodulators.removeObject(at: 0)
            //  sanity check v0.58 -- check to make sure demod is not in use
            if sortedDemodulators.indexOfObject(demod) < 0 { return demod }
            // keep trying to find a demodulator that is not already used!
            NSLog("cocoaModem PSK TableView: demodulator exists in both idle and sorted linked lists.\n")
        }
        let demod = LitePSKDemodulator(client: self, uniqueID: currentID)
        currentID += 1
        allDemodulators.append(demod)
        return demod
    }

    @objc(useControlButton:)
    func useControlButton(_ state: DarwinBoolean) {
        (table as? ClickedTableView)?.useControlButton(state)
    }

    private func activateDemodulator(_ demod: LitePSKDemodulator, frequency tone: Float) {
        demod.activateWithFrequency(tone)
    }

    private func allocAndActivateDemodulator(at tone: Float) -> LitePSKDemodulator {
        let demod = allocDemodulator()
        demod.activateWithFrequency(tone)
        return demod
    }

    @objc(setBrowserTable:)
    func setBrowserTable(_ view: NSTableView?) {
        table = view
        if let view = view {
            //  create data source for TableView
            browserTable = PSKBrowserTable(table: view, client: self)
            view.dataSource = browserTable
            view.delegate = browserTable
        }
    }

    @objc(enableReceiver:)
    override func enableReceiver(_ state: Bool) {
        enabled = state
    }

    @objc(tableViewSelectedTone:option:)
    func tableViewSelectedTone(_ tone: Float, option: Bool) {
        let rx: PSKReceiver?

        if option {
            let modem = receiver?.controlModem()
            rx = modem?.receiver(1)
            if rx == nil { return }
        } else {
            rx = receiver
        }

        rx?.selectFrequency(tone, secondsAgo: 15, fromWaterfall: false)
        rx?.setTransmitFrequencyToTone(tone)
        rx?.setFrequencyDefined()
    }

    @objc func inspectBrowserSpectrum() {
        var target = [Float](repeating: 0, count: 2600)
        var rawTones = [Float](repeating: 0, count: 22)
        var tones = [Float](repeating: 0, count: 22)
        var filteredTones = [Float](repeating: 0, count: 22)
        var hamming = [Float](repeating: 0, count: 2600)
        var weighted = [Float](repeating: 0, count: 2600)
        var sym = [Float](repeating: 0, count: 2600)

        //  Apply Hamming window to spectrum
        for i in 300..<2600 {
            hamming[i] = spectrum[i - 1] + 2.34 * spectrum[i] + spectrum[i + 1]
        }

        //  Look for symmetrical structure
        for i in 320..<2570 {
            var sum: Float = 0
            for j in 4..<16 {
                sum += (hamming[i - j] * hamming[i + j]) / sqrtf(hamming[i - j] * hamming[i - j] + hamming[i + j] * hamming[i + j])
            }
            sym[i] = sum
        }
        //  find weighted estimate
        for i in 340..<2550 {
            var sum: Float = 0
            for j in 3..<15 {
                sum += (sym[i - j] + sym[i + j])
            }
            let mean = sum / 28
            weighted[i] = (sym[i] - mean) / mean * sqrtf(hamming[i])
        }
        //  find weighted estimate
        //  A pure carrier produces a negative response, a random BPSK31 signal produces
        //  a symmetrical response with a sharp peak
        for i in 350..<2540 {
            target[i] = weighted[i - 1] + 1.34 * weighted[i] + weighted[i + 1]
        }
        var toneCount = 0

        //  find peaks
        var i = 380
        while i < 2505 {
            if target[i] > (181.0 + squelch * 500.0) {
                //  found potential target; look for local peak
                var maxv = target[i]
                var maxpos = 0
                for j in 1..<28 {
                    let k = i + j
                    let test = target[k]
                    if test > maxv { maxv = test; maxpos = j }
                }
                //  try alternate peaks up to 35 bins ahead, in case we'd locked on a sideband
                for j in (maxpos + 14)..<(maxpos + 35) {
                    let k = i + j
                    let test = target[k]
                    if test > maxv { maxv = test; maxpos = j }
                }
                //  refine tone (near maxpos)
                var mean: Float = 0
                var denom: Float = 0.0001
                maxpos += i
                if maxpos < 2500 {
                    for j in (maxpos - 4)...(maxpos + 4) {
                        let test = target[j]
                        mean += Float(j) * test
                        denom += test
                    }
                    let tone = (mean / denom) * (8000.0 / 8192.0)
                    rawTones[toneCount] = tone
                    tones[toneCount] = tone
                    toneCount += 1
                    if toneCount > 21 { toneCount = 21 }     //  stop collecting after 21 of them!
                }
                i = maxpos + 60
            }
            i += 1
        }
        //  At this point, we have found tones in spectrum.
        //  We now need to associate any tones with existing demodulators.

        //  But first, we remove repeated demodulators (or demodulators that are too
        //  close to one another in frequency)
        var demodCount = Int(sortedDemodulators.count())
        if demodCount > 1 {
            var demod = sortedDemodulators.object(at: 0) as? LitePSKDemodulator
            var prevFreq = demod?.frequency() ?? 0
            for _ in 1..<demodCount {
                demod = sortedDemodulators.nextObject() as? LitePSKDemodulator
                let freq = demod?.frequency() ?? 0
                if fabsf(prevFreq - freq) < 30 {
                    //  v0.58 check to make sure the demodulator is not already in the list
                    if let d = demod, removedDemodulators.indexOfObject(d) < 0 { removedDemodulators.addObject(d) }
                }
                prevFreq = freq
            }
        }
        //  Next we check the frequency order of demodulators (sanity check and drifting signal)
        demodCount = Int(sortedDemodulators.count())
        if demodCount > 1 {
            var prevDemod = sortedDemodulators.object(at: 0) as? LitePSKDemodulator
            var prevFreq = prevDemod?.frequency() ?? 0
            for i in 1..<demodCount {
                let demod = sortedDemodulators.nextObject() as? LitePSKDemodulator
                let freq = demod?.frequency() ?? 0
                if freq < prevFreq {
                    //  swap elements
                    sortedDemodulators.increaseIndexOfObject(at: Int32(i - 1))
                    break
                }
                prevFreq = freq
                prevDemod = demod
            }
        }
        //  We next identify the tones that correspond to existing demodulators, and
        //  remove the tones that already have demodulators.  We also try to AFC the
        //  frequency of the demodulators to the tones that we have found a match.
        demodCount = Int(sortedDemodulators.count())
        for idx in 0..<demodCount {
            let demod = (idx == 0)
                ? sortedDemodulators.object(at: 0) as? LitePSKDemodulator
                : sortedDemodulators.nextObject() as? LitePSKDemodulator
            demod?.setMark(1)
            let freq = demod?.frequency() ?? 0
            for j in 0..<toneCount {
                let tone = tones[j]
                if fabsf(tone - freq) < 32 {
                    //  found a match, do an afc
                    demod?.afcToFrequency(tone)
                    demod?.setMark(0)                   //  do not remove
                    //  now disable the tone from further searches
                    tones[j] = 0
                    break
                }
            }
        }
        //  Now start/continue the process of removing the demodulators that no longer
        //  have a tone in the spectrum.  When the remove count has reached the limit,
        //  remove the demod object.
        var prevFreq: Float = 0
        demodCount = Int(sortedDemodulators.count())
        var di = 0
        while di < demodCount {
            guard let demod = sortedDemodulators.object(at: Int32(di)) as? LitePSKDemodulator else { di += 1; continue }
            let freq = demod.frequency()
            if demod.mark() == 1 {
                let removeCount = demod.increaseRemoveCount()
                var limit: Int32 = 12

                //  demodulator frequency no longer found in tone list, remove faster if
                //  it is close in frequency to other demodulators
                if fabsf(prevFreq - freq) < 64 {
                    limit = 6
                } else {
                    if (di + 1) < demodCount {
                        prevFreq = (sortedDemodulators.object(at: Int32(di + 1)) as? LitePSKDemodulator)?.frequency() ?? 0
                        if fabsf(prevFreq - freq) < 64 { limit = 6 }
                    }
                }
                if removeCount > limit {
                    //  demodulator has timed out
                    //  v0.58 check to be sure the demodulator is not already in the removal list
                    if removedDemodulators.indexOfObject(demod) < 0 { removedDemodulators.addObject(demod) }
                    demodCount -= 1
                }
            }
            prevFreq = freq
            di += 1
        }
        //  create a clean tone list
        var filteredToneCount = 0
        for i in 0..<toneCount {
            let tone = tones[i]
            if tone >= 380 && tone <= 2500 {
                filteredTones[filteredToneCount] = tone
                filteredToneCount += 1
            }
        }

        if debugPrint {
            print("----")
            if toneCount > 0 {
                print(String(format: "filteredToneCount %d   All tones (%d):", filteredToneCount, toneCount))
                var line = ""
                for i in 0..<toneCount { line += String(format: " %.0f(%.0f)", rawTones[i], tones[i]) }
                print(line)
            }
            demodCount = Int(sortedDemodulators.count())
            if demodCount > 0 {
                print(String(format: "Active demodulators: %d (slot,row)", demodCount))
                var line = ""
                for i in 0..<demodCount {
                    if let demod = sortedDemodulators.object(at: Int32(i)) as? LitePSKDemodulator {
                        let demodSlot = demod.userIndex()
                        line += String(format: " %.0f (%d,%d) ", demod.frequency(), demodSlot, browserTable.rowForSlot(demodSlot))
                    }
                }
                print(line)
            }
            debugPrint = false
        }

        if filteredToneCount <= 0 { return }        //  no new tones found

        for i in 0..<filteredToneCount {
            let tone = filteredTones[i]
            demodCount = Int(sortedDemodulators.count())
            if demodCount == 0 {
                let demod = allocAndActivateDemodulator(at: tone)
                sortedDemodulators.addObject(demod)
            } else {
                var freq = (sortedDemodulators.object(at: 0) as? LitePSKDemodulator)?.frequency() ?? 0
                for j in 0..<demodCount {
                    if freq > tone {
                        let demod = allocAndActivateDemodulator(at: tone)
                        sortedDemodulators.insertObject(demod, at: Int32(j))
                        break
                    }
                    let prevDemod = sortedDemodulators.nextObject() as? LitePSKDemodulator
                    if prevDemod == nil {
                        let demod = allocAndActivateDemodulator(at: tone)
                        sortedDemodulators.addObject(demod)
                        break
                    }
                    freq = prevDemod?.frequency() ?? 0
                }
            }
        }
    }

    //  New resampled data buffer (at 8000 s/s) arrives from the readThread (see base class).
    //  v0.66 place inside lock
    private func lockedSendBufferToDemodulators(_ buffer: UnsafeMutablePointer<Float>, samples: Int32) {
        assert(samples == 512)

        if skipMultipleDemodulators { return }

        let currentIndex = bufferIndex
        let currentBuf = liteBuffer + Int(currentIndex) * 512
        memcpy(currentBuf, buffer, 512 * MemoryLayout<Float>.size)
        bufferIndex = (bufferIndex + 1) % 64

        switch bufferIndex & 0xf {
        case 0:
            //  process FFT every 8192 samples
            //  NOTE: the original assembles a local fftbuf here but then performs the
            //  FFT on liteBuffer (fftbuf is unused); preserved for fidelity.
            var fftbuf = [Float](repeating: 0, count: 8192)
            fftbuf.withUnsafeMutableBufferPointer { fb in
                var j = Int((bufferIndex - 16 + 64) % 64)
                for i in 0..<16 {
                    memcpy(fb.baseAddress! + i * 512, liteBuffer + j * 512, 512 * MemoryLayout<Float>.size)
                    j = (j + 1) % 64
                }
            }
            CMPerformFFT(fft, liteBuffer, spectrum)
        case 4:
            if demodBusy.try() {
                poolBusy?.lock()
                if Thread.current == mainThread {
                    inspectBrowserSpectrum()
                } else {
                    //  inspect spectrum only if not busy, this way sortedDemodulators is locked
                    performSelector(onMainThread: #selector(inspectBrowserSpectrum), with: nil, waitUntilDone: true)
                }
                poolBusy?.unlock()
                demodBusy.unlock()
            }
            started = true
        case 8:
            //  periodically refresh a row of the browser to get rid of orphaned rows
            refreshedRow = (refreshedRow + 1) % 21
            browserTable.checkAndUpdateRow(refreshedRow)
        case 12:
            //  periodically remove disabled demodulators
            demodBusy.lock()
            let count = sortedDemodulators.count()
            if count > 0 {
                var demod = sortedDemodulators.object(at: 0) as? LitePSKDemodulator
                for _ in 0..<count {
                    if let d = demod, d.disabled().boolValue {
                        //  v0.58 check to make sure the demodulator is not already in the removal list
                        if removedDemodulators.indexOfObject(d) < 0 { removedDemodulators.addObject(d) }
                    }
                    demod = sortedDemodulators.nextObject() as? LitePSKDemodulator
                    if demod == nil { break }
                }
            }
            demodBusy.unlock()
        case 14:
            //  periodically check if busy slots have freed up
            demodBusy.lock()
            let count = sortedDemodulators.count()
            if count > 0 {
                //  NOTE: the original never advances `demod` in this loop (it processes
                //  sortedDemodulators[0] `count` times); preserved for fidelity.
                let demod = sortedDemodulators.object(at: 0) as? LitePSKDemodulator
                for _ in 0..<count {
                    if let d = demod, d.userIndex() == PSKBrowserHub.SLOTINUSE {
                        //  check if slot is now available
                        let freq = d.frequency()
                        let slot = Int(cInt((freq - 400) / 50))
                        let sp = browserTable.slot()

                        if sp[slot].row < 0 {
                            //  slot has freed up
                            let targetRow = cInt((freq - 400) / 100)
                            if browserTable.rowIsInUse(targetRow).boolValue == false {
                                browserTable.assignRow(targetRow, toSlot: Int32(slot), frequency: freq)
                                d.setUserIndex(Int32(slot))
                            }
                        }
                    }
                    if demod == nil { break }
                }
            }
            demodBusy.unlock()
        default:
            break
        }
        demodBusy.lock()
        //  remove demodulators that are marked for removal (placed into the
        //  removedDemodulator LinkedArray).
        var count = removedDemodulators.count()
        if count > 0 {
            for i in 0..<count {
                if let demod = removedDemodulators.object(at: i) as? LitePSKDemodulator {
                    //  v0.58 sanity check -- make sure it is in the sortedDemodulator list before removing it
                    if sortedDemodulators.indexOfObject(demod) >= 0 { sortedDemodulators.removeObject(demod) }
                    let slot = releaseDemodulator(demod)
                    if slot >= 0 { browserTable.removeSlot(slot) }
                }
            }
            removedDemodulators.removeAllObjects()
        }

        //  Finally, send the wideband signal to active demodulators for mixing and decoding.
        count = sortedDemodulators.count()
        for i in 0..<count {
            if let demod = sortedDemodulators.object(at: i) as? LitePSKDemodulator {
                demod.decode(liteBuffer, offset: currentIndex)
            }
        }
        demodBusy.unlock()
    }

    @objc(sendBufferToDemodulators:samples:)
    override func sendBufferToDemodulators(_ buffer: UnsafeMutablePointer<Float>, samples: Int32) {
        if pskBrowserSkipBuffer.try() {         //  v0.66  skip buffer if the demodulators are too slow
            lockedSendBufferToDemodulators(buffer, samples: samples)
            pskBrowserSkipBuffer.unlock()
        }
    }

    @objc(testCheck)
    func testCheck() {
        debugPrint = true
    }

    @objc(isEnabled)
    override func isEnabled() -> Bool {
        return true
    }

    //  v0.70
    @objc(setUseShiftJIS:)
    func setUseShiftJIS(_ state: DarwinBoolean) {
        useShiftJIS_ = state.boolValue
    }

    //  v0.70
    @objc(useShiftJIS)
    func useShiftJIS() -> Bool {
        return useShiftJIS_
    }

    //  v0.70
    @objc(setJisToUnicodeTable:)
    func setJisToUnicodeTable(_ uarray: UnsafeMutablePointer<UInt8>) {
        memcpy(jisToUnicode, uarray, 65536 * 2)
    }

    //  -- data path --
    //
    //  importData (data from sound system; send to pipe)
    //      resample proc (convert 11025 to 8000 s/s)
    //          readThread (read from pipe; supply data to resample proc)
    //              sendBufferToDemodulators (send sound buffers to demodulator after resampling)
    //          demodulator:newCharacter (decoded characters callback from demodulator)

    //  ------------------------------------------------------------------------
    //  callbacks from the LitePSKDemodulator
    //  v0.70 input (decoded) can be 16 bit Unicode
    @objc(demodulator:newCharacter:quality:frequency:)
    func demodulator(_ demod: LitePSKDemodulator, newCharacter decode: Int32, quality: Float, frequency freq: Float) {
        let uch: unichar

        if useShiftJIS_ {
            if decode >= 0x813f && decode < 0xfc50 {
                //  convert from shiftJIS to unicode
                let hi = Int(jisToUnicode[Int(decode) * 2])
                let lo = Int(jisToUnicode[Int(decode) * 2 + 1])
                uch = unichar(truncatingIfNeeded: hi * 256 + lo)
            } else {
                //  ASCII range
                if (decode < 32 || decode > 127) && decode != 0x8 { uch = 32 } else { uch = unichar(truncatingIfNeeded: decode) }
            }
        } else {
            //  not in ShiftJIS state
            if (decode < 32 || decode > 127) && decode != 0x8 { uch = 32 } else { uch = unichar(truncatingIfNeeded: decode) }
        }

        let slot = demod.userIndex()

        if quality > squelch * 0.5 && slot >= 0 && slot < 41 {
            //  if carrier is not found, require higher quality to print
            if demod.removeCount() > 4 {
                if quality > squelch { browserTable.addUnicodeCharacter(uch, toSlot: slot, withFrequency: freq) }
            } else {
                browserTable.addUnicodeCharacter(uch, toSlot: slot, withFrequency: freq)
            }
            if quality > (1.0 + squelch) * 0.5 { demod.decreaseRemovalCount(1) }
        }
    }

    @objc(demodulator:startingAtFrequency:)
    func demodulator(_ demod: LitePSKDemodulator, startingAtFrequency freq: Float) {
        var slot = Int(cInt((freq - 400) / 50))

        if slot < 0 || slot > 40 {
            demod.setUserIndex(PSKBrowserHub.FREQOUTOFRANGE)        //  frequency out of range of browser table, not assigned
            return
        }
        let sp = browserTable.slot()
        let slotrow = sp[slot].row
        if slotrow < 0 {
            // slot available, check if the browser row is in use
            var targetRow = cInt((freq - 400) / 100)
            let slotForTargetRow = browserTable.slotForRow(targetRow)
            if slotForTargetRow >= 0 && slotForTargetRow < 41 {
                //  targeted row is in use, now check if we can use an adjacent row
                let slotFreq = sp[Int(slotForTargetRow)].frequency
                if freq < slotFreq {
                    if browserTable.rowIsInUse(targetRow - 1).boolValue == false {
                        //  found a usable row
                        targetRow -= 1
                    } else {
                        //  both row and row-1 are in use!
                        demod.setUserIndex(PSKBrowserHub.LOWERROWBUSY)
                        return
                    }
                } else {
                    if browserTable.rowIsInUse(targetRow + 1).boolValue == false {
                        //  found a usable row
                        targetRow += 1
                    } else {
                        //  both row and row+1 are in use!
                        demod.setUserIndex(PSKBrowserHub.UPPERROWBUSY)
                        demod.setDisabled(true)
                        return
                    }
                }
            }
            //  found a row to insert the slot
            browserTable.assignRow(targetRow, toSlot: Int32(slot), frequency: freq)
            demod.setUserIndex(Int32(slot))
            return
        }
        if slotrow >= 0 {
            demod.setUserIndex(PSKBrowserHub.SLOTINUSE)             // 50 Hz slot still in use
            return
        }
        let slotFreq = browserTable.frequencyForSlot(Int32(slot))
        if fabsf(slotFreq - freq) < 48 {
            demod.setUserIndex(PSKBrowserHub.TOOCLOSETONEIGHBOR)    // too close to existing frequency
            return
        }
        if freq < slotFreq { slot -= 1 } else { slot += 1 }
        if slot >= 0 && slot < 41 {
            if browserTable.rowForSlot(Int32(slot)) >= 0 {
                demod.setUserIndex(PSKBrowserHub.TOOCLOSETONEIGHBOR)    // too close to existing frequency
                return
            }
        }
    }

    //  Buffers arrive at 11025 s/s.
    //  This is converted to 8000 in the readThread (in the base class) and to
    //  -sendBufferToDemodulators.
    @objc(importBuffer:)
    func importBuffer(_ buf: UnsafeMutablePointer<Float>) {
        _ = dataPipe.write(UnsafeMutableRawPointer(buf), length: Int32(512 * MemoryLayout<Float>.size))
    }

    //  VFO offset and sideband are sent here from the PSK receiver
    //  polarity = YES if USB
    @objc(setVFOOffset:sideband:)
    func setVFOOffset(_ offset: Float, sideband polarity: DarwinBoolean) {
        browserTable.setVFOOffset(offset, sideband: polarity)
    }

    @objc(squelchChanged:)
    func squelchChanged(_ slider: NSSlider) {
        squelch = (1.0 - slider.floatValue) * 0.75 + 0.25
    }

    @objc(removeThread:)
    func removeThread(_ ourself: Any?) {
        autoreleasepool {
            let start = 0
            let end = 21

            let base = browserTable.slot()
            for row in start..<end {
                var slotIndex = browserTable.slotForRow(Int32(row))
                if slotIndex >= 0 {
                    let slot = base + Int(slotIndex)
                    let freq = slot.pointee.frequency
                    demodBusy.lock()
                    let count = sortedDemodulators.count()
                    for i in 0..<count {
                        if let demod = sortedDemodulators.object(at: i) as? LitePSKDemodulator {
                            if fabsf(demod.frequency() - freq) < 30 {
                                slotIndex = releaseDemodulator(demod)
                                browserTable.removeSlot(slotIndex)
                                sortedDemodulators.removeObject(demod)
                                break
                            }
                        }
                    }
                    demodBusy.unlock()
                }
            }
        }
    }

    @objc(rescanThread:)
    func rescanThread(_ ourself: Any?) {
        autoreleasepool {
            var start = Int(table.selectedRow)
            let end: Int
            if start < 0 {
                start = 0
                end = 21
            } else {
                end = start + 1
            }

            let base = browserTable.slot()
            for row in start..<end {
                var slotIndex = browserTable.slotForRow(Int32(row))
                if slotIndex >= 0 {
                    let slot = base + Int(slotIndex)
                    let freq = slot.pointee.frequency
                    demodBusy.lock()
                    let count = sortedDemodulators.count()
                    for i in 0..<count {
                        if let demod = sortedDemodulators.object(at: i) as? LitePSKDemodulator {
                            if fabsf(demod.frequency() - freq) < 30 {
                                slotIndex = releaseDemodulator(demod)
                                browserTable.removeSlot(slotIndex)
                                sortedDemodulators.removeObject(demod)
                                break
                            }
                        }
                    }
                    demodBusy.unlock()
                }
            }
        }
    }

    @objc(rescan)
    func rescan() {
        if Thread.current == mainThread {
            rescanThread(self)
        } else {
            //  start thread to rescan
            Thread.detachNewThreadSelector(#selector(rescanThread(_:)), toTarget: self, with: self)
        }
    }

    @objc(openAlarm)
    func openAlarm() {
        browserTable.openAlarm()
    }

    @objc(enableTableView)
    func enableTableView() {
        let window = table?.window
        skipMultipleDemodulators = false
        window?.delegate = self
        if let window = window, !window.isVisible {
            window.orderFront(nil)
        }
    }

    @objc(disableTableView)
    func disableTableView() {
        if table != nil {
            //  v0.78 check first if table is defined
            if let window = table.window { window.orderOut(nil) }
        }
        if skipMultipleDemodulators == true { return }          // v0.78

        skipMultipleDemodulators = true
        if Thread.current == mainThread {
            removeThread(self)
        } else {
            Thread.detachNewThreadSelector(#selector(removeThread(_:)), toTarget: self, with: self)
        }
    }

    @objc(nextStationInTableView)
    func nextStationInTableView() {         //  v0.97
        if table == nil || skipMultipleDemodulators == true {
            NSSound.beep()
            return
        }
        let previousScanIndex = scanIndex
        let rows = Int32(table.numberOfRows)
        var i: Int32 = 1
        while i < rows + 1 {
            let index = (scanIndex + i) % rows
            let slotIndex = browserTable.slotForRow(index)
            if slotIndex >= 0 {
                //  found an active row
                if index != previousScanIndex {
                    scanIndex = index
                    _ = browserTable.selectSlot(slotIndex)
                }
                return
            }
            i += 1
        }
        let spoke = (NSApp.delegate as? AppDelegate)?.application()?.speakAssist("No signal") ?? false
        if !spoke {         //  v1.01b
            //  didn't find any active station
            browserTable.unselectSlots()
            NSSound.beep()
            Thread.sleep(until: Date(timeIntervalSinceNow: 0.3))
            NSSound.beep()
        }
    }

    @objc(previousStationInTableView)
    func previousStationInTableView() {     //  v1.01c
        if table == nil || skipMultipleDemodulators == true {
            NSSound.beep()
            return
        }
        let previousScanIndex = scanIndex
        let rows = Int32(table.numberOfRows)
        var i: Int32 = 1
        while i < rows + 1 {
            let index = (scanIndex - i + rows) % rows
            let slotIndex = browserTable.slotForRow(index)
            if slotIndex >= 0 {
                //  found an active row
                if index != previousScanIndex {
                    scanIndex = index
                    _ = browserTable.selectSlot(slotIndex)
                }
                return
            }
            i += 1
        }
        let spoke = (NSApp.delegate as? AppDelegate)?.application()?.speakAssist("No signal") ?? false
        if !spoke {
            //  didn't find any active station
            browserTable.unselectSlots()
            NSSound.beep()
            Thread.sleep(until: Date(timeIntervalSinceNow: 0.3))
            NSSound.beep()
        }
    }

    @objc(updateVisibleState:)
    func updateVisibleState(_ visible: DarwinBoolean) {
        if visible.boolValue == false {
            //  interface switched away from PSK
            savedSkipMultipleDemodulators = skipMultipleDemodulators
            disableTableView()
        } else {
            // PSK interface made visible
            if savedSkipMultipleDemodulators == false { enableTableView() }
        }
    }

    @objc(windowShouldClose:)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == table?.window { disableTableView() }
        return true
    }

    @objc(updateFromPlist:)
    func updateFromPlist(_ pref: Preferences) -> DarwinBoolean {
        if browserTable != nil { _ = browserTable.updateFromPlist(pref) }
        return true
    }

    @objc(retrieveForPlist:)
    func retrieveForPlist(_ pref: Preferences) {
        if browserTable != nil { browserTable.retrieveForPlist(pref) }
    }
}
