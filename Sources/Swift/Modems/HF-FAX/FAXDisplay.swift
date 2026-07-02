//
//  FAXDisplay.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/26/06.
//  Swift port of FAXDisplay.m.
//
//  ReceiveView for HF-FAX.  FAXDisplay receives oversampled data (11025
//  samples/second), resamples it to the IOC, stores the image into FAXFrame's
//  backing store and drives the vertical/horizontal sync detectors.
//
//  Fidelity notes (mirroring the C original):
//   - syncBuffer is an exact int[5512+129] C buffer (allocated once, freed in
//     deinit).  All index math (i+64, i+128, i+5512) stays inside that range.
//   - The boxcar-filter / sync accumulators (sum1, sum2, peak, v, tap) are Int32
//     and use the wrapping operators (&+ / &-) so they silently overflow exactly
//     like the C ints did.
//   - Float->int truncations (addPixel scaling, scroller math) are guarded
//     (cTruncInt: NaN/range) then clamped, so NaN/inf is never handed on.
//   - goertzelWindow is a malloc'd C buffer from CMMakeBlackmanWindow; the
//     original never freed it (no -dealloc), so neither do we.
//

import Cocoa

//  vsync state machine (were #defines in FAXDisplay.m)
private let VSYNCWAIT: Int32 = 0
private let VSYNCSTARTING: Int32 = 1
private let VSYNCCHECK: Int32 = 2
private let VSYNCENDPAUSE: Int32 = 3
private let VSYNCSTARTWAIT: Int32 = 4

//  MAXBACKING (from FAXFrame.h) recomputed locally, as the nested C macro is not
//  imported into Swift.
private let MAXBACKING = (3200 + 64) * 2000

@objc(FAXDisplay)
class FAXDisplay: FAXView {

    //  ---- nib outlets (KVC) ----------------------------------------------
    @objc var autoButton: NSButton!
    @objc var halfButton: NSButton!
    @objc var newButton: NSButton!
    @objc var pauseButton: NSButton!
    @objc var saveButton: NSButton!
    @objc var scroller: NSSlider!               //  v0.80 scroll ourselves since scrollview leaks

    @objc var blackLevelSlider: NSSlider!
    @objc var contrastSlider: NSSlider!

    @objc var clockOffsetField: NSTextField!
    @objc var clockOffsetStepper: NSStepper!    //  a FAXStepper in the nib (cast to call steps())
    @objc var runLight: NSTextField!            //  colored NSTextField status light

    @objc var saveView: FAXView!                //  off page FAXView (v0.81 no longer used)
    @objc var tempFolder: NSTextField!

    //  ---- ivars -----------------------------------------------------------
    private var spareImage: NSImage!

    private var nominalBlackLevel: Float = 0, nominalContrast: Float = 0

    private var imageParametersChanged = false       // v0.57d

    private var dev850 = false                        // use 850 Hz deviation instead of 800 Hz

    private var updateLock: NSLock!
    private var drawLock: NSLock!
    private var message: Int32 = 0
    private var firstDraw = false

    //  float sync detection
    private var goertzelWindow: UnsafeMutablePointer<Float>?
    private var startTone: Float = 0
    private var stopTone: Float = 0
    private var sync: Float = 0

    private var running = false, paused = false
    private var vsyncState: Int32 = 0, pauseCount: Int32 = 0, linesFromTop: Int32 = 0
    private let syncBuffer: UnsafeMutablePointer<Int32> = {
        let p = UnsafeMutablePointer<Int32>.allocate(capacity: 5512 + 129)
        p.initialize(repeating: 0, count: 5512 + 129)
        return p
    }()

    //  display
    private var updatedRow: Int32 = 0
    private var updateRequested = false
    //  v0.80 scroller
    private var scrollerHeight: Float = 0, viewHeight: Float = 0

    //  file-scope `static int drawCount = 100` in FAXDisplay.m.  Renamed to
    //  drawCountValue so it cannot collide with the -drawCount selector below.
    private static var drawCountValue: Int32 = 100

    //  C truncates a float to a (signed 32-bit) int toward zero.  Swift traps on
    //  NaN / out-of-range, so mirror C with a guarded truncation.
    @inline(__always)
    static func cTruncInt(_ x: Float) -> Int32 {
        if x.isNaN { return 0 }
        let t = x.rounded(.towardZero)
        if t >= 2147483647.0 { return Int32.max }
        if t <= -2147483648.0 { return Int32.min }
        return Int32(t)
    }

    deinit {
        syncBuffer.deallocate()
        //  goertzelWindow (CMMakeBlackmanWindow) is intentionally not freed --
        //  the Obj-C original had no -dealloc and leaked it for the app lifetime.
    }

