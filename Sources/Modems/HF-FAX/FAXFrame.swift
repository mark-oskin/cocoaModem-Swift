//
//  FAXFrame.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/24/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//  Swift port of FAXFrame.m.
//
//  The BackingFrame C struct and the MAXFAXHEIGHT/MAXBACKING/BACKGROUND macros
//  remain in FAXFrame.h (with the @interface removed) so both this class and
//  the still-Obj-C FAXView / FAXDisplay share them.  All backing-store and
//  intensity indices are wrapped into range (modPos / clamp) so a bad
//  decimation value can never index out of bounds.
//

import Cocoa

@objc(FAXFrame)
class FAXFrame: NSObject {

    private static let maxFaxHeight = 3200
    private static let maxBacking = (3200 + 64) * 2000       //  MAXBACKING
    private static let background: UInt8 = 112               //  BACKGROUND (gray)

    private var imageObj: NSImage!
    private var bitmapRep: NSBitmapImageRep!
    private let frame: UnsafeMutablePointer<BackingFrame>

    private var bitmapRepLock: NSLock!
    private var imageLock: NSLock!
    private var dumpLock: NSLock!

    private let pixelBuffer: UnsafeMutablePointer<UInt8>
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var rowBytes: Int32 = 0
    private var lsize: Int32 = 0
    private var viewHeight: Int32 = 0
    private var scrollOffset: Int32 = 0

    //  resampling by 11025/(IOC*pi*2) nominal decimation
    private var IOC: Int32 = 0
    private var imageWidth: Float = 0
    private var actualWidth: Int32 = 0
    private var decimationRatio: Float = 1
    private var inputImageWidth: Float = 0
    private var ppm: Float = 0

    //  v0.81 save folder
    private var alternateFolder: String?

    //  ---- guarded conversions / index helpers -----------------------------

    @inline(__always) private func cInt(_ x: Float) -> Int32 {
        if x.isNaN { return 0 }
        let t = x.rounded(.towardZero)
        if t >= 2147483647.0 { return Int32.max }
        if t <= -2147483648.0 { return Int32.min }
        return Int32(t)
    }

    @inline(__always) private func cInt(_ x: Double) -> Int32 {
        if x.isNaN { return 0 }
        let t = x.rounded(.towardZero)
        if t >= 2147483647.0 { return Int32.max }
        if t <= -2147483648.0 { return Int32.min }
        return Int32(t)
    }

    @inline(__always) private func dInt(_ x: Double) -> Int {
        if x.isNaN { return 0 }
        let t = x.rounded(.towardZero)
        if t >= 9.0e18 { return Int.max }
        if t <= -9.0e18 { return Int.min }
        return Int(t)
    }

    @inline(__always) private func modPos(_ x: Int, _ m: Int) -> Int {
        let r = x % m
        return r < 0 ? r + m : r
    }

    @inline(__always) private func backingByte(_ i: Int) -> UInt8 {
        return frame.pointee.backing![modPos(i, FAXFrame.maxBacking)]
    }

    @inline(__always) private func intensityByte(_ i: Int) -> UInt8 {
        var j = i
        if j < 0 { j = 0 } else if j > 255 { j = 255 }
        return frame.pointee.intensity![j]
    }

    //  ---- private image rep builders --------------------------------------

