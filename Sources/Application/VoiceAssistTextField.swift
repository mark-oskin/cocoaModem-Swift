//
//  VoiceAssistTextField.swift
//  cocoaModem 2.0
//
//  Swift port of VoiceAssistTextField.m (Kok Chen, 4/13/12).
//

import Cocoa

@objc(VoiceAssistTextField)
class VoiceAssistTextField: NSTextField {

    //  voice character
    override func keyUp(with event: NSEvent) {
        if let characters = event.characters, !characters.isEmpty {
            let ch = (characters as NSString).character(at: 0)
            let application = (NSApp.delegate as? AppDelegate)?.application()
            switch ch {
            case 127:
                _ = application?.speakAssist("back spaced")
            case UInt16(UnicodeScalar(".").value):
                _ = application?.speakAssist(" period ")
            default:
                _ = application?.speakAssist(String(format: " %c ", Int32(ch)))
            }
        }
        super.keyUp(with: event)
    }
}