    // ---------------- init ----------------

    override init(frame imageframe: NSRect) {
        super.init(frame: imageframe)
        //  display appearance
        scrollerHeight = 2400
        running = false
        paused = false
        nominalBlackLevel = 32
        nominalContrast = 192
        imageParametersChanged = false
        updateRequested = false
        dev850 = false                          //  v0.73

        spareImage = NSImage()

        //  set grayscale table to nominal blackLevel and contrast
        faxFrame?.setGrayscale(from: nominalBlackLevel, to: nominalBlackLevel + nominalContrast)

        //  sync detector
        goertzelWindow = CMMakeBlackmanWindow(256)
        startTone = Float(cos(2.0 * 3.1415926535 / CMFs * 300.0))
        stopTone = Float(cos(2.0 * 3.1415926535 / CMFs * 450.0))
        vsyncState = VSYNCWAIT
        linesFromTop = 5000
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // ---------------- scrolling ----------------

    private func scrollBuffer() {
        let top = FAXDisplay.cTruncInt(Float(scroller?.maxValue ?? 0) - (scroller?.floatValue ?? 0))
        faxFrame?.setScrollOffset(top)
    }

    //  (Private API) v0.80 no longer done from main thread
    @objc func refreshImage() {
        self.needsDisplay = true
    }

    //  (Private API)
    private func unconditionalSetPosition(_ whereRow: Int32) {
        scroller?.floatValue = scrollerHeight - Float(whereRow)
        scrollBuffer()
        self.performSelector(onMainThread: #selector(refreshImage), with: nil, waitUntilDone: true)
    }

    //  (Private API)
    private func setPosition(_ whereRow: Int32) {
        //  v0.80 no longer uses the enclosing scrollview, but a slider (the
        //  scroll/clip view leaks massive memory once the FAX passes the bottom).
        let scrollertop = scrollerHeight - (scroller?.floatValue ?? 0)
        if whereRow != 0 && abs(Float(whereRow) - scrollertop) > 2 { return }   //  scroller moved away by user
        unconditionalSetPosition(whereRow)
    }

    //  (Private API)
    private func setInterface(_ object: NSControl?, to selector: Selector) {
        object?.action = selector
        object?.target = self
    }

    //  (Private API) executed in main thread
    @objc func swapImageRepAndRefresh() {
        //  point NSBitmapImageRep to scrolled position, and redraw
        self.swapImageRep()
        refreshImage()
    }

    @objc func scrollBufferFromScroller() {
        scrollBuffer()
        //  point NSBitmapImageRep to scrolled position, and redraw
        self.performSelector(onMainThread: #selector(swapImageRepAndRefresh), with: nil, waitUntilDone: true)
    }

    //  local
    @objc(displayRunLightColor:)
    func displayRunLightColor(_ color: NSColor) {
        runLight?.backgroundColor = color
        runLight?.needsDisplay = true
    }

    // ---------------- sync detection ----------------

    //  return power at frequency using Goertzel algorithm (256 unsigned char samples)
    private func goertzel(_ x: UnsafeMutablePointer<UInt8>, tone s: Float) -> Float {
        var d0: Float = 0, d1: Float = 0, d2: Float
        for i in 0..<256 {
            d2 = d1
            d1 = d0
            d0 = 2 * s * d1 - d2 + goertzelWindow![i] * Float(Int(x[i]) - 128)
        }
        return d0 * d0 + d1 * d1 - 2 * s * d0 * d1
    }

    private func findVSync(_ array: UnsafeMutablePointer<UInt8>) -> Float {
        //  cross correlate with shifted data (for multiple of 75 Hz tones)
        var r: Float = 0
        var d1: Float = 0.1, d2: Float = 0.1
        for i in 0..<256 {
            let x1 = Float(Int(array[i]) - 128)
            let x2 = Float(Int(array[i + 294]) - 128)
            r += x1 * x2
            d1 += x1 * x1
            d2 += x2 * x2
        }
        r = abs(r / (d1 * d2).squareRoot())

        if r < 0.8 { return 0 }

        let start = goertzel(array, tone: startTone)
        let stop = goertzel(array, tone: stopTone)

        var sum: Float = 0
        for i in 0..<256 {
            let x1 = Float(Int(array[i]) - 128)
            sum += x1 * x1
        }
        sum *= 7

        r = ((stop > start) ? -stop : start) / sum
        return r
    }

    private func findHSyncAtRow(_ v: Int32) {
        var offset = Int(faxFrame.frameOrigin()) + Int(faxFrame.frameOffsetForSample(0, ofRow: v))
        let backing = faxFrame.backingFrame().pointee.backing!
        for i in 0..<5512 {
            offset %= MAXBACKING
            syncBuffer[i] = syncBuffer[i] &+ (Int32(backing[offset]) &- 128)
            offset += 1
        }
    }

    private func checkSyncBuffer() {
        //  first extend the buffer to emulate a circular buffer
        for i in 0..<129 { syncBuffer[i + 5512] = syncBuffer[i] }

        //  init boxcar filter
        var sum1: Int32 = 0, sum2: Int32 = 0
        for i in 0..<64 {
            sum1 = sum1 &+ syncBuffer[i]
            sum2 = sum2 &+ syncBuffer[i + 64]
        }
        //  boxcar filter
        var peak = sum2 &- sum1
        for i in 0..<5512 {
            let tap = syncBuffer[i + 64]
            sum1 = sum1 &+ (tap &- syncBuffer[i])
            sum2 = sum2 &+ (syncBuffer[i + 128] &- tap)      //  v0.26 bug fix
            let v = sum1 &- sum2
            if v > peak { peak = v }
        }

        if peak < 2000 { return }       //  probably not a sync pulse

        //  position is where the correlation peaks
        for i in 0..<5512 {
            if syncBuffer[i + 1] < 0 && syncBuffer[i] >= 0 {
                faxFrame?.setHorizontalOffset(Int32(i))
                faxFrame?.clearSwath(32)
                setPosition(0)
                return
            }
        }
    }

    @objc func start() {
        faxFrame?.startNewImage()
        sync = 0.0

        running = true
        paused = false
        runLight?.backgroundColor = .green
        if vsyncState == VSYNCSTARTWAIT { vsyncState = VSYNCWAIT }
    }

    //  (stop signal) -> VSYNCENDPAUSE -> VSYNCWAIT -> (start signal) -> VSYNCSTARTING
    //   -> (start signal goes away) -> VSYNCWAIT
    @objc func outputLine() {
        //  new line received, inform background thread
        if vsyncState == VSYNCWAIT || vsyncState == VSYNCSTARTING || vsyncState == VSYNCSTARTWAIT {
            //  look for sync at different locations on the scanline to avoid false
            //  positives.  Each scanline is 0.5 s long and has 11025/2 samples.
            //  Use a slow attack fast decay decoder.
            let backingframe = faxFrame.backingFrame()
            let random = (backingframe.pointee.input & 0x7) &* 500
            let syncIndex = (backingframe.pointee.origin &+ backingframe.pointee.input &- 5000 &+ random) % Int32(MAXBACKING)
            let newsync = findVSync(backingframe.pointee.backing! + Int(syncIndex))
            sync = (newsync < sync) ? (sync * 0.3 + 0.7 * newsync) : (sync * 0.7 + 0.3 * newsync)
        }
        switch vsyncState {
        case VSYNCSTARTING:
            if sync < 0.40 {
                linesFromTop = 0
                sync = 0.0
                for i in 0..<5510 { syncBuffer[i] = 0 }
                vsyncState = VSYNCWAIT
                start()
                FAXDisplay.drawCountValue = 0
                runLight?.backgroundColor = .yellow
                self.performSelector(onMainThread: #selector(displayRunLightColor(_:)), with: NSColor.yellow, waitUntilDone: false)
            }
        case VSYNCENDPAUSE:
            //  pause after a STOP signal before waiting for START
            pauseCount &+= 1
            if pauseCount > 10 {
                paused = true
                runLight?.backgroundColor = .red
                vsyncState = VSYNCSTARTWAIT
                sync = 0.0
            }
        case VSYNCSTARTWAIT:
            if sync > 0.8 { vsyncState = VSYNCSTARTING }
        default:
            linesFromTop &+= 1
            let backingframe = faxFrame.backingFrame()
            if linesFromTop > 10 && linesFromTop <= 32 {
                //  look for hsync
                findHSyncAtRow(backingframe.pointee.displayRow)
                if linesFromTop == 32 {
                    checkSyncBuffer()
                    runLight?.backgroundColor = .green
                    self.performSelector(onMainThread: #selector(displayRunLightColor(_:)), with: NSColor.green, waitUntilDone: false)
                }
            }
            if sync > 0.8 {
                //  saw individual (not after stop) start signal
                if autoButton?.state == .on {
                    //  if auto is checked, start at the top and look for H Sync
                    vsyncState = VSYNCSTARTING
                }
            } else if sync < -0.8 {
                //  saw stop signal
                if autoButton?.state == .on {
                    //  do auto sequence if auto is checked
                    pauseCount = 0
                    vsyncState = VSYNCENDPAUSE
                    faxFrame?.markDisplayRow()
                    let folder = tempFolder?.stringValue
                    //  dump image to pdf file (v0.80 check string for nil first)
                    if let folder = folder, !folder.isEmpty {
                        faxFrame?.dumpCurrentFrameToFolder(folder)      //  v0.81 use FAXFrame to dump
                    }
                }
            }
        }
        //  update all touched scanlines
        if vsyncState == VSYNCWAIT && !paused {
            if drawLock.try() {
                let row = faxFrame.drawLineAndAdvanceRow()
                //  reposition scroller if image is larger than the view, and refresh display if needed
                let pos = FAXDisplay.cTruncInt(Float(row) - 4 - viewHeight)
                if pos >= 0 { setPosition(pos) }
                self.performSelector(onMainThread: #selector(refreshImage), with: nil, waitUntilDone: true)
                drawLock.unlock()
                faxFrame?.setFrameMark(1)
            }
        }
    }

    @objc func drawCount() -> Int32 {
        return FAXDisplay.drawCountValue
    }

    //  called from redrawThread
    @objc func redrawFAX() {
        drawLock.lock()
        faxFrame?.redrawFrame()
        drawLock.unlock()
        self.performSelector(onMainThread: #selector(refreshImage), with: nil, waitUntilDone: true)
    }

    //  Data sample received from FAXReceiver.
    //  Received values are bi-polar, black about -0.23 and white about +0.23
    //  (-.244 to +.244 for DWD).  Stored into the backing buffer as an 8-bit value,
    //  with black at level 32 and white at level 224.
    @objc(addPixel:)
    func addPixel(_ value: Float) {
        //  scale input so black is about 16 and white about 240 in a 0-255 scale
        let f: Float
        if dev850 {
            //  v0.73  (+,-)425 Hz deviation for DWD
            f = (value + 0.279) * 459
        } else {
            //  (+,-)400
            f = (value + 0.263) * 485
        }
        var v = FAXDisplay.cTruncInt(f)
        if v < 0 { v = 0 } else if v > 255 { v = 255 }

        faxFrame?.addPixel(v)

        if !running { return }

        if imageParametersChanged {
            faxFrame?.setSamplingParameters()
            redrawFAX()
            imageParametersChanged = false
        }
        if (faxFrame?.passedMark().boolValue ?? false) && updateLock.try() {
            //  skip this step if busy
            outputLine()
            updateLock.unlock()
        }
    }

    //  v0.73
    @objc(setDeviation:)
    func setDeviation(_ state: Int32) {
        dev850 = (state != 0)
    }

    //  connect actions to Nib
    override func awakeFromNib() {
        updateLock = NSLock()
        drawLock = NSLock()
        firstDraw = true
        super.awakeFromNib()
        ppmValue = clockOffsetField?.floatValue ?? 0            //  A/D clock adjustment
        runLight?.backgroundColor = .red

        if var sframe = scroller?.frame {
            sframe.origin.y += 30.0
            scroller?.frame = sframe
        }

        scrollerHeight = 2400
        viewHeight = Float(self.bounds.size.height) + 11
        scroller?.floatValue = 0.0
        scroller?.minValue = 0.0
        scroller?.maxValue = Double(scrollerHeight)
        unconditionalSetPosition(0)

        //  clear both the row number of the display image and the pointer to the backingBuffer
        faxFrame?.resetFrame()

        setInterface(halfButton, to: #selector(scaleChanged(_:)))
        setInterface(blackLevelSlider, to: #selector(grayscaleChanged))
        setInterface(contrastSlider, to: #selector(grayscaleChanged))
        setInterface(clockOffsetField, to: #selector(ppmChanged))
        setInterface(clockOffsetStepper, to: #selector(ppmStepped))
        setInterface(pauseButton, to: #selector(pauseChanged))
        setInterface(newButton, to: #selector(newChanged))
        setInterface(saveButton, to: #selector(savePushed))
        setInterface(scroller, to: #selector(scrollBufferFromScroller))
    }

    @objc func updateRequest() {
        if updateRequested { return }
        updateRequested = true
        if updateLock.try() {
            redrawFAX()
            updateLock.unlock()
        }
        updateRequested = false
    }

    //  action for half/full button
    @objc(scaleChanged:)
    func scaleChanged(_ button: NSButton?) {
        let halfSize = (button?.state != .on)
        faxFrame?.setHalfSize(DarwinBoolean(halfSize))
        button?.title = halfSize ? NSLocalizedString("Half", comment: "") : NSLocalizedString("Full", comment: "")

        let oldHeight = FAXDisplay.cTruncInt(scrollerHeight)
        scrollerHeight = halfSize ? 2400 : 4800
        let oldPos = scroller?.intValue ?? 0
        scroller?.maxValue = Double(scrollerHeight)
        scroller?.intValue = FAXDisplay.cTruncInt(Float(oldPos) * scrollerHeight / Float(oldHeight))
        updateRequest()
        self.enclosingScrollView?.hasHorizontalScroller = !halfSize
    }

    //  v0.80 for plist
    @objc(setupScale:)
    func setupScale(_ full: Bool) {
        halfButton?.state = full ? .on : .off
        scaleChanged(halfButton)
    }

    @objc func scaleIsFullSize() -> Bool {
        return halfButton?.state == .on
    }

    @objc func grayscaleChanged() {
        let blackLevel = nominalBlackLevel - (blackLevelSlider?.floatValue ?? 0)
        let contrast = nominalContrast - (contrastSlider?.floatValue ?? 0)
        faxFrame?.setGrayscale(from: blackLevel, to: blackLevel + contrast)
        updateRequest()
    }

    @objc func ppmChanged() {
        ppmValue = Float(FAXDisplay.cTruncInt(clockOffsetField?.floatValue ?? 0))    //  A/D clock adjustment
        clockOffsetStepper?.floatValue = ppmValue
        faxFrame?.setPPM(ppmValue)
        imageParametersChanged = true
    }

    @objc func ppmStepped() {
        var stepsSinceMouseDown = (clockOffsetStepper as? FAXStepper)?.steps() ?? 0
        ppmValue = Float(FAXDisplay.cTruncInt(clockOffsetStepper?.floatValue ?? 0))  //  A/D clock adjustment
        if stepsSinceMouseDown > 1 {
            if stepsSinceMouseDown > 5 { stepsSinceMouseDown = 5 }
            ppmValue = ppmValue + Float(stepsSinceMouseDown) * (ppmValue - (clockOffsetField?.floatValue ?? 0))
            clockOffsetStepper?.floatValue = ppmValue
        }
        clockOffsetField?.floatValue = ppmValue
        ppmChanged()

        imageParametersChanged = true
    }

    @objc func newChanged() {
        if pauseButton?.state == .on {
            pauseButton?.state = .off
            pauseButton?.title = NSLocalizedString("Pause", comment: "")
            runLight?.backgroundColor = .green
            running = true
        }
        start()
    }

    @objc func savePushed() {
        let folder = tempFolder?.stringValue
        faxFrame?.dumpCurrentFrameToFolder(folder)
    }

    @objc func pauseChanged() {
        if pauseButton?.state == .on {
            pauseButton?.title = NSLocalizedString("Resume", comment: "")
            running = false
            paused = true
            runLight?.backgroundColor = .red
        } else {
            pauseButton?.title = NSLocalizedString("Pause", comment: "")
            runLight?.backgroundColor = .green
            running = true
            paused = false
            if vsyncState == VSYNCSTARTWAIT { vsyncState = VSYNCWAIT }
        }
    }

    @objc(setPPM:)
    override func setPPM(_ value: Float) {
        ppmValue = value
        faxFrame?.setPPM(ppmValue)
        clockOffsetField?.floatValue = ppmValue
        clockOffsetStepper?.floatValue = ppmValue
        faxFrame?.setSamplingParameters()
    }

    @objc(setFolder:)
    func setFolder(_ folder: String) {
        tempFolder?.stringValue = folder
    }

    @objc func folder() -> String {
        return tempFolder?.stringValue ?? ""
    }

    @objc(selectFolder:)
    func selectFolder(_ sender: Any?) {
        //  Modernized: the original used the (now removed) -runModalForTypes: with
        //  a garbage type to force directory-only selection, plus -filename.  The
        //  modern NSOpenPanel API (canChooseFiles=false, .url) is behaviorally
        //  equivalent (directories only) and compiles on current SDKs.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.nameFieldLabel = "Select Directory"
        if panel.runModal() == .OK {
            if let url = panel.url {
                let current = url.path
                tempFolder?.stringValue = (current as NSString).abbreviatingWithTildeInPath
            }
        }
    }

    @objc(clearFolder:)
    func clearFolder(_ sender: Any?) {
        let current = tempFolder?.stringValue ?? ""
        if current.isEmpty { return }
        tempFolder?.stringValue = ""
    }

    //  horizontal positioning
    override func mouseDown(with event: NSEvent) {
        let position = self.convert(event.locationInWindow, from: nil).x
        faxFrame?.mouseDown(at: Float(position))
        updateRequest()
    }
}
