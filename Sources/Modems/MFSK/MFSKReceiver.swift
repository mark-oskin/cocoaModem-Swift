//
//  MFSKReceiver.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 4/29/06.
//  Swift port of MFSKReceiver.m.
//
//  MFSK Receiver: mix with a complex LO to center the signal around DC, then
//  resample (nearest neighbour / linear) to a 500 Hz period before handing 32
//  samples at a time to the MFSKDemodulator.
//
//  Base class of MFSK16Receiver / DominoReceiver / DominoHalfRateReceiver.  All
//  base ivars are EXACT-named stored properties so those subclasses keep
//  accessing them by name.  The C fixed sample arrays (iMixer[512] ... iBuffer[32])
//  and the malloc'd click buffers (float*[512]) become UnsafeMutablePointer
//  buffers allocated up-front and freed in deinit; the CMFIR filters are freed
//  with CMDeleteFIR (mirroring -dealloc).  Ring indices keep the exact `& 0x1ff`.
//

import Cocoa

@objc(MFSKReceiver)
class MFSKReceiver: CMTappedPipe {

    @objc var demodulator: MFSKDemodulator!

    @objc var enabled: Bool = false
    var clickBuffersAllocated: Bool = false     //  v0.80l

    //  mixer
    var vco: CMPCO!
    var receiveFrequency: Float = 0
    let iMixer = UnsafeMutablePointer<Float>.allocate(capacity: 512)     //  mixer output (before IF filter)
    let qMixer = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    var decimationRatio: Float = 0
    var nextSample: Float = 0
    var outputIndex: Int32 = 0
    var iFilter: UnsafeMutablePointer<CMFIR>!
    var qFilter: UnsafeMutablePointer<CMFIR>!
    //  IF filtered buffer
    let iOutput = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    let qOutput = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    let iBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 32)
    let qBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 32)
    //  sideband
    var sidebandState: Bool = false

    //  click buffer
    var clickBufferLock: NSLock!
    let clickBuffer: UnsafeMutablePointer<UnsafeMutablePointer<Float>?> = {
        let p = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 512)
        p.initialize(repeating: nil, count: 512)
        return p
    }()
    var clickBufferProducer: Int32 = 0
    var clickBufferConsumer: Int32 = 0

    //  ---- initializers ----

    //  common base setup ( -initReceiver body, minus [super init] )
    private func setupReceiverBase() {
        iMixer.initialize(repeating: 0, count: 512)
        qMixer.initialize(repeating: 0, count: 512)
        iOutput.initialize(repeating: 0, count: 512)
        qOutput.initialize(repeating: 0, count: 512)
        iBuffer.initialize(repeating: 0, count: 32)
        qBuffer.initialize(repeating: 0, count: 32)

        enabled = false
        sidebandState = true
        demodulator = nil
        clickBuffersAllocated = false               //  v0.80l

        //  set up VCO at tone's frequency
        receiveFrequency = 972.0 + Float(CARRIEROFFSET)
        vco = CMPCO()
        vco.setCarrier(receiveFrequency)

        //  click buffer
        createClickBuffer()

        //  input decimation
        nextSample = 150
        outputIndex = 0
    }

    //  -initReceiver : partial setup, used by subclasses via [super initReceiver].
    //  The Void label keeps this distinct from -init (the full receiver below) and
    //  is only reachable from the Swift subclasses' super.init(receiverPartial:()).
    init(receiverPartial: Void) {
        super.init()
        setupReceiverBase()
    }

    //  -init : full MFSK receiver (used by DominoHalfRateReceiver via [super init])
    override init() {
        super.init()
        setupReceiverBase()
        demodulator = MFSKDemodulator()
        //  input decimation
        decimationRatio = Float(CMFs / 500.0)
        iFilter = CMFIRLowpassFilter(210, Float(CMFs), 512)
        qFilter = CMFIRLowpassFilter(210, Float(CMFs), 512)
    }

    //  v0.76 leak (not important, since we don't release the MFSK object)
    deinit {
        if iFilter != nil { CMDeleteFIR(iFilter) }
        if qFilter != nil { CMDeleteFIR(qFilter) }
        iMixer.deallocate()
        qMixer.deallocate()
        iOutput.deallocate()
        qOutput.deallocate()
        iBuffer.deallocate()
        qBuffer.deallocate()
        for i in 0..<512 {
            if let p = clickBuffer[i] { p.deallocate() }
        }
        clickBuffer.deallocate()
    }

    @objc(setSidebandState:)
    func setSidebandState(_ state: Bool) {
        sidebandState = state
        demodulator.setSidebandState(DarwinBoolean(state))
    }

    @objc(createClickBuffer)
    func createClickBuffer() {
        if clickBuffersAllocated { return }         //  v0.80l already allocated by super class

        clickBufferProducer = 0                     //  buffer number (512 samples per buffer)
        clickBufferConsumer = 0
        clickBufferLock = NSLock()
        for i in 0..<512 {
            //  1 MB buffer, for 262,144 floating point samples (23.77 seconds)
            clickBuffer[i] = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        }
        clickBuffersAllocated = true
    }

    //  import data at 11025 s/s
    @objc(importArray:)
    func importArray(_ array: UnsafeMutablePointer<Float>) {
        if sidebandState == true {
            //  USB
            for i in 0..<512 {
                let v = array[i]
                let pair = vco.nextVCOPair()
                iMixer[i] = pair.re * v
                qMixer[i] = pair.im * v
            }
        } else {
            //  LSB -- reverse spectrum around DC
            for i in 0..<512 {
                let v = array[i]
                let pair = vco.nextVCOPair()
                iMixer[i] = pair.re * v
                qMixer[i] = -pair.im * v
            }
        }
        //  Apply lowpass to I and Q channels
        CMPerformFIR(iFilter, iMixer, 512, iOutput)
        CMPerformFIR(qFilter, qMixer, 512, qOutput)

        for _ in 0..<512 {
            //  resample the lowpass filtered I.F. using nearest neighbor
            let n = Int(nextSample)
            if n > 511 {
                nextSample -= 512
                break
            }
            if n < 511 {
                let fract = nextSample - Float(n)
                iBuffer[Int(outputIndex)] = iOutput[n] * (1 - fract) + iOutput[n + 1] * fract
                qBuffer[Int(outputIndex)] = qOutput[n] * (1 - fract) + qOutput[n + 1] * fract
            } else {
                iBuffer[Int(outputIndex)] = iOutput[n]
                qBuffer[Int(outputIndex)] = qOutput[n]
            }
            nextSample += decimationRatio
            outputIndex += 1
            if outputIndex >= 32 {
                //  send 32 samples to demodulator
                demodulator.newBuffer(iBuffer, imag: qBuffer)
                outputIndex = 0
            }
        }
    }

    @objc(consumeClickBufferData)
    func consumeClickBufferData() {
        //  copy the stream info but use the buffered data, and set the pointer to
        //  the click buffer.  Process 8 click buffers as fast as possible until
        //  the stream has caught up.
        for _ in 0..<8 {
            if clickBufferConsumer == clickBufferProducer { break }
            //  push out unprocessed data
            let array = clickBuffer[Int(clickBufferConsumer)]
            clickBufferConsumer = (clickBufferConsumer + 1) & 0x1ff  //  wrap around 512 buffers
            importArray(array!)
        }
    }

    //  input data for MFSK receiver, at 11025 samples/second
    //  resample to 8000 and send to the demodulator.
    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        if !enabled { return }

        if clickBufferLock.try() {
            //  copy data into tail of clickBuffer
            let stream = pipe.stream()
            let array = stream!.pointee.array
            let buf = clickBuffer[Int(clickBufferProducer)]
            clickBufferProducer = (clickBufferProducer + 1) & 0x1ff  //  512 click buffers
            memcpy(buf, array, 512 * MemoryLayout<Float>.size)
            consumeClickBufferData()
            clickBufferLock.unlock()
        }
    }

    //  new click, set the click buffer pointer so the next time data will be
    //  consumed from the buffer.
    @objc(clicked:)
    func clicked(_ history: Float) {
        //  clickBuffer base is always allocated; the original `if ( !clickBuffer )`
        //  guard never triggered.
        var history = history
        if history < 0.1 { history = 0.1 }
        if history > 20.0 { history = 20.0 }

        //  0.73 flush decimation filter
        iMixer.update(repeating: 0, count: 512)
        for _ in 0..<4 {
            CMPerformFIR(iFilter, iMixer, 512, iOutput)
            CMPerformFIR(qFilter, iMixer, 512, qOutput)
        }

        clickBufferLock.lock()
        clickBufferConsumer = clickBufferProducer + (512 - Int32(21.5 * history))
        clickBufferConsumer = clickBufferConsumer & 0x1ff   //  wrap around a 256K sample (512*512) float buffer
        clickBufferLock.unlock()

        demodulator.waterfallClicked()
    }

    @objc(selectFrequency:fromWaterfall:)
    func selectFrequency(_ freq: Float, fromWaterfall clicked: Bool) {
        if sidebandState {
            //  USB
            receiveFrequency = freq + Float(CARRIEROFFSET)      //  center is 125 Hz higher
        } else {
            receiveFrequency = freq - Float(CARRIEROFFSET)      //  center is 125 Hz lower
        }
        vco.setCarrier(receiveFrequency)
        if clicked {
            //  don't reset demodulator if it is a scroll wheel operation
            demodulator.resetDemodulatorState()
        }
    }

    @objc(enableReceiver:)
    func enableReceiver(_ state: Bool) {
        enabled = state
    }
}
