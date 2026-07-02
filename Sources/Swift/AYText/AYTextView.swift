//
//  AYTextView.swift
//  cocoaCCD / cocoaModem 2.0
//
//  Created by Kok Chen on Sun Apr 04 2004.
//  Swift port of AYTextView.m.
//
//  The C TextAttribute struct and TEXTRINGMASK now live in TextAttribute.h so
//  they remain visible to the Obj-C modems (and to this class) after the port.
//

import Cocoa

@objc(AYTextView)
class AYTextView: NSTextView {

    //  ---- ivars (former Obj-C instance variables) ------------------------
    private var initialized: Bool = false
    private var hasInsertionPoint: Bool = false
    private var background: NSColor!
    private var thread: Thread!
    //  base ivars accessed by subclasses (SendView / ExchangeView) -> internal
    internal var scroller: NSScroller?
    private var charSinceNewline: Int32 = 0
    //  font attributes (malloc'd C structs, intentionally never freed — matches
    //  the original, which had no dealloc; they live for the app)
    private var attribute: UnsafeMutablePointer<TextAttribute>?
    private var defaultAttribute: UnsafeMutablePointer<TextAttribute>?

    private var bufferLock: NSLock!
    private var viewLock: NSLock!
    internal var appendLock: NSLock!
    //  scratch unichar buffer (was inline unichar uni[256] ivar)
    private let uni = UnsafeMutablePointer<unichar>.allocate(capacity: 256)

    private var ignoreNewline: Bool = false

    deinit {
        uni.deallocate()
    }

    //  ---- helpers ---------------------------------------------------------

    //  fetch the attribute dictionary as a typed Swift dictionary
    private func attrDict(_ a: UnsafeMutablePointer<TextAttribute>) -> [NSAttributedString.Key: Any]? {
        return a.pointee.dictionary?.takeUnretainedValue() as? [NSAttributedString.Key: Any]
    }

