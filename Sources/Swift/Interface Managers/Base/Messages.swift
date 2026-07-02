//
//  Messages.swift
//  cocoaModem
//
//  Created by Kok Chen on Tue Jun 08 2004.
//  Swift port of Messages.m.
//

import Cocoa

@objc(Messages)
class Messages: NSObject {

    //  nib-connected outlet (owner of ModemLog.nib)
    @objc var contentView: NSView!

    private static var mainLog: Messages?

    private var sessionStartDate: Date!
    private var controllingTabView: NSTabView!
    private var logTabItem: NSTabViewItem!
    private var logView: NSTextView!
    private let bufferedString = NSMutableString(capacity: 4096)

    //  kTextEncoding is NSISOLatin1StringEncoding (see TextEncoding.h)
    private static let latin1 = String.Encoding.isoLatin1

    //  -----------------------------------------------------------------
    //  class methods
    //  -----------------------------------------------------------------

    //  NOTE: the original was a C-variadic method (+logMessage:(char*)format,...).
    //  A C-variadic method cannot be exposed from Swift, so this now takes a
    //  single, already-formatted C string.  The vararg call sites were updated to
    //  pre-format with sprintf (identical runtime behaviour).
    @objc(logMessage:)
    class func logMessage(_ msg: UnsafePointer<CChar>?) {
        guard let msg = msg else { return }
        mainLog?.msg(msg)
    }

    @objc(alertWithMessageText:informativeText:)
    @discardableResult
    class func alert(withMessageText msg: String?, informativeText info: String?) -> Int32 {
        //  v1.02e -- appLevel is a compile-time constant 1 in this build, so the
        //  appLevel==0 branch of the original is unreachable; only the Application
        //  voice-assist path remains.
        if let app = (NSApp.delegate as? AppDelegate)?.application(), app.voiceAssist() {
            app.speakAssist(String(format: "Alert! %@ .", msg ?? ""))
            app.setSpeakAssistInfo(info)
            return 1    //  NSAlertDefaultReturn
        }
        let alert = NSAlert()
        alert.messageText = msg ?? ""
        alert.informativeText = info ?? ""
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        return Int32(alert.runModal().rawValue)
    }

    @objc(alertWithHiraganaError)
    class func alertWithHiraganaError() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Unrecognized encoding", comment: "")
        alert.informativeText = NSLocalizedString("kotoeri", comment: "")
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }

    @objc(appleScriptError:script:)
    class func appleScriptError(_ dict: [AnyHashable: Any]?, script from: UnsafePointer<CChar>?) {
        guard let dict = dict else { return }

        let code = (dict[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        let msg = dict[NSAppleScript.errorMessage] as? String
        var nstr: String? = nil
        switch code {
        case -43:
            nstr = NSLocalizedString("File not found", comment: "")
        case -120:
            nstr = NSLocalizedString("Directory not found", comment: "")
        case -128:
            //  user cancelled
            return
        case -1703:
            nstr = NSLocalizedString("Wrong data type", comment: "")
        case -2753:
            nstr = NSLocalizedString("Undefined variable", comment: "")
        default:
            break
        }

        let fromStr = from != nil ? String(cString: from!) : ""
        let str: String
        if let nstr = nstr {
            str = "\(nstr) for \(fromStr) script."
        } else {
            let errString = NSError(domain: NSOSStatusErrorDomain, code: code, userInfo: nil).localizedDescription
            str = "\(errString) for \(fromStr) script.\n\nError detail: \(msg ?? "")"
        }
        alert(withMessageText: NSLocalizedString("AppleScript error", comment: ""), informativeText: str)
    }

    //  -----------------------------------------------------------------
    //  instance methods
    //  -----------------------------------------------------------------

    //  initialize with given view
    @objc(initIntoView:)
    init?(intoView view: NSTextView?) {
        super.init()
        sessionStartDate = Date()
        if Bundle.main.loadNibNamed("ModemLog", owner: self, topLevelObjects: nil), contentView != nil {
            Messages.mainLog = self
            logView = view
            return
        }
        return nil
    }

    //  initialize, and load the log view from the Nib into the tab view (not used in cocoaModem 2.0)
    @objc(initIntoTabView:)
    init?(intoTabView tabview: NSTabView?) {
        super.init()
        sessionStartDate = Date()
        if Bundle.main.loadNibNamed("ModemLog", owner: self, topLevelObjects: nil), contentView != nil {
            //  create a new TabViewItem for config
            logTabItem = NSTabViewItem()
            logTabItem.label = "Diagnostics"
            logTabItem.view = contentView
            //  and insert as tabView item
            controllingTabView = tabview
            controllingTabView.addTabViewItem(logTabItem)
            Messages.mainLog = self
            return
        }
        return nil
    }

    @objc(appendToBuffer:)
    func appendToBuffer(_ str: String?) {
        guard let str = str else { return }

        bufferedString.append(str)

        if let window = logView?.window, window.isVisible {
            logView.isEditable = true
            logView.insertText(bufferedString)
            logView.isEditable = false
            bufferedString.setString("")
        }
    }

    @objc func show() {
        let window = logView?.window
        window?.orderFront(self)
        if bufferedString.length > 0 {
            appendToBuffer("")
        }
    }

    @objc func awakeFromApplication() {
        Messages.mainLog = self
        appendToBuffer(NSLocalizedString("welcome", comment: ""))
    }

    @objc(msg:)
    func msg(_ msg: UnsafePointer<CChar>?) {
        guard let msg = msg else { return }

        let elapsed = Date().timeIntervalSince(sessionStartDate)
        var n = Int32(elapsed)
        let s = n % 60
        let m = (n / 60) % 60
        n = Int32((elapsed - Double(n)) * 1000)
        if n >= 1000 { n = 999 }

        //  decode the incoming C string as ISO Latin-1 (kTextEncoding)
        let bytes = Data(bytes: UnsafeRawPointer(msg), count: strlen(msg))
        let body = String(data: bytes, encoding: Messages.latin1) ?? ""
        let prefix = String(format: "[ %02d: %02d: %02d.%03d ]  ", n / 3600, m, s, n)
        Messages.mainLog?.appendToBuffer(prefix + body + "\n")
    }
}
