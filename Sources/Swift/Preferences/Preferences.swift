//
//  Preferences.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on Thu May 20 2004.
//
//  Swift port of Preferences.m.  Base of the Config inheritance tree.
//
//  The plist keys and the kPlistDirectory / kDefaultPlist / kTextEncoding /
//  kNoOpenRouter constants live in Plist.h and TextEncoding.h (still reachable
//  through the bridging header) — they are referenced here, never redefined.
//

import Cocoa

@objc(Preferences)
class Preferences: NSObject {

    //  ---- ivars (former Obj-C instance variables) ------------------------
    //  'prefs' is read directly by the Config subclass (see updatePreferences),
    //  so it is exposed at the default (internal) access level.  'path' and
    //  'hasPlist' are used only inside this class -> private.
    internal let prefs = NSMutableDictionary()
    private var path: String = ""
    private var hasPlist: Bool = false

    /*  -------------------------------------------------------------------------

        1) Preferences init during app startup
            a) new empty dictionary created

        2) Config initPreference called
            a) adds default items to dictionary
            b) calls Config to fetchPlist, this updates the defaulted items

        3) cocoaModem applicationShouldTerminate called
            a) calls Config to savePlist
            b) application quits.
        ------------------------------------------------------------------------ */

    override init() {
        super.init()
        hasPlist = false
        //  prefs dictionary already created above

        //  make default pathname from bundle info
        let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String
        var str = kPlistDirectory                       //  "~/Library/Preferences/"
        if let bundleName = bundleName {
            str += bundleName
            str += ".plist"
        } else {
            //  use default name if plist path is not in bundle
            str += kDefaultPlist                         //  "w7ay.cocoaModem 2.0.plist"
        }
        //  v0.76 - Bundle name has changed to use a dash instead of spaces; place the
        //  space back to keep using the old plist (replace '-' with ' ' in first 120 chars)
        var chars = Array(str)
        let limit = min(120, chars.count)
        var i = 0
        while i < limit {
            if chars[i] == "-" { chars[i] = " " }
            i += 1
        }
        str = String(chars)
        path = (str as NSString).expandingTildeInPath
    }

    //  this is for creating a standalone dictionary (e.g., for exporting macros)
    @objc(initWithPath:)
    init?(path name: String) {
        super.init()
        hasPlist = false
        //  prefs dictionary already created above
        prefs.setObject(NSNumber(value: 0), forKey: kNoOpenRouter as NSString)
        path = name
    }

