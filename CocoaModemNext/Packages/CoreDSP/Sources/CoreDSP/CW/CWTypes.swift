//
//  CWTypes.swift
//  CoreDSP
//
//  Plain Swift structs for the C types that lived in the old app's
//  CWPipelineTypes.h bridging header (ElementType / MorseTiming), shared here
//  between CWPipeline / CWSpeedPipeline / CWMatchedFilter exactly as the C
//  struct was shared across CWMatchedFilter.m and the (then-Swift) pipeline
//  files. `Boolean valid` -> Swift Bool (DarwinBoolean was only needed for the
//  Objective-C bridge, which no longer exists).
//

import Foundation

//  was ElementType in CWPipelineTypes.h
struct CWElementType {
    var state: Int32 = 0
    var interval: Int32 = 1
    var max: Float = 0
    var min: Float = 1
    var valid: Bool = false
}

//  was MorseTiming in CWPipelineTypes.h
struct CWMorseTiming {
    var interElement: Float = 0
    var interSymbol: Float = 0
    var dit: Float = 0
    var dash: Float = 0
    var speed: Float = 0
}

//  C truncates a float to (signed) int toward zero and lets out-of-range
//  values wrap; guarded so a NaN/out-of-range value never traps (see
//  cmPhaseTrunc in CMNCO.swift for the Double equivalent used elsewhere).
@inline(__always)
func cwFloatToInt32(_ x: Float) -> Int32 {
    if x.isNaN { return 0 }
    let t = x.rounded(.towardZero)
    if t >= 2147483647.0 { return Int32.max }
    if t <= -2147483648.0 { return Int32.min }
    return Int32(t)
}
