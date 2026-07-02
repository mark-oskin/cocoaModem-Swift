//
//  Cabrillo.swift
//  cocoaModem
//
//  Created by Kok Chen on Thu Jul 01 2004.
//
//  Swift port of Cabrillo.m.  Nib-loaded NSWindow used as the Cabrillo log
//  export / contest-info sheet.  The file panels use the modernized
//  (URL-based) NSOpen/SavePanel API; behavior is preserved.
//

import Cocoa

private let kLatin1 = String.Encoding.isoLatin1.rawValue

//  preference keys (must match Plist.h)
private let kContestFontName = "Contest Font"
private let kContestFontSize = "Contest Font Size"
private let kTempFolder = "Temporary Folder"
private let kContestAllowDupe = "Allow Contest Dupe"
private let kContestLogExtension = "ContestLogExtension"
private let kCabrilloName = "Cabrillo Name"
private let kCabrilloAddr1 = "Cabrillo Addr1"
private let kCabrilloAddr2 = "Cabrillo Addr2"
private let kCabrilloAddr3 = "Cabrillo Addr3"
private let kCabrilloMail = "Cabrillo Mail"

//  informal access to the few ContestManager methods used here, resolved
//  through dynamic dispatch (keeps ContestManager.h out of the bridging header).
@objc private protocol CabrilloManager {
    func journalChanged()
    @objc(setAllowDupe:) func setAllowDupe(_ state: DarwinBoolean)
    func contestObject() -> AnyObject?
}

@objc(Cabrillo)
class Cabrillo: NSWindow, NSTextFieldDelegate {

    //  outlets connected by Cabrillo.nib -- names must match nib keys exactly
    @objc var view: NSView!

    @objc var categoryMenu: NSPopUpButton!
    @objc var bandMenu: NSPopUpButton!
    @objc var exchangeSent: NSTextField!
    @objc var allowDupe: NSButton!

    @objc var callUsedField: NSTextField!
    @objc var nameUsedField: NSTextField!
    @objc var operatorsField: NSTextField!
    @objc var clubField: NSTextField!

    @objc var nameField: NSTextField!
    @objc var addr1Field: NSTextField!
    @objc var addr2Field: NSTextField!
    @objc var addr3Field: NSTextField!
    @objc var emailField: NSTextField!

    @objc var soapboxView: NSTextView!

    @objc var fontField: NSTextField!
    @objc var tempFolder: NSTextField!

    @objc var logExtension: NSTextField!

    private var controllingWindow: NSWindow?
    private var manager: CabrilloManager?
    private var journalFile: UnsafeMutablePointer<FILE>?
    private var journalName: String?

