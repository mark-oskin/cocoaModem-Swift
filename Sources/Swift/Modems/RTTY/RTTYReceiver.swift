//
//  RTTYReceiver.swift
//  cocoaModem
//
//  Created by Kok Chen on 1/17/05.
//  Swift port of RTTYReceiver.m.
//
//  This is the cocoaModem wrapper around CoreModem's RTTYDemodulator.  It
//  provides a bank of bandpass filters and a bank of matched filters.
//  Characters received from CMBaudotDecoder are displayed on a TextView.
//
//  Port notes:
//    - This is the base class of ASCIIReceiver / CWReceiver / SITORReceiver.
//      Every ivar becomes an EXACT-named stored property so those subclasses
//      (all Swift now) keep accessing them by name across the module.
//    - The receive thread is preserved exactly (detachNewThreadSelector +
//      NSConditionLock lockWhenCondition:/unlockWithCondition: on kNoData /
//      kHasData).  The old manual NSAutoreleasePool drain (guarded by a
//      Gestalt Snow-Leopard check) is replaced by a per-iteration
//      autoreleasepool {} which is the ARC-safe equivalent.
//    - The malloc'd click buffers (float*[512], 512 floats each) become
//      UnsafeMutablePointer buffers, allocated in -createClickBuffer and freed
//      in deinit.  The ring indices keep the exact `& 0x1ff` masking.
//    - `cmData` (the object's private CMDataStream) is a heap CMDataStream so
//      the inherited `data` pointer can hold its stable address, exactly as the
//      ObjC `data = &cmData`.
//

import Cocoa

//  enum LockCondition { kNoData, kHasData } used to live in RTTYReceiver.h and
//  was shared (via the header) by CWReceiver, ASCIIReceiver and PSKReceiver.
//  All of those are Swift now, so the enum is expressed here as two module-scope
//  constants; no C header replacement is needed.
let kNoData = 0
let kHasData = 1

//  Phi (slashed-zero glyph) was #define Phi 0xd8 in cocoaModemParams.h, which is
//  not visible to Swift.
private let Phi: Int32 = 0xd8

@objc(RTTYReceiver)
class RTTYReceiver: CMTappedPipe {

    var uniqueID: Int32 = 0
    var app: Application!                       //  v0.96d

    //  connections (views, buttons, sliders)
    var receiveView: ExchangeView!
    var bandwidthMatrix: NSMatrix!
    var demodulatorModeMatrix: NSMatrix!
    var squelch: NSSlider!
    //  USOS
    var usos: Bool = false

