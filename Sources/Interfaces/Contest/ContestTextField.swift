//
//  ContestTextField.swift
//  cocoaModem
//
//  Created by Kok Chen on 11/17/04.
//  Swift port of ContestTextField.m.
//

import Cocoa

//  Panther centering-offset tables (indexed 0...20 by point size)
private let lucidaGrandeOffset: [Float] = [ 0, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 1, 0, 1, 1, -1, -1, -1, -1 ]
private let verdanaOffset: [Float]      = [ 0, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 1, -2, -3, -4, -5, -6, -7, -8 ]
private let tektonOffset: [Float]       = [ 0, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 2, 2, 2, 1, 1, 2, -1, 0, 0 ]
private let monacoOffset: [Float]       = [ 0, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 2, 2, 1, -4, -4, -4, -5, -7, -8, -8 ]

@objc(ContestTextField)
class ContestTextField: OptionTextField {

    private var editor: NSText?

    //  C truncates a float to (signed) int toward zero.  Guard against NaN so
    //  we never index the offset table out of range.
    @inline(__always)
    private func cInt(_ x: CGFloat) -> Int {
        if x.isNaN { return 0 }
        return Int(x.rounded(.towardZero))
    }

    override func awakeFromNib() {
        editor = window?.fieldEditor(true, for: self)
        //  accepts fontChanges messages here
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(setContestFont(_:)),
                                               name: NSNotification.Name("ContestFont"),
                                               object: nil)
    }

    @objc(sameFont:asBase:)
    func sameFont(_ name: String, asBase base: String) -> Bool {
        if name == base { return true }
        let length = base.count
        if name.count < length { return false }
        return String(name.prefix(length)) == base
    }

    //  NSNotification with name "ContestFont" is sent when font changes
    @objc(setContestFont:)
    func setContestFont(_ notify: Notification) {
        guard let font = notify.object as? NSFont else { return }
        let size = font.pointSize
        let name = font.fontName

        var y: Float = 0
        var index = cInt(size + 0.5)
        if index > 20 { index = 20 }
        if index < 0 { index = 0 }

        if sameFont(name, asBase: "LucidaGrande") { y = lucidaGrandeOffset[index] }
        else if sameFont(name, asBase: "Verdana") { y = verdanaOffset[index] }
        else if sameFont(name, asBase: "Tekton") { y = tektonOffset[index] }
        else if sameFont(name, asBase: "Monaco") { y = monacoOffset[index] }
        else { y = verdanaOffset[index] }

        var matrix = [CGFloat](repeating: 0, count: 6)
        matrix[0] = size
        matrix[3] = size
        matrix[5] = CGFloat(y) - 2

        self.font = NSFont(name: font.fontName, matrix: matrix)

        //  redraw
        self.stringValue = self.stringValue
    }
}