    @objc(initWithManager:)
    convenience init(manager inManager: Any?) {
        self.init(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        manager = inManager as? CabrilloManager
        journalFile = nil
        journalName = nil
        if Bundle.main.loadNibNamed("Cabrillo", owner: self, topLevelObjects: nil), let v = view {
            setFrame(v.bounds, display: false)
            contentView?.addSubview(v)
        }
        if let ff = fontField {
            ff.allowsEditingTextAttributes = true    //  allow font change
            ff.delegate = self
            //  set up default font
            ff.font = NSFont.systemFont(ofSize: 12)
            if let font = ff.font { ff.stringValue = font.fontName }
        }
    }

    @objc func category() -> String {
        return categoryMenu.selectedItem?.title ?? ""
    }

    @objc func band() -> String {
        return bandMenu.selectedItem?.title ?? ""
    }

    @objc func name() -> String {
        return nameField.stringValue
    }

    @objc func addr1() -> String {
        return addr1Field.stringValue
    }

    @objc func addr2() -> String {
        return addr2Field.stringValue
    }

    @objc func addr3() -> String {
        return addr3Field.stringValue
    }

    @objc func email() -> String {
        return emailField.stringValue
    }

    @objc func nameUsed() -> String {
        return nameUsedField.stringValue
    }

    @objc func callUsed() -> String {
        return callUsedField.stringValue
    }

    @objc func operators() -> String {
        return operatorsField.stringValue
    }

    @objc func club() -> String {
        return clubField.stringValue
    }

    @objc func soapbox() -> String {
        return soapboxView.textStorage?.string ?? ""
    }

    @objc(showSheet:)
    func showSheet(_ window: NSWindow) {
        controllingWindow = window
        NSApp.beginSheet(self, modalFor: window, modalDelegate: nil, didEnd: nil, contextInfo: nil)
        NSApp.runModal(for: self)
        //  ... modal mode waits for stopModal in done
        NSApp.endSheet(self)
        orderOut(controllingWindow)
    }

    //  set all ContestTextField to current contest font
    @objc func setFonts() {
        let font = fontField.font
        NotificationCenter.default.post(name: NSNotification.Name("ContestFont"), object: font)
    }

    @objc func done(_ sender: Any?) {
        NSApp.stopModal()
        NotificationCenter.default.post(name: NSNotification.Name("MyCall"), object: nil)
        if let manager = manager {
            manager.journalChanged()
            manager.setAllowDupe(DarwinBoolean(allowDupe.state == .on))
        }
    }

    //  replace the TextField by a non-empty string  (string -> TextField)
    private func setField(fromString field: NSTextField?, _ string: String?) {
        guard let field = field else { return }        //  Obj-C tolerated nil outlets
        if let string = string, !string.isEmpty { field.stringValue = string }
    }

    //  Plist -> TextField
    private func setField(fromPref field: NSTextField?, _ pref: Preferences, _ key: String) {
        guard let field = field else { return }        //  Obj-C tolerated nil outlets
        field.stringValue = pref.stringValue(forKey: key) ?? ""
    }

    //  TextField -> Plist
    private func setStringPref(_ pref: Preferences, _ field: NSTextField?, _ key: String) {
        guard let field = field else { return }        //  Obj-C tolerated nil outlets
        pref.setString(field.stringValue, forKey: key)
    }

    //  called from ContestManager
    @objc(setExchange:)
    func setExchange(_ string: String?) {
        setField(fromString: exchangeSent, string)
    }

    @objc func exchangeString() -> String {
        return exchangeSent.stringValue
    }

    @objc func logExtensionString() -> String {
        return logExtension?.stringValue ?? ""        //  outlet may be unconnected in the nib
    }

    @objc(setCName:)
    func setCName(_ string: String?) {
        setField(fromString: nameField, string)
    }

    @objc(setCAddr1:)
    func setCAddr1(_ string: String?) {
        setField(fromString: addr1Field, string)
    }

    @objc(setCAddr2:)
    func setCAddr2(_ string: String?) {
        setField(fromString: addr2Field, string)
    }

    @objc(setCAddr3:)
    func setCAddr3(_ string: String?) {
        setField(fromString: addr3Field, string)
    }

    @objc(setEmail:)
    func setEmail(_ string: String?) {
        setField(fromString: emailField, string)
    }

    //  category menu, called from ContestManager
    @objc(setCategory:)
    func setCategory(_ string: String) {
        categoryMenu.selectItem(withTitle: string)
    }

    //  band menu, called from ContestManager
    @objc(setBand:)
    func setBand(_ string: String) {
        bandMenu.selectItem(withTitle: string)
    }

    @objc(setCallUsed:)
    func setCallUsed(_ string: String?) {
        setField(fromString: callUsedField, string)
    }

    @objc(setNameUsed:)
    func setNameUsed(_ string: String?) {
        setField(fromString: nameUsedField, string)
    }

    @objc(setClub:)
    func setClub(_ string: String?) {
        setField(fromString: clubField, string)
    }

    @objc(setOperators:)
    func setOperators(_ string: String?) {
        setField(fromString: operatorsField, string)
    }

    //  set string into view, called from ContestManager
    @objc(setSoapbox:)
    func setSoapbox(_ string: String) {
        if let storage = soapboxView.textStorage {
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: string)
        }
    }

