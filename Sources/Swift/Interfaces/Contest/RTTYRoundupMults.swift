//
//  RTTYRoundupMults.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/26/05.
//
//  Swift port of RTTYRoundupMults.m.  Tracks worked multipliers (states /
//  call areas) for the RTTY Roundup contest and colors the mults window.
//

import Cocoa

private let kLatin1 = String.Encoding.isoLatin1.rawValue

@objc(RTTYRoundupMults)
class RTTYRoundupMults: NSObject {

    //  outlets connected by RTTYRoundupMults.nib -- names must match nib keys exactly
    @objc var rrMults: NSMatrix!
    @objc var callAreas: NSMatrix!
    @objc var veArea: NSTextField!

    private var workedColor: NSColor = .black

    override func awakeFromNib() {
        workedColor = NSColor(calibratedRed: 0, green: 0.7, blue: 0, alpha: 0.9)
    }

    /* local */
    private func stateMultWindow() -> NSWindow? {
        let cell = rrMults.cell(atRow: 0, column: 0) as? NSCell
        return cell?.controlView?.window
    }

    private func workedAllVE(_ color: NSColor) {
        veArea.textColor = color
    }

    private func workedAllArea(_ area: Int, color: NSColor) {
        var a = area - 1
        if a < 0 { a = 9 }
        if let cell = callAreas.cell(atRow: a, column: 0) as? NSTextFieldCell {
            cell.textColor = color
        }
    }

    private func updateCallArea(_ area: Int, statelist rawStateList: UnsafeMutablePointer<StateList>) {
        if area > 20 {
            var i = 0
            while i < 64 {
                if rawStateList[i].abbrev!.pointee == Int8(UInt8(ascii: "*")) { break }
                let j = Int(rawStateList[i].area)
                if j > 20 && rawStateList[i].worked == 0 { return }
                i += 1
            }
            workedAllVE(workedColor)
            return
        }

        var i = 0
        while i < 64 {
            if rawStateList[i].abbrev!.pointee == Int8(UInt8(ascii: "*")) { break }
            let j = Int(rawStateList[i].area)
            if j == area && rawStateList[i].worked == 0 { return }
            i += 1
        }
        workedAllArea(area, color: workedColor)
    }

    /* local */
    private func colorRow(_ row: Int, column: Int, color: NSColor, string: String?) {
        if let cell = rrMults.cell(atRow: row, column: column) as? NSTextFieldCell {
            cell.textColor = color
            if let string = string { cell.stringValue = string }
        }
    }

    @objc(updateMult:statelist:)
    func updateMult(_ p: UnsafeMutablePointer<ContestQSO>, statelist rawStateList: UnsafeMutablePointer<StateList>) {
        var i = 0
        while i < 64 {
            if rawStateList[i].abbrev!.pointee == Int8(UInt8(ascii: "*")) { break }
            if strcmp(rawStateList[i].abbrev, p.pointee.exchange) == 0 {
                rawStateList[i].worked += 1
                if rawStateList[i].worked == 1 {
                    colorRow(Int(rawStateList[i].y), column: Int(rawStateList[i].x), color: workedColor, string: nil)
                    updateCallArea(Int(rawStateList[i].area), statelist: rawStateList)
                }
                return
            }
            i += 1
        }
    }

    @objc(showWindow:)
    func showWindow(_ rawStateList: UnsafeMutablePointer<StateList>) {
        var i = 0
        while i < 64 {
            if rawStateList[i].abbrev!.pointee == Int8(UInt8(ascii: "*")) { break }
            let color: NSColor = (rawStateList[i].worked != 0) ? workedColor : NSColor.black
            let string = NSString(cString: rawStateList[i].abbrev!, encoding: kLatin1) as String?
            colorRow(Int(rawStateList[i].y), column: Int(rawStateList[i].x), color: color, string: string)
            i += 1
        }
        for k in 0..<10 { updateCallArea(k, statelist: rawStateList) }
        updateCallArea(21, statelist: rawStateList)

        if let window = stateMultWindow() {
            (window as? NSPanel)?.isFloatingPanel = false
            window.orderFront(self)
        }
    }
}