    private func createNewImageRep(_ pixbuf: UnsafeMutablePointer<UInt8>, topOffset offset: Int32, height length: Int32) -> NSBitmapImageRep? {
        var plane = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: 3)
        plane[0] = pixbuf + Int(offset) * Int(rowBytes)     //  top of image
        return NSBitmapImageRep(bitmapDataPlanes: &plane,
                                pixelsWide: Int(width),
                                pixelsHigh: Int(length),
                                bitsPerSample: 8,
                                samplesPerPixel: 1,
                                hasAlpha: false,
                                isPlanar: false,
                                colorSpaceName: .calibratedWhite,
                                bytesPerRow: Int(rowBytes),
                                bitsPerPixel: 8)
    }

    private func createNewHalfsizeImageRep(_ pixbuf: UnsafeMutablePointer<UInt8>, height length: Int32) -> NSBitmapImageRep? {
        var plane = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: 3)
        plane[0] = pixbuf                                    //  top of image
        return NSBitmapImageRep(bitmapDataPlanes: &plane,
                                pixelsWide: Int(width) / 2,
                                pixelsHigh: Int(length) / 2,
                                bitsPerSample: 8,
                                samplesPerPixel: 1,
                                hasAlpha: false,
                                isPlanar: false,
                                colorSpaceName: .calibratedWhite,
                                bytesPerRow: Int(rowBytes),
                                bitsPerPixel: 8)
    }

    //  A FAXFrame consists of the NSImage, NSImageRep and a BackingFrame
    @objc(initWidth:height:)
    init(width w: Int32, height h: Int32) {
        width = w
        height = h
        rowBytes = ((width + 3) / 4) * 4
        lsize = rowBytes * height

        //  local buffer to NSBitmapImageRep
        let bufsize = Int(rowBytes) * FAXFrame.maxFaxHeight * 3
        pixelBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufsize)
        pixelBuffer.initialize(repeating: FAXFrame.background, count: bufsize)

        scrollOffset = 0

        //  create backing memory
        frame = UnsafeMutablePointer<BackingFrame>.allocate(capacity: 1)
        frame.initialize(to: BackingFrame())
        frame.pointee.halfSize = true
        let intensity = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
        intensity.initialize(repeating: 0, count: 256)
        frame.pointee.intensity = intensity
        let backing = UnsafeMutablePointer<UInt8>.allocate(capacity: FAXFrame.maxBacking)
        backing.initialize(repeating: 0, count: FAXFrame.maxBacking)
        frame.pointee.backing = backing

        alternateFolder = nil

        super.init()

        bitmapRep = createNewImageRep(pixelBuffer, topOffset: scrollOffset, height: height)
        bitmapRepLock = NSLock()
        imageObj = NSImage()
        imageObj.addRepresentation(bitmapRep)
        imageLock = NSLock()
        dumpLock = NSLock()
    }

    deinit {
        frame.pointee.backing?.deallocate()
        frame.pointee.intensity?.deallocate()
        pixelBuffer.deallocate()
        frame.deinitialize(count: 1)
        frame.deallocate()
    }

    @objc func resetFrame() {
        frame.pointee.displayRow = 0
        frame.pointee.origin = 0
        frame.pointee.input = 0
        frame.pointee.mark = 0
        frame.pointee.correction = 0.0
    }

    // v0.80 generate a new bitmapImageRep (with proper scrollOffset) to fool the Snow Leopard cache
    private func updateGrayImageRep() -> NSBitmapImageRep {
        bitmapRepLock.lock()
        bitmapRep = createNewImageRep(pixelBuffer, topOffset: scrollOffset, height: height)
        bitmapRepLock.unlock()
        return bitmapRep
    }

    @objc func image() -> NSImage {
        return imageObj
    }

    @objc func backingFrame() -> UnsafeMutablePointer<BackingFrame> {
        return frame
    }

    @objc func passedMark() -> DarwinBoolean {
        return DarwinBoolean(frame.pointee.input > frame.pointee.mark)
    }

    //  Swap to a new NSBitmapImageRep, since Snow Leopard appears to cache it
    //  Called whenever the image changes and needs to be displayed on the screen
    @objc func swapImageRep() {
        imageLock.lock()
        imageObj.removeRepresentation(bitmapRep)
        imageObj.addRepresentation(updateGrayImageRep())
        imageLock.unlock()
    }

    //  image a line into the backing store
    @objc(drawLineAtRow:)
    func drawLineAtRow(_ row: Int32) {
        let halfSize = frame.pointee.halfSize.boolValue
        let skipRow = Int(frame.pointee.skipRow)

        if halfSize {
            if (row & 1) == 0 { return }

            let previousRow = (Int(row) + FAXFrame.maxFaxHeight - 1) % FAXFrame.maxFaxHeight   // previous scanline
            //  process half sized image only once per scanline
            let imagePointerOffset = modPos((Int(row) - skipRow) / 2, FAXFrame.maxFaxHeight)
            var dest = pixelBuffer + imagePointerOffset * Int(rowBytes)

            //  beginning of line (0) and previous line (1)
            let p = Double(frame.pointee.origin) + Double(frame.pointee.horizontalOffset) * Double(decimationRatio) + 0.5
            var p0 = p + Double(row) * Double(inputImageWidth)
            var p1 = p + Double(previousRow) * Double(inputImageWidth)

            var i = 0
            while i < 1808 {
                if i == 0 || i == 1806 {
                    //  nearest neighbor average for first and last sample of scanline
                    var avg = Int(backingByte(dInt(p0))) + Int(backingByte(dInt(p1)))
                    p0 += Double(decimationRatio); p1 += Double(decimationRatio)
                    avg += Int(backingByte(dInt(p0))) + Int(backingByte(dInt(p1)))
                    dest.pointee = intensityByte(avg / 4); dest += 1
                } else {
                    //  Hamming window the fast scan direction
                    var sum = Double(backingByte(dInt(p0))) + Double(backingByte(dInt(p1)))
                    p0 += Double(decimationRatio); p1 += Double(decimationRatio)
                    sum += (Double(backingByte(dInt(p0))) + Double(backingByte(dInt(p1)))) * 2.348
                    p0 += Double(decimationRatio); p1 += Double(decimationRatio)
                    sum += Double(backingByte(dInt(p0))) + Double(backingByte(dInt(p1)))
                    let avg = dInt((sum + 0.5) / 8.696)
                    dest.pointee = intensityByte(avg); dest += 1
                }
                i += 2
            }
        } else {
            // full sized
            let imagePointerOffset = modPos(Int(row) - skipRow, FAXFrame.maxFaxHeight)
            var dest = pixelBuffer + imagePointerOffset * Int(rowBytes)
            var p0 = Double(frame.pointee.origin) + Double(frame.pointee.horizontalOffset) * Double(decimationRatio) + Double(row) * Double(inputImageWidth) + 0.5  //  v0.57d

            for _ in 0..<1809 {
                let avg = Int(backingByte(dInt(p0)))
                p0 += Double(decimationRatio)
                dest.pointee = intensityByte(avg); dest += 1
            }
        }
        perform(#selector(swapImageRep), on: Thread.main, with: nil, waitUntilDone: true)
    }

    private func drawEmptyLineAtRow(_ row: Int32) {
        let skipRow = Int(frame.pointee.skipRow)
        if frame.pointee.halfSize.boolValue {
            if (row & 1) == 0 { return }
            let imagePointerOffset = modPos((Int(row) - skipRow) / 2, FAXFrame.maxFaxHeight)
            var dest = pixelBuffer + imagePointerOffset * Int(rowBytes)
            var i = 0
            while i < 1808 {
                dest.pointee = UInt8(truncatingIfNeeded: dInt(Double(row) * 0.1)); dest += 1
                i += 2
            }
        } else {
            let imagePointerOffset = modPos(Int(row) - skipRow, FAXFrame.maxFaxHeight)
            var dest = pixelBuffer + imagePointerOffset * Int(rowBytes)
            for _ in 0..<1809 { dest.pointee = FAXFrame.background; dest += 1 }
        }
    }

    @objc(clearSwath:)
    func clearSwath(_ ht: Int32) {
        //  clear a swath of NSImage bitmap, this leaves a 32 pixel black space to old image
        pixelBuffer.update(repeating: FAXFrame.background, count: Int(rowBytes) * 32)
    }

    @objc(drawLineInFrameAtRow:refresh:)
    func drawLineInFrame(atRow row: Int32, refresh: DarwinBoolean) -> Int32 {
        if row < frame.pointee.skipRow { return 0 }

        drawLineAtRow(row)

        if refresh.boolValue {
            var r = row
            if frame.pointee.halfSize.boolValue { r /= 2 }
            //  erase a line that is 32 pixels lower, leaving a 32 pixel black border to the old image
            let p = Int(r) - Int(frame.pointee.skipRow) + 32
            if p >= 0 && p < FAXFrame.maxFaxHeight {
                let dest = pixelBuffer + p * Int(rowBytes)
                dest.update(repeating: FAXFrame.background, count: Int(rowBytes))
            }
            return Int32(truncatingIfNeeded: p)
        }
        return 0
    }

    @objc func drawLineAndAdvanceRow() -> Int32 {
        let row = frame.pointee.displayRow
        frame.pointee.displayRow = row &+ 1
        return drawLineInFrame(atRow: row, refresh: true)
    }

    @objc func redrawFrame() {
        //  update all visible scanlines
        let n = frame.pointee.skipRow
        let m = frame.pointee.displayRow

        var i = n
        while i < m { drawLineAtRow(i); i += 1 }

        frame.pointee.mark = frameOffsetForSample(1, ofRow: frame.pointee.displayRow &+ 1)
        setSamplingParameters()
    }

    //  set the horizontal offset (adjusted by decimation ratio)
    @objc(setHorizontalOffset:)
    func setHorizontalOffset(_ position: Int32) {
        frame.pointee.horizontalOffset = frame.pointee.horizontalOffset &+ cInt(Float(position) / decimationRatio)
        frame.pointee.horizontalOffset %= 1809
        frame.pointee.skipRow = frame.pointee.displayRow
    }

    @objc(setScrollOffset:)
    func setScrollOffset(_ offset: Int32) {
        scrollOffset = offset
    }

    //  position frame parameters to the start of a new image
    @objc func startNewImage() {
        //  new image starts at the end of old image
        frame.pointee.origin = (frame.pointee.horizontalOffset &+ frameOffsetForSample(0, ofRow: frame.pointee.displayRow)) % Int32(FAXFrame.maxBacking)
        frame.pointee.displayRow = 0
        frame.pointee.skipRow = 0
        frame.pointee.input = 0
        //  trigger point for dumping row
        frame.pointee.mark = frameOffsetForSample(2, ofRow: frame.pointee.displayRow &+ 1)
        clearSwath(32)
    }

    //  create a grayscale table (recomputed each time the black level / contrast sliders change)
    @objc(setGrayscaleFrom:to:)
    func setGrayscale(from black: Float, to white: Float) {
        let range = white - black
        for i in 0..<256 {
            var v = cInt((Float(i) - black) * 256.0 / range)
            if v < 0 { v = 0 } else if v > 255 { v = 255 }
            frame.pointee.intensity![i] = UInt8(v)
        }
    }

    @objc(addPixel:)
    func addPixel(_ v: Int32) {
        let index = Int((frame.pointee.origin &+ frame.pointee.input) % Int32(FAXFrame.maxBacking))
        frame.pointee.backing![modPos(index, FAXFrame.maxBacking)] = UInt8(truncatingIfNeeded: v)
        frame.pointee.input = frame.pointee.input &+ 1
    }

    @objc(pixelAtSample:ofRow:)
    func pixelAtSample(_ h: Int32, ofRow v: Int32) -> Int32 {
        let offset = Int((frame.pointee.origin &+ frameOffsetForSample(h, ofRow: v)) % Int32(FAXFrame.maxBacking))
        return Int32(frame.pointee.backing![modPos(offset, FAXFrame.maxBacking)])
    }

    //  compute offset from frame.origin into the oversample buffer for a real pixel at (h,v)
    @objc(frameOffsetForSample:ofRow:)
    func frameOffsetForSample(_ h: Int32, ofRow v: Int32) -> Int32 {
        return cInt((Double(h) + Double(frame.pointee.horizontalOffset)) * Double(decimationRatio) + Double(v) * Double(inputImageWidth) + 0.5)
    }

    @objc func frameOrigin() -> Int32 {
        return frame.pointee.origin
    }

    //  -setSamplingParameters will pick this up
    @objc(setPPM:)
    func setPPM(_ p: Float) {
        ppm = p
    }

    @objc(setHalfSize:)
    func setHalfSize(_ isHalfSize: DarwinBoolean) {
        frame.pointee.halfSize = isHalfSize
    }

    //  change decimation ratio and fractional width of the FAX transmission
    @objc func setSamplingParameters() {
        IOC = 576                                       // fix IOC to 576 for now
        //  resampling parameters
        imageWidth = Float(Double(IOC) * 3.1415926)     // fractional width
        actualWidth = cInt(imageWidth)                  // integral width
        //  decimation
        decimationRatio = Float((11025.0 / (Double(IOC) * 3.1415926535 * 2)) * (1.0 + Double(ppm) / 1000000.0))
        inputImageWidth = imageWidth * decimationRatio  // actual 1/2 second of data
    }

    @objc func markDisplayRow() {
        frame.pointee.rows = frame.pointee.displayRow
    }

    @objc(setFrameMark:)
    func setFrameMark(_ offset: Int32) {
        frame.pointee.mark = frameOffsetForSample(1, ofRow: frame.pointee.displayRow &+ offset)
    }

    //  horizontal positioning
    @objc(mouseDownAt:)
    func mouseDown(at positionIn: Float) {
        var position = positionIn
        if frame.pointee.halfSize.boolValue { position *= 2 }
        if position < 0 || position > 1808 { return }
        frame.pointee.horizontalOffset = frame.pointee.horizontalOffset &+ cInt(position)
        frame.pointee.horizontalOffset %= 1809
        pixelBuffer.update(repeating: FAXFrame.background, count: Int(lsize))
    }

    // ---------------- save to PDF --------------------

    private func drawFAXFromFrame(_ frame: UnsafeMutablePointer<BackingFrame>) {
        print("FAXFrame: need to implement drawFAXFromFrame")
    }

    //  this is executed in the main thread
    @objc(dumpFrame:)
    func dumpFrame(_ folderIn: String) {
        var folder = (folderIn as NSString).expandingTildeInPath

        //  v0.81 find dimensions and make copy of the bitmap memory
        var rows = Int(frame.pointee.displayRow) - Int(frame.pointee.skipRow) + 1
        if rows < 1 { rows = 1 }
        let halfsize = frame.pointee.halfSize.boolValue

        let imageBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(rowBytes) * rows)
        imageBuffer.update(from: pixelBuffer, count: Int(rowBytes) * rows)
        defer { imageBuffer.deallocate() }

        //  now check if folder exists
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) == false || isDirectory.boolValue == false {
            let alert = NSAlert()
            alert.messageText = "FAX folder not found.  Save to your home directory instead?"
            alert.informativeText = "\nFolder \(folder) is not found.\n"
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            if alert.runModal() != .alertFirstButtonReturn { return }
            let home = ("~" as NSString).expandingTildeInPath
            alternateFolder = home
            folder = home
        }
        let name = (folder as NSString).expandingTildeInPath + "/fax "
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HHmm'.pdf'"
        df.timeZone = TimeZone(secondsFromGMT: 0)
        let date = df.string(from: Date())
        let filename = name + date

        let imageRep: NSBitmapImageRep?
        if halfsize {
            imageRep = createNewHalfsizeImageRep(imageBuffer, height: Int32(rows))
        } else {
            imageRep = createNewImageRep(imageBuffer, topOffset: 0, height: Int32(rows))
        }
        guard let rep = imageRep, let imageData = rep.tiffRepresentation else { return }

        //  create a scaled PDF version of the image
        guard let frameImage = NSImage(data: imageData) else { return }
        let size = frameImage.size
        let pdfView = NSImageView()
        pdfView.image = frameImage
        pdfView.frame = NSMakeRect(0.0, 0.0, size.width, size.height)
        var pdfRect = pdfView.bounds
        if halfsize {
            pdfRect.origin.y = pdfRect.size.height - CGFloat(rows) * 0.5
            pdfRect.size.height = CGFloat(rows) * 0.5
        }
        let pdfData = pdfView.dataWithPDF(inside: pdfRect)
        try? pdfData.write(to: URL(fileURLWithPath: filename), options: .atomic)
    }

    @objc(dumpCurrentFrameToFolder:)
    func dumpCurrentFrameToFolder(_ folderIn: String?) {
        dumpLock.lock()
        var folder = folderIn
        if let alt = alternateFolder { folder = alt }
        if folder == nil || folder!.isEmpty {
            let alert = NSAlert()
            alert.messageText = "FAX folder has not been set up.  Save to your home directory instead?"
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            if alert.runModal() != .alertFirstButtonReturn {
                dumpLock.unlock()
                return
            }
            let home = ("~" as NSString).expandingTildeInPath
            alternateFolder = home
            folder = home
        }
        perform(#selector(dumpFrame(_:)), on: Thread.main, with: folder, waitUntilDone: true)
        dumpLock.unlock()
    }
}