    //  Merge in plist data from .plist file
    @objc(fetchPlist:)
    func fetchPlist(_ importIfMissing: Bool) {
        if let xmlData = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            //  get plist from XML data (CFPropertyListCreateFromXMLData is awkward in Swift)
            if let plist = try? PropertyListSerialization.propertyList(from: xmlData, options: [], format: nil),
               let dict = plist as? [AnyHashable: Any] {
                //  merge and overwrite default values
                prefs.addEntries(from: dict)
            }
            hasPlist = true
        } else {
            hasPlist = false
            if importIfMissing {
                //  make default pathname from bundle info (1.0 plist)
                let oldPlistPath = "~/Library/Preferences/w7ay.cocoaModem.plist"
                let oldpath = (oldPlistPath as NSString).expandingTildeInPath
                if let oldXmlData = try? Data(contentsOf: URL(fileURLWithPath: oldpath)) {
                    //  modern NSAlert replacement for the deprecated
                    //  alertWithMessageText:defaultButton:alternateButton:otherButton: API
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Import Preferences from older version of cocoaModem?", comment: "")
                    alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                    alert.addButton(withTitle: NSLocalizedString("Skip", comment: ""))
                    if alert.runModal() == .alertFirstButtonReturn {
                        //  found 1.0 plist, make it the 2.0 plist
                        if let plist = try? PropertyListSerialization.propertyList(from: oldXmlData, options: [], format: nil),
                           let dict = plist as? [AnyHashable: Any] {
                            prefs.addEntries(from: dict)
                            hasPlist = true
                        }
                    }
                }
            }
        }
    }

    //  Write preference out to .plist file.
    //  The XML formatting is done by the NSMutableDictionary class upon a writeToFile call.
    @objc func savePlist() {
        _ = prefs.write(toFile: path, atomically: true)
    }

    //  check if key is in dictionary
    @objc(hasKey:)
    func hasKey(_ key: String) -> Bool {
        return prefs.object(forKey: key) != nil
    }

    @objc(booleanValueForKey:)
    func booleanValue(forKey key: String) -> Bool {                  //  v1.01b
        guard let num = prefs.object(forKey: key) as? NSNumber else { return false }
        return num.boolValue
    }

    @objc(intValueForKey:)
    func intValue(forKey key: String) -> Int32 {
        guard let num = prefs.object(forKey: key) as? NSNumber else { return 0 }
        return num.int32Value
    }

    @objc(incrementIntValueForKey:)
    func incrementIntValue(forKey key: String) {
        guard let num = prefs.object(forKey: key) as? NSNumber else { return }
        setInt(num.int32Value + 1, forKey: key)
    }

    @objc(setBoolean:forKey:)
    func setBoolean(_ value: Bool, forKey key: String) {            //  v1.01b
        prefs.setObject(NSNumber(value: value), forKey: key as NSString)
    }

    @objc(setInt:forKey:)
    func setInt(_ value: Int32, forKey key: String) {
        prefs.setObject(NSNumber(value: value), forKey: key as NSString)
    }

    @objc(floatValueForKey:)
    func floatValue(forKey key: String) -> Float {
        guard let num = prefs.object(forKey: key) as? NSNumber else { return 0 }
        return num.floatValue
    }

    @objc(setFloat:forKey:)
    func setFloat(_ value: Float, forKey key: String) {
        prefs.setObject(NSNumber(value: value), forKey: key as NSString)
    }

    //  Returns an implicitly-unwrapped optional to match the original unannotated
    //  Obj-C -stringValueForKey: (NSString*), so existing callers that assign the
    //  result straight into a non-optional String (e.g. field.stringValue = ...) keep compiling.
    @objc(stringValueForKey:)
    func stringValue(forKey key: String) -> String! {
        guard let obj = prefs.object(forKey: key) as? String else { return nil }
        return obj
    }

    @objc(setString:forKey:)
    func setString(_ string: String?, forKey key: String) {
        if string == nil {
            //  printf( "Preferences: bad string value for key %s\n", ... ) ;
            return
        }
        prefs.setObject(string!, forKey: key as NSString)
    }

    @objc(arrayForKey:)
    func array(forKey key: String) -> [Any]? {
        guard let obj = prefs.object(forKey: key) as? [Any] else { return nil }
        return obj
    }

    @objc(setArray:forKey:)
    func setArray(_ array: [Any]?, forKey key: String) {           //  v0.47
        guard let array = array else {
            print("Preferences: bad array value for key \(key)")
            return
        }
        prefs.setObject(array, forKey: key as NSString)
    }

    //  v0.78
    @objc(dictionaryForKey:)
    func dictionary(forKey key: String) -> [AnyHashable: Any]? {
        guard let obj = prefs.object(forKey: key) as? [AnyHashable: Any] else { return nil }
        return obj
    }

    //  v0.78
    @objc(setDictionary:forKey:)
    func setDictionary(_ dict: [AnyHashable: Any]?, forKey key: String) {
        guard let dict = dict else {
            print("Preferences: bad dictionary value for key \(key)")
            return
        }
        prefs.setObject(dict, forKey: key as NSString)
    }

    //  v0.72
    @objc(objectForKey:)
    func object(forKey key: String) -> Any? {
        return prefs.object(forKey: key)
    }

    //  Color in our Plist is expressed as an array of three floating point (R,G,B) elements
    @objc(colorValueForKey:)
    func colorValue(forKey key: String) -> NSColor? {
        guard let color = prefs.object(forKey: key) as? [Any], color.count >= 3 else { return nil }
        let r = (color[0] as? NSNumber)?.floatValue ?? 0
        let g = (color[1] as? NSNumber)?.floatValue ?? 0
        let b = (color[2] as? NSNumber)?.floatValue ?? 0
        return NSColor(calibratedRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
    }

    //  Color in our Plist is expressed as an array of three floating point (R,G,B) elements
    @objc(setColor:forKey:)
    func setColor(_ color: NSColor, forKey key: String) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let array = [NSNumber(value: Float(red)), NSNumber(value: Float(green)), NSNumber(value: Float(blue))]
        prefs.setObject(array, forKey: key as NSString)
    }

    //  Color in our Plist is expressed as an array of three floating point (R,G,B) elements
    @objc(setRed:green:blue:forKey:)
    func setRed(_ red: Float, green: Float, blue: Float, forKey key: String) {
        let array = [NSNumber(value: red), NSNumber(value: green), NSNumber(value: blue)]
        prefs.setObject(array, forKey: key as NSString)
    }

    @objc(removeKey:)
    func removeKey(_ key: String) {
        prefs.removeObject(forKey: key)
    }
}
