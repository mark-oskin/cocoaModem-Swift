//
//  SendView.swift
//  cocoaModem
//
//  Created by Kok Chen on Thu Jul 08 2004.
//  Swift port of SendView.m.
//
//  TextViews for transmitViews.
//

import Cocoa

@objc(SendView)
class SendView: AYTextView {

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        //  allow only plain text
        return [NSPasteboard.PasteboardType(rawValue: "NSStringPboardType")]
    }

    override func viewDidMoveToWindow() {
        if let scrollView = self.enclosingScrollView {
            //  use arrow cursor for this view
            scrollView.documentCursor = NSCursor.arrow
        }
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        if flag {
            //  get part of string not yet transmitted, and insert
            let remainder = (word as NSString).substring(from: charRange.length)
            self.insertText(remainder)
        }
    }

    //  force cursor to arrow when scrolling
    override func resetCursorRects() {
        self.addCursorRect(self.visibleRect, cursor: NSCursor.arrow)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        NSCursor.arrow.set()
    }

    //  delete character if at end
    //  DeleteView overrides this
    @objc(deleteFromEnd:)
    func deleteFromEnd(_ event: NSEvent) {
    }

    //  force cursor back to arrow after insertion
    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        NSCursor.arrow.set()
    }

    //  NSResponder
    override func flagsChanged(with event: NSEvent) {
        NotificationCenter.default.post(name: NSNotification.Name("OptionKey"), object: event)
        super.flagsChanged(with: event)
    }

    //  NSResponder
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let chars = event.characters, !chars.isEmpty else { return false }
        let ig = event.charactersIgnoringModifiers ?? ""
        guard !ig.isEmpty else { return false }
        let n = Int((ig as NSString).character(at: 0))
        if (n >= 0x30 && n <= 0x39) || n == 0x2d || n == 0x3d {  // '0'..'9', '-', '='
            NotificationCenter.default.post(name: NSNotification.Name("MacroKeyboardShortcut"), object: event)
            return true
        }
        return false
    }

    //  v0.70 -- (Delegate of SendView implements this method)
    @objc(insertedText:)
    func insertedText(_ string: Any) {
    }

    //  v0.70 -- Kotoeri text collected and inserted as a word here
    override func insertText(_ string: Any) {
        super.insertText(string)
        if let delegate = self.delegate, delegate.responds(to: #selector(SendView.insertedText(_:))) {
            _ = delegate.perform(#selector(SendView.insertedText(_:)), with: string)
        }
    }
}
