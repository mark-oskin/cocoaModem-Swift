//
//  FAXTypes.swift
//  CoreDSP
//
//  The old cocoaModem app defined BackingFrame (and the MAXFAXHEIGHT /
//  MAXBACKING / BACKGROUND macros) in a bridging-header-only C file,
//  FAXFrame.h, so both the (still Objective-C at the time) FAXView/FAXDisplay
//  and the Swift FAXFrame class could share them. A pure SwiftPM package has
//  no bridging header, so -- mirroring the CMDataStream / CMAnalyticBuffer
//  precedent in CoreDSPTypes.swift -- this becomes a plain Swift struct local
//  to the HF-FAX subfolder, holding only the scalar bookkeeping fields; the
//  large byte buffers the original C struct pointed at (`backing`,
//  `intensity`) are owned directly by FAXFrame as heap allocations instead
//  (same pattern CoreDSPTypes.swift uses for CMAnalyticBuffer.re/im).
//

import Foundation

/// MAXFAXHEIGHT from FAXFrame.h.
let kFAXMaxHeight: Int32 = 3200
/// MAXBACKING from FAXFrame.h: (MAXFAXHEIGHT+64)*2000 -- 600-scanline headroom, 2000 samples wide.
let kFAXMaxBacking: Int = (3200 + 64) * 2000
/// BACKGROUND from FAXFrame.h (gray backdrop the original painted behind the live image).
let kFAXBackground: UInt8 = 112

/// Plain-Swift port of the `BackingFrame` C struct (FAXFrame.h). Field names
/// and meanings are unchanged; `backing`/`intensity` (raw byte pointers in the
/// original) are dropped from the struct itself and owned by FAXFrame instead.
struct BackingFrame {
    var origin: Int32 = 0                 //  index into the backing store; always < kFAXMaxBacking
    var rows: Int32 = 0
    var correction: Float = 0             //  fractional correction of frame (unused by the ported DSP path, kept for fidelity)
    var input: Int32 = 0                  //  next input location, offset from origin (can exceed kFAXMaxBacking)
    var mark: Int32 = 0                   //  offset (from origin) at which to next process data
    var horizontalOffset: Int32 = 0
    var halfSize: Bool = true
    var displayRow: Int32 = 0
    var skipRow: Int32 = 0
}