    @objc(setupDefaultPreferences:)
    func setupDefaultPreferences(_ pref: Preferences) {
        pref.setString("Verdana", forKey: kContestFontName)
        pref.setString("", forKey: kTempFolder)
        pref.setFloat(12.0, forKey: kContestFontSize)
        pref.setInt(0, forKey: kContestAllowDupe)

        pref.setString("", forKey: kCabrilloName)
        pref.setString("", forKey: kCabrilloAddr1)
        pref.setString("", forKey: kCabrilloAddr2)
        pref.setString("", forKey: kCabrilloAddr3)
        pref.setString("", forKey: kCabrilloMail)
        pref.setString("", forKey: kContestLogExtension)
    }

    @objc(updateFromPlist:)
    @discardableResult
    func updateFromPlist(_ pref: Preferences) -> Bool {
        let fontname = pref.stringValue(forKey: kContestFontName) ?? ""
        let fontsize = pref.floatValue(forKey: kContestFontSize)
        var font = NSFont(name: fontname, size: CGFloat(fontsize))
        if font == nil { font = NSFont.systemFont(ofSize: 12) }
        fontField.font = font
        setFonts()

        let tempFolderName = pref.stringValue(forKey: kTempFolder) ?? ""
        tempFolder.stringValue = tempFolderName

        if let f = fontField.font { fontField.stringValue = f.fontName }

        let dupeButton = pref.intValue(forKey: kContestAllowDupe)
        allowDupe.state = (dupeButton == 0) ? .off : .on
        manager?.setAllowDupe(DarwinBoolean(dupeButton != 0))

        setField(fromPref: nameField, pref, kCabrilloName)
        setField(fromPref: addr1Field, pref, kCabrilloAddr1)
        setField(fromPref: addr2Field, pref, kCabrilloAddr2)
        setField(fromPref: addr3Field, pref, kCabrilloAddr3)
        setField(fromPref: emailField, pref, kCabrilloMail)
        setField(fromPref: logExtension, pref, kContestLogExtension)

        return true
    }

    @objc(retrieveForPlist:)
    func retrieveForPlist(_ pref: Preferences) {
        let font = fontField.font
        pref.setString(font?.fontName ?? "", forKey: kContestFontName)
        pref.setFloat(Float(font?.pointSize ?? 0), forKey: kContestFontSize)
        setStringPref(pref, nameField, kCabrilloName)
        setStringPref(pref, addr1Field, kCabrilloAddr1)
        setStringPref(pref, addr2Field, kCabrilloAddr2)
        setStringPref(pref, addr3Field, kCabrilloAddr3)
        setStringPref(pref, emailField, kCabrilloMail)
        setStringPref(pref, logExtension, kContestLogExtension)

        pref.setString(tempFolder.stringValue, forKey: kTempFolder)

        pref.setInt((allowDupe.state == .on) ? 1 : 0, forKey: kContestAllowDupe)
    }

    @objc(saveFieldsToFile:)
    func saveFieldsToFile(_ file: UnsafeMutablePointer<FILE>) {
        //  fprintf is a variadic C function and is unavailable to Swift; build the
        //  line and write its ISO-Latin-1 bytes (identical output) via fputs.
        func emit(_ tag: String, _ value: String) {
            let line = "\t\t<\(tag)>\(value)</\(tag)>\n"
            if let c = (line as NSString).cString(using: kLatin1) { fputs(c, file) }
        }
        emit("category", categoryMenu.titleOfSelectedItem ?? "")
        emit("band", bandMenu.titleOfSelectedItem ?? "")
        emit("cname", nameField.stringValue)
        emit("addr1", addr1Field.stringValue)
        emit("addr2", addr2Field.stringValue)
        emit("addr3", addr3Field.stringValue)
        emit("email", emailField.stringValue)
        emit("callused", callUsedField.stringValue)
        emit("nameused", nameUsedField.stringValue)
        emit("operators", operatorsField.stringValue)
        emit("club", clubField.stringValue)
        emit("soapbox", soapboxView.textStorage?.string ?? "")
    }

