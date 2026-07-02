//
//  ExchangeView.swift
//  cocoaModem
//
//  Created by Kok Chen on Thu Jul 08 2004.
//  Swift port of ExchangeView.m.
//
//  AYTextView which manipulates callsigns, etc.
//

import Cocoa

@objc(ExchangeView)
class ExchangeView: AYTextView {

    private var isRightMouse: Bool = false
    private var isMouseClick: Bool = false
    private var freeze: Bool = false

    override func viewDidMoveToWindow() {
        self.turnOffInsertionPoint(true)
        if let scrollView = self.enclosingScrollView {
            //  use arrow cursor for this view
            scrollView.documentCursor = NSCursor.arrow
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let chars = event.characters, !chars.isEmpty else {   // v0.35
            super.keyDown(with: event)
            return
        }

        let ch = (chars as NSString).character(at: 0)

        switch ch {
        case 0x7f:
            //  delete selection
            self.replaceCharacters(in: self.selectedRange(), with: "")
        default:
            super.keyDown(with: event)
        }
    }

    //  -appendOnMainThread does not use NSTextView's insert method since that requires the view to be editable
    //  -appendOnMainThread can be used with read-only (e.g., RTTY output) views
    //  call -append from a secondary thread
    @objc(appendOnMainThread:)
    override func appendOnMainThread(_ string: NSAttributedString) {
        appendLock.lock()                   // for contest clicking

        let endOfScroll = (scroller?.floatValue ?? 0) >= 1.0
        //  place string into text storage of view
        guard let storage = self.textStorage else { appendLock.unlock(); return }
        var total = storage.length
        let temp = string.string as NSString
        let length = temp.length

        storage.append(string)

        //  move selection range away from the end
        let selected = self.selectedRange()
        if selected.location == (total + length) {
            self.setSelectedRange(NSRange(location: 0, length: 0))
        }
        //  if we were at the end of the scroll bar, maintain scrolled position
        if endOfScroll {
            total = storage.length
            self.scrollRangeToVisible(NSRange(location: total, length: 0))
        }
        appendLock.unlock()
    }

    @objc(getRightMouse)
    func getRightMouse() -> Bool {
        return isRightMouse
    }

    //  read and clear right mouse flag
    @objc(getAndClearRightMouse)
    func getAndClearRightMouse() -> Bool {
        let wasRightMouse = isRightMouse
        isRightMouse = false
        return wasRightMouse
    }

    @objc(getAndClearMouseClick)
    func getAndClearMouseClick() -> Bool {
        let wasMouse = isMouseClick
        isMouseClick = false
        return wasMouse
    }

    @objc(getMouseClick)
    func getMouseClick() -> Bool {
        return isMouseClick
    }

    @objc(getEitherMouse)
    func getEitherMouse() -> Bool {
        return isRightMouse || isMouseClick
    }

    //  force cursor to arrow when scrolling
    override func resetCursorRects() {
        self.addCursorRect(self.visibleRect, cursor: NSCursor.arrow)
    }

    override func mouseDown(with event: NSEvent) {
        isMouseClick = true
        isRightMouse = event.modifierFlags.contains(.control)
        if isRightMouse {
            //  process control click as a right mouse click
            super.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
        NSCursor.arrow.set()
    }

    //  return nil so it does not show on control click
    override func menu(for event: NSEvent) -> NSMenu? {
        _ = super.menu(for: event)      // do whatever NSTextView needs
        return nil                      // but returns nil so no menu pops up
    }

    //  v0.89 -- freeze click
    override func awakeFromNib() {
        super.awakeFromNib()
        freeze = false
        isRightMouse = false
        isMouseClick = false
    }

    //  v0.89 -- freeze click
    override func draw(_ dirtyRect: NSRect) {
        if freeze { return }
        super.draw(dirtyRect)
    }

    //  v0.89 -- freeze click
    //  capture a control mouse down
    //  The control click is used to freeze the input
    override func rightMouseDown(with event: NSEvent) {
        freeze = true
    }

    //  v0.89 -- freeze click
    //  captures a control mouse up
    //  it is first used to generate a fake right mouseDown (to do the actual callsign capture)
    //  then finally unfreeze the view and send the actual mouse up.
    override func rightMouseUp(with event: NSEvent) {
        isRightMouse = true
        isMouseClick = true

        let down = NSEvent.mouseEvent(with: .rightMouseDown,
                                      location: event.locationInWindow,
                                      modifierFlags: event.modifierFlags,
                                      timestamp: event.timestamp,
                                      windowNumber: event.windowNumber,
                                      context: event.context,
                                      eventNumber: event.eventNumber,
                                      clickCount: event.clickCount,
                                      pressure: event.pressure)

        if let down = down {
            super.rightMouseDown(with: down)
        }

        freeze = false
        super.rightMouseUp(with: event)
    }

    //  return proposed range for right and control clicks (this keeps the range at zero length)
    override func selectionRange(forProposedRange proposedSelRange: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        if isRightMouse {
            return proposedSelRange
        }
        return super.selectionRange(forProposedRange: proposedSelRange, granularity: granularity)
    }

    //  NSResponder
    override func flagsChanged(with event: NSEvent) {
        NotificationCenter.default.post(name: NSNotification.Name("OptionKey"), object: event)
        super.flagsChanged(with: event)
    }

    //  NSResponder - catches command 1 through = keys
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let chars = event.characters, !chars.isEmpty else { return false }   // v0.35
        let ig = event.charactersIgnoringModifiers ?? ""
        guard !ig.isEmpty else { return false }

        let n = Int((ig as NSString).character(at: 0))

        switch n {
        case NSUpArrowFunctionKey, NSDownArrowFunctionKey, NSLeftArrowFunctionKey, NSRightArrowFunctionKey:
            if event.modifierFlags.contains(.command) {
                //  respond only if command key is down
                NotificationCenter.default.post(name: NSNotification.Name("ArrowKey"), object: event)
                return true
            }
            //  do nothing otherwise
            return false
        default:
            if (n >= 0x30 && n <= 0x39) || n == 0x2d || n == 0x3d {  // '0'..'9', '-', '='
                NotificationCenter.default.post(name: NSNotification.Name("MacroKeyboardShortcut"), object: event)
                return true
            }
        }
        return false
    }
}