    private func makeDictionary(font: NSFont, color: NSColor) -> NSDictionary {
        let dict: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: font
        ]
        return dict as NSDictionary
    }

    //  ---- overrides -------------------------------------------------------

    override var isOpaque: Bool { return true }

    @objc private func setTextAttributeOnMainThread() {
        guard let a = attribute else { return }
        if let font = a.pointee.font?.takeUnretainedValue() {
            super.font = font
        }
        if let color = a.pointee.textColor?.takeUnretainedValue() {
            self.insertionPointColor = color
        }
    }

    @objc(setTextAttribute:)
    func setTextAttribute(_ a: UnsafeMutablePointer<TextAttribute>) {
        attribute = a
        self.performSelector(onMainThread: #selector(setTextAttributeOnMainThread), with: nil, waitUntilDone: false)
    }

    //  return a struct with the default text attributes
    @objc(newAttribute)
    func newAttribute() -> UnsafeMutablePointer<TextAttribute> {
        let a = UnsafeMutablePointer<TextAttribute>.allocate(capacity: 1)
        //  default font
        var font = NSFont(name: "Verdana", size: 14)
        if font == nil { font = NSFont.systemFont(ofSize: 14) }
        //  default text color
        let textColor = NSColor(calibratedRed: 1, green: 0.8, blue: 0, alpha: 1)
        a.pointee.font = Unmanaged.passRetained(font!)
        a.pointee.textColor = Unmanaged.passRetained(textColor)
        a.pointee.dictionary = Unmanaged.passRetained(makeDictionary(font: font!, color: textColor))
        return a
    }

    override var shouldDrawInsertionPoint: Bool { return hasInsertionPoint }

    @objc(turnOffInsertionPoint:)
    func turnOffInsertionPoint(_ state: Bool) {
        hasInsertionPoint = !state
    }

    override func awakeFromNib() {
        ignoreNewline = false
        viewLock = NSLock()
        bufferLock = NSLock()
        appendLock = NSLock()

        let fontMgr = NSFontManager.shared
        fontMgr.delegate = self     // delegate for -changeFont (no-op on modern macOS, kept for parity)

        background = NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 1)

        defaultAttribute = newAttribute()
        //  set colors and fonts
        super.backgroundColor = background
        setTextAttribute(defaultAttribute!)

        self.isContinuousSpellCheckingEnabled = false      // turn off spell checker
        thread = Thread.current

        //  get scroller
        scroller = nil
        if let scrollView = self.enclosingScrollView {
            scroller = scrollView.verticalScroller
        }
        hasInsertionPoint = true
        self.menu = nil
    }

    @objc(setIgnoreNewline:)
    func setIgnoreNewline(_ state: Bool) {
        ignoreNewline = state
    }

    //  set following text storage
    @objc(setTextColor:attribute:)
    func setTextColor(_ inColor: NSColor, attribute a: UnsafeMutablePointer<TextAttribute>) {
        let oldColor = a.pointee.textColor
        a.pointee.textColor = Unmanaged.passRetained(inColor)
        oldColor?.release()
        //  create new dictionary with new color
        let oldDictionary = a.pointee.dictionary
        if let font = a.pointee.font?.takeUnretainedValue() {
            a.pointee.dictionary = Unmanaged.passRetained(makeDictionary(font: font, color: inColor))
        }
        oldDictionary?.release()
        //  note: setTextAttribute also locks
        setTextAttribute(a)
    }

    @objc private func setTextColorOnMainThread(_ color: NSColor) {
        super.textColor = color
    }

    //  set entire view's text color
    @objc(setViewTextColor:attribute:)
    func setViewTextColor(_ inColor: NSColor, attribute a: UnsafeMutablePointer<TextAttribute>) {
        let oldColor = a.pointee.textColor
        a.pointee.textColor = Unmanaged.passRetained(inColor)
        self.performSelector(onMainThread: #selector(setTextColorOnMainThread(_:)), with: inColor, waitUntilDone: false)
        oldColor?.release()
        //  create new dictionary with new color
        let oldDictionary = a.pointee.dictionary
        if let font = a.pointee.font?.takeUnretainedValue() {
            a.pointee.dictionary = Unmanaged.passRetained(makeDictionary(font: font, color: inColor))
        }
        oldDictionary?.release()
        setTextAttribute(a)
    }

    @objc(setTextFont:size:attribute:)
    func setTextFont(_ name: String, size: Float, attribute a: UnsafeMutablePointer<TextAttribute>) {
        if let newFont = NSFont(name: name, size: CGFloat(size)) {
            viewLock.lock()
            let oldFont = a.pointee.font
            a.pointee.font = Unmanaged.passRetained(newFont)
            oldFont?.release()
            //  create new dictionary with new font
            let oldDictionary = a.pointee.dictionary
            if let color = a.pointee.textColor?.takeUnretainedValue() {
                a.pointee.dictionary = Unmanaged.passRetained(makeDictionary(font: newFont, color: color))
            }
            oldDictionary?.release()
            viewLock.unlock()
        }
        setTextAttribute(a)
    }

    @objc(setTextFont:attribute:)
    func setTextFont(_ newFont: NSFont?, attribute a: UnsafeMutablePointer<TextAttribute>) {
        if let newFont = newFont {
            viewLock.lock()
            let oldFont = a.pointee.font
            a.pointee.font = Unmanaged.passRetained(newFont)
            oldFont?.release()
            //  create new dictionary with new font
            let oldDictionary = a.pointee.dictionary
            if let color = a.pointee.textColor?.takeUnretainedValue() {
                a.pointee.dictionary = Unmanaged.passRetained(makeDictionary(font: newFont, color: color))
            }
            oldDictionary?.release()
            viewLock.unlock()
        }
        setTextAttribute(a)
    }

    /* local */
    private func backspace() {
        guard let storage = self.textStorage else { return }
        let total = storage.length
        if total < 2 { return }
        let end = NSRange(location: total - 1, length: 1)
        storage.replaceCharacters(in: end, with: "")
    }

    /* local */
    //  NOTE: this is performed in the main thread
    //  string must be shorter than 64 characters
    private func convertAndAppendAsUnicode(_ charBuffer: UnsafeMutablePointer<UInt8>, length inLength: Int32) {
        var length = inLength
        if length <= 0 { return }
        if length > 64 { length = 64 }

        if charBuffer[0] == 0o10 {
            backspace()
            return
        }
        var n = 0
        var i = 0
        while i < Int(length) {
            let u = Int(charBuffer[i]) & 0xff
            if u < 32 && u != 0x0a {
                //  ignore control characters
            } else {
                //  replace 0x80 by unicode for euro symbol
                if ignoreNewline && u == 0x0a {
                    uni[n] = UInt16(UnicodeScalar(" ").value); n += 1
                    uni[n] = UInt16(UnicodeScalar("-").value); n += 1
                    uni[n] = UInt16(UnicodeScalar(" ").value); n += 1
                } else {
                    var uu = u
                    if uu == 0x80 { uu = 0x20ac }       // euro symbol
                    uni[n] = UInt16(uu); n += 1
                }
            }
            i += 1
        }
        if n > 0 {
            let s = NSString(characters: uni, length: n) as String
            let attrs = attribute.flatMap { attrDict($0) }
            let string = NSAttributedString(string: s, attributes: attrs)
            appendOnMainThread(string)
        }
    }

    @objc private func appendString(_ str: String?) {
        guard let str = str else { return }
        if bufferLock.try() {
            if let s = str.cString(using: .isoLatin1) {
                //  ignore overruns
                let charBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
                defer { charBuffer.deallocate() }
                var bufferLength: Int32 = 0
                var idx = 0
                while s[idx] != 0 {
                    let u = Int(s[idx]) & 0xff
                    idx += 1
                    //  check for backspaces
                    if u == 0o10 {
                        if bufferLength > 0 { convertAndAppendAsUnicode(charBuffer, length: bufferLength) }
                        charBuffer[0] = 0o10
                        bufferLength = 1
                        convertAndAppendAsUnicode(charBuffer, length: 1)
                        bufferLength = 0
                    } else {
                        charBuffer[Int(bufferLength)] = UInt8(u); bufferLength += 1
                        if bufferLength >= 60 {
                            convertAndAppendAsUnicode(charBuffer, length: bufferLength)
                            bufferLength = 0
                        }
                    }
                }
                //  flush string if non-zero length
                if bufferLength > 0 {
                    convertAndAppendAsUnicode(charBuffer, length: bufferLength)
                }
            }
            bufferLock.unlock()
        }
    }

    //  (Private API)
    //  v0.70 same as AppendString but for Unicode
    @objc private func appendUnicodeString(_ str: String) {
        if bufferLock.try() {
            let attrs = attribute.flatMap { attrDict($0) }
            let string = NSAttributedString(string: str, attributes: attrs)
            appendOnMainThread(string)
            bufferLock.unlock()
        }
    }

    //  force cursor back to arrow after insertion
    override func keyDown(with event: NSEvent) {
        if let chars = event.characters, !chars.isEmpty {
            let ch = (chars as NSString).character(at: 0)
            if ch == 0o33 { return }        // toss ESC
        }
        super.keyDown(with: event)
    }

    //  add a string to the ring buffer in the main thread
    @objc(append:)
    func append(_ s: UnsafeMutablePointer<CChar>) {
        let string = NSString(cString: s, encoding: String.Encoding.isoLatin1.rawValue)
        self.performSelector(onMainThread: #selector(appendString(_:)), with: string, waitUntilDone: false)
    }

    //  v0.70 - append Unicode character to NSTextView
    @objc(appendUnicode:)
    func appendUnicode(_ c: unichar) {
        var unistr = c
        let string = NSString(characters: &unistr, length: 1) as String
        self.performSelector(onMainThread: #selector(appendUnicodeString(_:)), with: string, waitUntilDone: false)
    }

    @objc(setAppendLock:)
    func setAppendLock(_ state: Bool) {
        if state { appendLock.lock() } else { appendLock.unlock() }
    }

    //  -appendOnMainThread does not use NSTextView's insert method since that requires the view to be editable
    //  -appendOnMainThread can be used with read-only (e.g., RTTY output) views
    //  call -append from a secondary thread
    @objc(appendOnMainThread:)
    func appendOnMainThread(_ string: NSAttributedString) {
        appendLock.lock()

        let endOfScroll = (scroller?.floatValue ?? 0) >= 1.00
        guard let storage = self.textStorage else { appendLock.unlock(); return }

        storage.append(string)

        //  check if need to scroll, inhibit if not at the end (user has moved scroller)
        if endOfScroll {
            var hasNewline = false
            let temp = string.string as NSString
            let length = temp.length
            for i in 0..<length {
                if temp.character(at: i) == 0x0a { hasNewline = true }
            }
            var doScroll = false
            if hasNewline {
                doScroll = true
            } else {
                charSinceNewline += Int32(length)
                if charSinceNewline > 50 { doScroll = true }
            }
            if doScroll {
                let total = storage.length
                self.scrollRangeToVisible(NSRange(location: total, length: 0))
                if hasNewline { charSinceNewline = 0 }
            }
        }
        appendLock.unlock()
    }

    @objc(insertAtEnd:)
    func insertAtEnd(_ string: String) {
        insertInTextStorage(string)
        let end = NSRange(location: (self.textStorage?.length ?? 0), length: 0)
        self.scrollRangeToVisible(end)
    }

    @objc(insertInTextStorage:)
    func insertInTextStorage(_ string: String) {
        let end = NSRange(location: (self.textStorage?.length ?? 0), length: 0)
        self.setSelectedRange(end)
        self.insertText(string)         // deprecated selector kept: SendView overrides -insertText:
    }

    //  scroll so the text at end is visible
    @objc(scrollToEnd)
    func scrollToEnd() {
        if self.lockFocusIfCanDraw() {
            let length = self.textStorage?.length ?? 0
            let end = NSRange(location: length, length: 0)
            self.scrollRangeToVisible(end)
            self.unlockFocus()
        }
    }

    @objc private func updateDisplayOnMainThread() {
        let end = NSRange(location: (self.textStorage?.length ?? 0), length: 0)
        self.scrollRangeToVisible(end)
    }

    @objc(updateDisplay)
    func updateDisplay() {
        self.performSelector(onMainThread: #selector(updateDisplayOnMainThread), with: nil, waitUntilDone: false)
    }

    @objc private func clearAllOnMainThread() {
        let all = NSRange(location: 0, length: (self.textStorage?.length ?? 0))
        self.replaceCharacters(in: all, with: "")
        self.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    @objc(clearAll)
    func clearAll() {
        self.performSelector(onMainThread: #selector(clearAllOnMainThread), with: nil, waitUntilDone: false)
    }

    //  make this textview the first responder
    @objc(select)
    func select() {
        self.window?.makeFirstResponder(self)
    }

    override func draw(_ rect: NSRect) {
        if thread === Thread.current {
            //  ensure that we are called from the main thread
            super.draw(rect)
        }
    }

    //  delegate for NSFontManager
    //  called when the font panel changes font for the textView
    override func changeFont(_ sender: Any?) {
        guard let a = attribute else { return }
        guard let fontManager = sender as? NSFontManager else { return }
        guard let current = a.pointee.font?.takeUnretainedValue() else { return }
        let font = fontManager.convert(current)
        if font != current {
            setTextFont(font, attribute: a)
        }
    }
}
