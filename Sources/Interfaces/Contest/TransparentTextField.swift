//
//  TransparentTextField.swift
//  cocoaModem
//
//  Created by Kok Chen on 11/23/04.
//  Swift port of TransparentTextField.m.
//

import Cocoa

//  Panther centering-offset tables (indexed 0...20 by point size)
private let lucidaGrandeOffset: [Float] = [ 0, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 0, 1, 1, -1, -1, -1, -1 ]
private let verdanaOffset: [Float]      = [ 0, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 1, -2, -3, -4, -5, -6, -7, -8 ]
private let tektonOffset: [Float]       = [ 0, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 2, 2, 2, 1, 1, 2, -1, 0, 0 ]
private let monacoOffset: [Float]       = [ 0, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 2, 2, 1, -4, -4, -4, -5, -7, -8, -8 ]

//  transparent text field for use over a watermark (e.g., DUPE warning)
@objc(TransparentTextField)
class TransparentTextField: ContestTextField {

    private var ratio: Float = 0
    @objc var fieldType: Int32 = 0
    private var savedString: String = ""
    private var ignore: Bool = false

    //  C truncates a float to (signed) int toward zero.  Guard against NaN so
    //  we never index the offset table out of range.
    @inline(__always)
    private func cInt(_ x: CGFloat) -> Int {
        if x.isNaN { return 0 }
        return Int(x.rounded(.towardZero))
    }

    override func awakeFromNib() {
        //  accepts fontChanges messages here
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(setContestFont(_:)),
                                               name: NSNotification.Name("ContestFont"),
                                               object: nil)

        fieldType = 0
        savedString = ""
        ignore = false
        isBezeled = false
        isBordered = false          // cocoa screws up vertical positioning if transparent view is not bordered
        drawsBackground = false
    }

    //  kCallsignTextField, kExchangeTextField:  the fieldType property provides
    //  both the -fieldType getter and the -setFieldType: setter selectors.

    @objc(markAsSelected:)
    func markAsSelected(_ state: Bool) {
        isBordered = state
    }

    @objc(clickedString)
    func clickedString() -> String {
        return savedString
    }

    @objc(setIgnoreFirstResponder:)
    func setIgnoreFirstResponder(_ state: Bool) {
        ignore = state
    }

    //  clear savedString if the field is manually edited
    override func textShouldEndEditing(_ textObject: NSText) -> Bool {
        savedString = ""
        return super.textShouldEndEditing(textObject)
    }

    override var acceptsFirstResponder: Bool {
        return !ignore
    }

    //  save string in clicked string
    //  any non zero length string here would cause a click/control click to cause an IBAction
    override func becomeFirstResponder() -> Bool {
        savedString = self.stringValue
        if ignore {
            ignore = false
            return true
        }
        if super.becomeFirstResponder() {
            //  inform Contest object that a new field is selected
            NotificationCenter.default.post(name: NSNotification.Name("SelectNewField"), object: self)
            return true
        }
        return false
    }

    @objc(moveAbove)
    func moveAbove() {
        guard let view = superview else { return }
        removeFromSuperview()
        view.addSubview(self, positioned: .above, relativeTo: nil)
    }

    //  NSNotification with name "ContestFont" is sent when font changes
    @objc(setContestFont:)
    override func setContestFont(_ notify: Notification) {
        guard let font = notify.object as? NSFont else { return }
        let size = font.pointSize
        let name = font.fontName

        //  do some centering adjustments for Panther
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
        matrix[5] = CGFloat(y)

        self.font = NSFont(name: font.fontName, matrix: matrix)

        //  redraw
        self.stringValue = self.stringValue
    }
}