    //  import Cabrillo strings
    @objc(import:)
    func `import`(_ sender: Any?) {
        let open = NSOpenPanel()
        open.allowsMultipleSelection = false
        if open.runModal() == .OK, let path = open.url?.path {
            if let prefs = Preferences(path: path) {
                prefs.fetchPlist(false)
                updateFromPlist(prefs)
            }
        }
    }

    //  export Cabrillo strings
    @objc(export:)
    func export(_ sender: Any?) {
        let save = NSSavePanel()
        save.nameFieldStringValue = "ContestInfo.xml"
        if save.runModal() == .OK, let path = save.url?.path {
            if let prefs = Preferences(path: path) {
                //  get the macros into this temp dictionary
                retrieveForPlist(prefs)
                prefs.savePlist()
            }
        }
    }

    @objc(selectTempFolder:)
    func selectTempFolder(_ sender: Any?) {
        let current = tempFolder.stringValue
        let needInit = current.isEmpty

        if manager?.contestObject() != nil && !needInit {
            Messages.alert(withMessageText: "Contest journaling already active.", informativeText: "You cannot change the folder since a journal file is alreadly writing into it.\n\nYou need to change the folder before starting a contest session.")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true    // only in 10.3 or later
        panel.nameFieldLabel = "Select Directory"
        if panel.runModal() == .OK, let path = panel.url?.path {
            tempFolder.stringValue = (path as NSString).abbreviatingWithTildeInPath
        }
    }

    @objc(clearTempFolder:)
    func clearTempFolder(_ sender: Any?) {
        let current = tempFolder.stringValue
        if current.isEmpty { return }

        if manager?.contestObject() != nil {
            Messages.alert(withMessageText: "Contest journaling already active.", informativeText: "You cannot clear the folder since a journal file is alreadly writing into it.\n\nYou need to clear the folder before starting a contest session.")
            return
        }
        tempFolder.stringValue = ""
    }

    @objc(openJournalFile:)
    func openJournalFile(_ contest: Contest) -> UnsafeMutablePointer<FILE>? {
        if let jf = journalFile {
            // for safety.  we should not get here
            fclose(jf)
            journalFile = nil
        }
        var folder = tempFolder.stringValue
        if folder.isEmpty { return nil }
        folder = (folder as NSString).expandingTildeInPath

        var name = folder + "/cocoaModem "
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm'.jnl'"
        name += formatter.string(from: Date())
        journalName = name

        journalFile = fopen((name as NSString).cString(using: kLatin1), "w")
        if let jf = journalFile { contest.updateQSO(toJournal: jf) }
        return journalFile
    }

    @objc(reOpenJournalFile:)
    func reOpenJournalFile(_ contest: Contest) -> UnsafeMutablePointer<FILE>? {
        if let jf = journalFile, journalName != nil {
            journalFile = freopen(nil, "w", jf)
            if let njf = journalFile { contest.updateQSO(toJournal: njf) }
            return journalFile
        }
        closeJournalFile()
        return openJournalFile(contest)
    }

    @objc func closeJournalFile() {
        if let jf = journalFile {
            fclose(jf)
            journalFile = nil
        }
    }

    @objc func journal() -> UnsafeMutablePointer<FILE>? {
        return journalFile
    }

    //  delegate for fontField (to register font changes)
    func controlTextDidChange(_ notification: Notification) {
        guard let current = fontField.font else { return }
        let fname = current.fontName
        let size = current.pointSize

        let str = fontField.attributedStringValue
        let len = str.length
        for i in 0..<len {
            //  apply any change to entire field
            if let font = str.attribute(.font, at: i, effectiveRange: nil) as? NSFont {
                if font.fontName != fname || font.pointSize != size {
                    fontField.font = font
                    fontField.stringValue = font.fontName
                    //  set all contest fields
                    NotificationCenter.default.post(name: NSNotification.Name("ContestFont"), object: font)
                    break
                }
            }
        }
    }
}
