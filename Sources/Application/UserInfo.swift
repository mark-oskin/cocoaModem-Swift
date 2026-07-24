//
//  UserInfo.swift
//  cocoaModem 2.0
//
//  Swift port of UserInfo.m (Kok Chen, 7/1/04).
//

import Cocoa

//  preference keys (must match Plist.h)
private let kInfoName = "Name"
private let kInfoCall = "Callsign"
private let kInfoState = "State"
private let kInfoGridSquare = "Grid Square"
private let kInfoYearLic = "Year Licensed"
private let kInfoSection = "ARRL Section"
private let kInfoZone = "CQ Zone"
private let kInfoITU = "ITU Zone"
private let kInfoCountry = "Country"
private let kBragTape = "Brag Tape"

@objc(UserInfo)
class UserInfo: NSWindow {
    //  outlets set by UserInfo.nib through KVC -- names must match nib keys exactly
    @objc var view: NSView!
    @objc var nameField: NSTextField!
    @objc var callField: NSTextField!
    @objc var stateField: NSTextField!
    @objc var country: NSTextField!
    @objc var gridSquare: NSTextField!
    @objc var yearLicensed: NSTextField!
    @objc var arrlSection: NSTextField!
    @objc var cqZone: NSTextField!
    @objc var ituZone: NSTextField!
    @objc var brag: NSTextView!

    private var controllingWindow: NSWindow?

    //  NSWindow's -init funnels through this designated initializer,
    //  so [ [ UserInfo alloc ] init ] from Objective-C loads the nib here.
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        if Bundle.main.loadNibNamed("UserInfo", owner: self, topLevelObjects: nil), view != nil {
            setFrame(view.bounds, display: false)
            contentView?.addSubview(view)
        }
    }

    @objc func call() -> String {
        return callField.stringValue
    }

    @objc func name() -> String {
        return nameField.stringValue
    }

    @objc func qth() -> String {
        return stateField.stringValue
    }

    @objc func section() -> String {
        return arrlSection.stringValue
    }

    @objc(showSheet:)
    func showSheet(_ window: NSWindow) {
        controllingWindow = window
        NSApp.beginSheet(self, modalFor: window, modalDelegate: nil, didEnd: nil, contextInfo: nil)
        NSApp.runModal(for: self)
        //  ... modal mode waits for stopModal in -done
        NSApp.endSheet(self)
        orderOut(controllingWindow)
    }

    //  fetch macro
    @objc(macroFor:)
    func macroFor(_ c: Int32) -> String {
        let str: String

        switch UnicodeScalar(UInt8(truncatingIfNeeded: c)) {
        case "a":
            //  arrl section
            str = arrlSection.stringValue
        case "b":
            //  brag tape
            str = "\n" + brag.string + "\n"
        case "c":
            //  callsign
            str = callField.stringValue
        case "g":
            //  grid square
            str = gridSquare.stringValue
        case "h":
            //  name
            str = nameField.stringValue
        case "s":
            //  state
            str = stateField.stringValue
        case "S":
            //  country
            str = country.stringValue
        case "y":
            //  year licensed
            str = yearLicensed.stringValue
        case "z":
            //  CQ zone
            str = cqZone.stringValue
        case "Z":
            //  ITU zone
            str = ituZone.stringValue
        default:
            str = "----"
        }
        return str
    }

    @objc func done(_ sender: Any?) {
        NSApp.stopModal()
        NotificationCenter.default.post(name: NSNotification.Name("MyCall"), object: nil)
    }

    //  set up defaults before Plist is fetched
    @objc(setupDefaultPreferences:)
    func setupDefaultPreferences(_ pref: Preferences) {
        pref.setString("", forKey: kInfoName)
        pref.setString("", forKey: kInfoCall)
        pref.setString("", forKey: kBragTape)
        pref.setString("", forKey: kInfoState)
        pref.setString("", forKey: kInfoCountry)
        pref.setString("", forKey: kInfoGridSquare)
        pref.setString("", forKey: kInfoYearLic)
        pref.setString("", forKey: kInfoSection)
        pref.setString("", forKey: kInfoZone)
        pref.setString("", forKey: kInfoITU)
    }

    //  update all parameters from the plist (called after fetchPlist )
    @objc(updateFromPlist:)
    @discardableResult
    func updateFromPlist(_ pref: Preferences) -> Bool {
        nameField.stringValue = pref.stringValue(forKey: kInfoName)
        callField.stringValue = pref.stringValue(forKey: kInfoCall)
        stateField.stringValue = pref.stringValue(forKey: kInfoState)
        country.stringValue = pref.stringValue(forKey: kInfoCountry)
        gridSquare.stringValue = pref.stringValue(forKey: kInfoGridSquare)
        yearLicensed.stringValue = pref.stringValue(forKey: kInfoYearLic)
        arrlSection.stringValue = pref.stringValue(forKey: kInfoSection)
        cqZone.stringValue = pref.stringValue(forKey: kInfoZone)
        ituZone.stringValue = pref.stringValue(forKey: kInfoITU)
        brag.insertText(pref.stringValue(forKey: kBragTape) as Any)

        return true
    }

    @objc(retrieveForPlist:)
    func retrieveForPlist(_ pref: Preferences) {
        pref.setString(nameField.stringValue, forKey: kInfoName)
        pref.setString(callField.stringValue, forKey: kInfoCall)
        pref.setString(stateField.stringValue, forKey: kInfoState)
        pref.setString(country.stringValue, forKey: kInfoCountry)
        pref.setString(gridSquare.stringValue, forKey: kInfoGridSquare)
        pref.setString(yearLicensed.stringValue, forKey: kInfoYearLic)
        pref.setString(arrlSection.stringValue, forKey: kInfoSection)
        pref.setString(cqZone.stringValue, forKey: kInfoZone)
        pref.setString(ituZone.stringValue, forKey: kInfoITU)
        pref.setString(brag.string, forKey: kBragTape)
    }
}
