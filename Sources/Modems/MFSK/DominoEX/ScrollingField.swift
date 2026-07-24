//
//  ScrollingField.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 6/24/09.
//  Copyright 2009 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of ScrollingField.m.  Horizontal text scrolling NSView.
//
//  Requires (via the bridging header) MFSKModes.h (DOMINOEX* mode tags) and
//  PrivateNSFont.h (NSFont -_defaultGlyphForChar:).

import Cocoa

@objc(ScrollingField)
class ScrollingField: NSView {

    private var textField: TextFieldForScrolling?
    private var stringValue = NSMutableString(capacity: 60)
    private var originalRect = NSRect.zero
    private var fontAdvance = [Float](repeating: 0, count: 256)
    private var currentFontAdvance: Float = 0
    private var glyph = [NSGlyph](repeating: 0, count: 256)
    private var scrollCount = 0
    private var extraPause = 0
    private var scrollRate = 1
    private var timer: Timer?
    private var currentMode = 0
    private var font: NSFont!
    private var busy = false

    private var backlogString = [unichar](repeating: 0, count: 2048)
    private var producer: UInt = 0
    private var consumer: UInt = 0

    private var useSmooth = true
    private var fast = false

    //  The C original only defined -initWithFrame:, but the object is
    //  instantiated from the MFSK nib (initWithCoder:).  Share the setup so the
    //  nib-loaded instance is initialised the same way.
    private func commonInit() {
        textField = nil
        stringValue = NSMutableString(capacity: 60)
        stringValue.append("                        .")
        producer = 0
        consumer = 0
        scrollCount = 0
        extraPause = 0
        scrollRate = 1
        useSmooth = true
        fast = false
        timer = nil
        currentMode = 0
        busy = false                //  not critical, no need to use lock
    }

    override init(frame rect: NSRect) {
        super.init(frame: rect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    //  (Private API)
    private func restartTimer(_ mode: Int) {
        timer?.invalidate()
        timer = nil
        busy = false

        var baudRate: Float = 0.0
        switch Int32(mode % 100) {
        case DOMINOEX22: baudRate = 21.533
        case DOMINOEX16: baudRate = 15.625
        case DOMINOEX11: baudRate = 10.766
        case DOMINOEX8:  baudRate = 7.8125
        case DOMINOEX5:  baudRate = 5.3833
        case DOMINOEX4:  baudRate = 3.90625
        default: break
        }
        if baudRate < 0.01 { return }       //  don't start timer

        timer = Timer.scheduledTimer(timeInterval: TimeInterval(0.028 * (15.625 + 0.25) / (baudRate + 0.25)),
                                     target: self, selector: #selector(tick(_:)), userInfo: self, repeats: true)
    }

    @objc func clear() {
        producer = consumer
        textField?.stringValue = ""
    }

    //  check if we have a character to scroll into the view
    @objc(tick:)
    func tick(_ tm: Timer) {
        if busy { return }
        busy = true

        if scrollCount != 0 {
            scrollCount -= scrollRate
            if scrollCount <= 1 {
                //  last step
                if scrollCount < 0 { scrollCount = 0 }
                var fieldRect = originalRect
                fieldRect.origin.x += CGFloat(scrollCount)
                textField?.frame = fieldRect
                textField?.display()
                scrollCount = 0
                busy = false
                return
            }
            //  not last step
            var fieldRect = originalRect
            fieldRect.origin.x += CGFloat(scrollCount)
            textField?.frame = fieldRect
            textField?.display()
            busy = false
            return
        }
        //  check backlog for characters
        var length = Int(producer) - Int(consumer)

        //  Extra pause for spaces, tabs, etc if there is no (large) backlog of
        //  characters.  This averages out the non-fix-width characters.
        if extraPause > 0 {
            if length < 1 {
                extraPause -= 1
                busy = false
                return
            }
            extraPause = 0          //  has backlog, cut the pause short
        }
        if length <= 0 {
            busy = false
            return                  //  nothing to process
        }

        //  get char
        let c = backlogString[Int(consumer % 2048)] & 0xff
        consumer += 1

        //  adjust scroll rate
        fast = false
        if length < 8 { scrollRate = 1 }
        else if length > 12 {
            fast = true
            if length > 15 { scrollRate = 60 } else { scrollRate = 2 }
        }
        //  first remove trailing <space, space, dot> that we had inserted (see below)
        length = stringValue.length
        let newString = String(utf16CodeUnits: [c], count: 1)
        stringValue.replaceCharacters(in: NSRange(location: length - 3, length: 0), with: newString)

        length = stringValue.length
        if length > 48 { stringValue.deleteCharacters(in: NSRange(location: 0, length: length - 48)) }

        currentFontAdvance = fontAdvance[Int(c)]
        var fieldRect = originalRect

        if useSmooth == false {
            scrollCount = 0
            extraPause = 0
        } else {
            scrollCount = 30
            if Float(scrollCount) > currentFontAdvance {
                let sc = currentFontAdvance + 0.5
                scrollCount = sc.isFinite ? Int(sc) : 0
            }
            extraPause = (c <= 32) ? 60 : 0
        }
        fieldRect.origin.x += CGFloat(scrollCount)
        textField?.setPaused(true)
        textField?.stringValue = stringValue as String
        textField?.frame = fieldRect
        textField?.setPaused(false)
        busy = false
    }

    @objc(appendCharacter:draw:)
    func appendCharacter(_ c: Int32, draw: Bool) {
        if draw == false { return }

        backlogString[Int(producer % 2048)] = unichar(truncatingIfNeeded: c)
        producer += 1
    }

    //  set the text field, and also gather font advance information
    @objc(setTextField:)
    func setTextField(_ field: NSTextField) {
        textField = field as? TextFieldForScrolling

        let boxRect = self.frame
        originalRect = field.bounds
        //  set up an underlying clipped field that is much wider so the text
        //  formatter doesn't start compressing text
        originalRect.size.width = boxRect.size.width + 180
        originalRect.size.height = boxRect.size.height - 1
        originalRect.origin.x = -173
        originalRect.origin.y = 0
        field.frame = originalRect
        field.bounds = originalRect

        font = textField?.font
        guard let font = font else { return }
        let zeroWidth = Float(font.advancement(forGlyph: 0).width)

        for i in 0..<256 {
            let g = font._defaultGlyph(forChar: unichar(i))
            glyph[i] = g
            fontAdvance[i] = (g == 0) ? zeroWidth : Float(font.advancement(forGlyph: g).width)
        }
    }

    @objc(setBackgroundColor:)
    func setBackgroundColor(_ color: NSColor) {
        textField?.backgroundColor = color
    }

    @objc(setTextColor:)
    func setTextColor(_ color: NSColor) {
        textField?.textColor = color
    }

    @objc(setSmoothState:)
    func setSmoothState(_ checkbox: NSButton) {
        useSmooth = (checkbox.state == .on)
    }

    //  This determines the smooth scrolling rate
    @objc(setMFSKMode:)
    func setMFSKMode(_ mode: Int32) {
        if Int(mode) != currentMode {
            currentMode = Int(mode)
            restartTimer(Int(mode))
        }
    }
}