    //  AudioPipes (DSP stages for RTTY)
    var matchedFilter: CMFilterBank!
    var bandpassFilter: CMFilterBank!
    var bpf = [CMBandpassFilter?](repeating: nil, count: 5)
    @objc var demodulator: CMFSKDemodulator!
    //  float *clickBuffer[512] -- base array is always allocated (as the C fixed
    //  array was); the individual 512-float buffers are malloc'd in
    //  -createClickBuffer.
    let clickBuffer: UnsafeMutablePointer<UnsafeMutablePointer<Float>?> = {
        let p = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 512)
        p.initialize(repeating: nil, count: 512)
        return p
    }()
    var clickBufferProducer: Int32 = 0
    var clickBufferConsumer: Int32 = 0
    var clickBufferLock: NSLock!
    var newData: NSConditionLock!
    let cmData = UnsafeMutablePointer<CMDataStream>.allocate(capacity: 1)

    var appleScript: Module!

    var currentTonePair = CMTonePair()
    @objc var enabled: Bool = false
    var slashZero: Bool = false
    var sidebandState: Bool = false

    //  v0.78
    @objc var rttyAuralMonitor: RTTYAuralMonitor!

    //  v0.88
    var clickBufferActive: Bool = false

    //  ---- initializers ----

    //  mirrors the inherited [super init] path used by ASCIIReceiver/CWReceiver
    //  ( [super init] in those subclasses resolves here ).
    override init() {
        cmData.initialize(to: CMDataStream())
        super.init()
    }

    @objc(initSuperReceiver:)
    init(superReceiver index: Int32) {
        cmData.initialize(to: CMDataStream())
        super.init()
    }

    @objc(initReceiver:modem:)
    init(receiver index: Int32, modem: Modem!) {
        cmData.initialize(to: CMDataStream())
        let defaultTones = CMTonePair(mark: 2125.0, space: 2295.0, baud: 45.45)

        super.init()

        uniqueID = index
        app = modem.application()               //  v0.96d
        receiveView = nil
        squelch = nil
        currentTonePair = defaultTones
        enabled = false
        slashZero = false
        sidebandState = false
        demodulatorModeMatrix = nil
        bandwidthMatrix = nil
        appleScript = nil
        usos = true
        clickBufferActive = false               //  v0.88

        //  local CMDataStream
        cmData.pointee.samplingRate = 11025.0
        cmData.pointee.samples = 512
        cmData.pointee.components = 1
        cmData.pointee.channels = 1
        data = cmData
        newData = NSConditionLock(condition: kNoData)
        Thread.detachNewThreadSelector(#selector(receiveThread(_:)), toTarget: self, with: self)
        clickBufferLock = nil

        rttyAuralMonitor = RTTYAuralMonitor()

        //  v0.52, v0.68 -- RTTYDemodulator (OLDDEMOD path is disabled)
        demodulator = RTTYDemodulator(fromReceiver: self)

        bandpassFilter = CMFilterBank()
        matchedFilter = CMFilterBank()

        //  create bandpass filter bank
        bpf[0] = demodulator.makeFilter(238.18)     //  v0.83, was 240
        bpf[1] = demodulator.makeFilter(306.35)     //  was 340
        bpf[2] = demodulator.makeFilter(442.70)     //  was 480
        bpf[3] = demodulator.makeFilter(579.05)     //  was 580
        bpf[4] = demodulator.makeFilter(1000.0)
        bandpassFilter.installFilter(bpf[0])
        bandpassFilter.installFilter(bpf[1])
        bandpassFilter.installFilter(bpf[2])
        bandpassFilter.installFilter(bpf[3])
        bandpassFilter.installFilter(bpf[4])
        bandpassFilter.selectFilter(1)
        demodulator.useBandpassFilter(bandpassFilter)

        //  create matched filter bank
        matchedFilter.installFilter(RTTYSingleFilter(tone: 0, baud: 45.45))                  //  Mark-only
        matchedFilter.installFilter(RTTYSingleFilter(tone: 1, baud: 45.45))                  //  Space-only
        matchedFilter.installFilter(RTTYMPFilter(bitWidth: 0.35, baud: 45.45))               //  MP+
        matchedFilter.installFilter(RTTYMPFilter(bitWidth: 0.70, baud: 45.45))               //  MP-
        matchedFilter.installFilter(RTTYMatchedFilter(defaultFilterWithBaudRate: 45.45))     //  MS  v0.32

        matchedFilter.selectFilter(4)
        demodulator.useMatchedFilter(matchedFilter)
    }

    deinit {
        for i in 0..<512 {
            if let p = clickBuffer[i] { p.deallocate() }
        }
        clickBuffer.deallocate()
        cmData.deinitialize(count: 1)
        cmData.deallocate()
    }

    //  v0.68
    @objc(setPrintControl:)
    func setPrintControl(_ state: Bool) {
        (demodulator as? RTTYDemodulator)?.setPrintControl(state)
    }

    //  update views when receiver is moved inside the window
    @objc(updateInterface)
    func updateInterface() {
    }

    @objc(baudotPipe)
    func baudotPipe() -> CMTappedPipe! {
        return demodulator.baudotWaveform() as? CMTappedPipe
    }

    @objc(atcPipe)
    func atcPipe() -> CMTappedPipe! {
        return demodulator.atcWaveform() as? CMTappedPipe
    }

    @objc(demodBufferPipe)
    func demodBufferPipe() -> CMTappedPipe! {
        return demodulator as? CMTappedPipe
    }

    @objc(bpfBufferPipe)
    func bpfBufferPipe() -> CMTappedPipe! {
        return bandpassFilter as? CMTappedPipe
    }

    @objc(registerModule:)
    func registerModule(_ module: Module!) {
        appleScript = module
    }

    //  set up filter cutoffs given current mark and space frequencies
    @objc(setFilterCutoffs:)
    func setFilterCutoffs(_ tonepair: UnsafePointer<CMTonePair>) {
        let low: Double
        let high: Double

        if tonepair.pointee.space < tonepair.pointee.mark {
            low = tonepair.pointee.space
            high = tonepair.pointee.mark
        } else {
            low = tonepair.pointee.mark
            high = tonepair.pointee.space
        }
        let bw = tonepair.pointee.baud / 45.45      //  bandwidth relative to 45.5 baud receiver

        bpf[0]?.updateLowCutoff(Float(low - (1.5 * 45.45 / 2) * bw), highCutoff: Float(high + (1.5 * 45.45 / 2) * bw))   //  v0.83
        bpf[1]?.updateLowCutoff(Float(low - (3 * 45.45 / 2) * bw), highCutoff: Float(high + (3 * 45.45 / 2) * bw))       //  v0.83
        bpf[2]?.updateLowCutoff(Float(low - (6 * 45.45 / 2) * bw), highCutoff: Float(high + (6 * 45.45 / 2) * bw))       //  v0.83
        bpf[3]?.updateLowCutoff(Float(low - (9 * 45.45 / 2) * bw), highCutoff: Float(high + (9 * 45.45 / 2) * bw))       //  v0.83
    }

    @objc(setupReceiverChain:)
    func setupReceiverChain(_ config: ModemConfig!) {
        demodulator.setConfig(config)                   //  v0.88d
        demodulator.setupDemodulatorChain()
        demodulator.useBandpassFilter(bandpassFilter)
        demodulator.useMatchedFilter(matchedFilter)
        demodulator.setDelegate(self)                   //  demodulator calls back to receivedCharacter: delegate
    }

    @objc(createClickBuffer)
    func createClickBuffer() {
        clickBufferProducer = 0                          //  buffer number (512 samples per buffer)
        clickBufferConsumer = 0
        clickBufferLock = NSLock()
        for i in 0..<512 {
            //  1 MB buffer, for 262,144 floating point samples (23.77 seconds)
            clickBuffer[i] = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        }
    }

    //  v0.89
    @objc(clearClickBuffer)
    func clearClickBuffer() {
        //  clickBuffer base is always allocated (was float*[512]); the original
        //  `if ( clickBuffer != nil )` is therefore always true.
        clickBufferLock?.lock()
        clickBufferProducer = 0
        clickBufferConsumer = 0
        if clickBufferActive == true {
            clickBufferActive = false
            rttyAuralMonitor.clickBufferCleared()
        }
        clickBufferLock?.unlock()
    }

    @objc(receiveThread:)
    func receiveThread(_ ourself: Any?) {
        Thread.setThreadPriority(Thread.current.threadPriority * 0.95)   //  lower thread priority of demodulator

        while true {
            autoreleasepool {
                //  block here waiting for data
                newData.lock(whenCondition: kHasData)
                if enabled {
                    //  copy the stream info but use the buffered data, and set the
                    //  pointer to the click buffer.  Process 8 click buffers as fast
                    //  as possible until the stream has caught up.
                    for i in 0..<8 {
                        if clickBufferConsumer == clickBufferProducer {
                            //  mute auralMonitor while click buffer is active
                            if clickBufferActive == true {
                                clickBufferActive = false
                                rttyAuralMonitor.setClickBufferActive(false)
                            }
                            break
                        }
                        //  push out unprocessed data
                        cmData.pointee.array = clickBuffer[Int(clickBufferConsumer)]
                        clickBufferConsumer = (clickBufferConsumer + 1) & 0x1ff  //  wrap around 512 buffer pointers
                        rttyAuralMonitor.setClickBufferResampling(clickBufferActive && (i == 0))

                        demodulator.importData(self)
                    }
                }
                newData.unlock(withCondition: kNoData)
            }
        }
    }

    @objc(setIgnoreNewline:)
    func setIgnoreNewline(_ state: Bool) {
        receiveView?.setIgnoreNewline(state)
    }

    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        //  check if we have a click buffer by looking to see if a lock exists
        //  some sub classes of RTTYReceiver don't have click buffers
        if clickBufferLock != nil {
            if clickBufferLock.try() {
                newData.lock(whenCondition: kNoData)
                //  copy data into tail of clickBuffer
                let stream = pipe.stream()
                let array = stream!.pointee.array
                //  copy another 512 samples into the click buffer
                let buf = clickBuffer[Int(clickBufferProducer)]
                clickBufferProducer = (clickBufferProducer + 1) & 0x1ff  //  512 click buffers
                memcpy(buf, array, 512 * MemoryLayout<Float>.size)
                //  run the receive thread
                cmData.pointee.userData = stream!.pointee.userData
                cmData.pointee.sourceID = stream!.pointee.sourceID
                //  signal receiveThread that new data has arrived
                newData.unlock(withCondition: kHasData)
                clickBufferLock.unlock()
            }
        } else {
            //  no click buffer -- simply use input stream
            demodulator.importData(pipe)
        }
    }

    //  each audio stream is 512 samples in size
    //  there are 512 of these buffers in the click buffer, or 23.77 seconds worth
    @objc(clicked:)
    func clicked(_ history: Float) {
        //  clickBuffer base is always allocated; the original `if ( !clickBuffer )`
        //  guard never triggered.
        var history = history
        if history < 0.1 { history = 0.1 }
        if history > 20.0 { history = 20.0 }

        clickBufferLock.lock()
        clickBufferConsumer = clickBufferProducer + (512 - Int32(21.5 * history))

        //  v0.88 mute aural monitor
        clickBufferActive = true
        rttyAuralMonitor.setClickBufferActive(true)

        clickBufferConsumer = clickBufferConsumer & 0x1ff   //  wrap around a 256K sample (512*512) float buffer
        clickBufferLock.unlock()
    }

    @objc(enableReceiver:)
    func enableReceiver(_ state: Bool) {
        enabled = state
    }

    @objc(setSlashZero:)
    func setSlashZero(_ state: Bool) {
        slashZero = state
    }

    @objc(setUSOS:)
    func setUSOS(_ state: Bool) {
        usos = state
        demodulator.setUSOS(state)
    }

    @objc(setBell:)
    func setBell(_ state: Bool) {
        demodulator.setBell(state)
    }

    @objc(setBandwidthMatrix:)
    func setBandwidthMatrix(_ matrix: NSMatrix!) {
        bandwidthMatrix = matrix
    }

    @objc(setDemodulatorModeMatrix:)
    func setDemodulatorModeMatrix(_ matrix: NSMatrix!) {
        demodulatorModeMatrix = matrix
    }

    @objc(setReceiveView:)
    func setReceiveView(_ view: ExchangeView!) {
        receiveView = view
    }

    //  select a Demodulator as the client of the Mixer
    @objc(selectDemodulator:)
    func selectDemodulator(_ index: Int32) {
        var index = index
        if demodulatorModeMatrix != nil {
            demodulatorModeMatrix.deselectAllCells()
            demodulatorModeMatrix.selectCell(atRow: 0, column: Int(index))
            if index < 0 || index > 4 { index = 4 }
        } else {
            index = 4       //  mask space demodulator
        }

        matchedFilter.selectFilter(index)

        //  send equalizer parameters
        switch index {
        case 2:
            demodulator.setEqualizer(2)
        case 3:
            demodulator.setEqualizer(1)
        default:
            demodulator.setEqualizer(0)
        }
    }

    //  select an input BPF
    @objc(selectBandwidth:)
    func selectBandwidth(_ index: Int32) {
        var index = index
        if bandwidthMatrix != nil {
            bandwidthMatrix.deselectAllCells()
            bandwidthMatrix.selectCell(atRow: 0, column: Int(index))
            if index < 0 || index > 4 { index = 1 }
            bandpassFilter.selectFilter(index)
            return
        }
        bandpassFilter.selectFilter(1)      //  "normal" filter
    }

    //  --- squelch -----
    @objc(setSquelch:)
    func setSquelch(_ slider: NSSlider!) {
        squelch = slider
    }

    @objc(setSquelchValue:)
    func setSquelchValue(_ value: Float) {
        if squelch != nil {
            squelch.floatValue = value
            demodulator.setSquelch(value)
        }
    }

    @objc(newSquelchValue:)
    func newSquelchValue(_ value: Float) {
        demodulator.setSquelch(value)
    }

    @objc(squelchValue)
    func squelchValue() -> Float {
        var value: Float = 0.1
        if squelch != nil { value = squelch.floatValue }
        return value
    }

    @objc(makeReceiverActive:)
    func makeReceiverActive(_ state: Bool) {
        demodulator.makeDemodulatorActive(state)
    }

    @objc(rxTonePairChanged:)
    func rxTonePairChanged(_ control: RTTYRxControl!) {
        var tonePair = control.rxTonePair()
        //  set mixer tones
        demodulator.setTonePair(&tonePair)
        setFilterCutoffs(&tonePair)
    }

    @objc(forceLTRS)
    func forceLTRS() {
        demodulator.setLTRS(true)
    }

    //  delegate to CMFSKDemodulator
    //  character received from CMBaudotDecoder.
    //  Switch zero to a slashed zero if it is requested.
    @objc(receivedCharacter:)
    func receivedCharacter(_ c: Int32) {
        var c = c
        var buffer = [CChar](repeating: 0, count: 2)

        if appleScript != nil { appleScript.insertBuffer(c) }
        if c == 0x30 /* '0' */ && slashZero { c = Phi }

        buffer[0] = CChar(truncatingIfNeeded: c)
        buffer[1] = 0
        if receiveView != nil {
            receiveView.append(&buffer)
            app?.addToVoice(c, channel: uniqueID + 1)       //  v0.96d voice synthesizer
        }
    }
}
