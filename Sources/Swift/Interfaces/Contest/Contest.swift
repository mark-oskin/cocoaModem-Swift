//
//  Contest.swift
//  cocoaModem
//
//  Created by Kok Chen on Mon Oct 04 2004.
//
//  Swift port of Contest.m.  The base contest engine: hash-table of worked
//  callsigns, dupe checking, XML journaling and Cabrillo export.  Subclass of
//  StripPhi (now Swift).  The C structs ContestQSO / Callsign (and MAXQ) live
//  in ContestTypes.h so they can be shared with the remaining Objective-C
//  (ContestManager).  The C helper functions band()/rttyFrequency()/... are
//  now Swift free functions in this file (still referenced by ContestQSOObj).
//

import Cocoa

let kLatin1Contest = String.Encoding.isoLatin1.rawValue

//  ---- module-level C-style helpers (replace the file-scope C functions) ----

//  write a string as ISO-Latin-1 bytes (fprintf is variadic and unavailable to
//  Swift; the byte output is identical).
func cmFPuts(_ s: String, _ file: UnsafeMutablePointer<FILE>?) {
    guard let file = file else { return }
    if let c = (s as NSString).cString(using: kLatin1Contest) { fputs(c, file) }
}

//  pointer to the char[64] first member of a Callsign
func callsignCName(_ c: UnsafeMutablePointer<Callsign>?) -> UnsafeMutablePointer<CChar>? {
    guard let c = c else { return nil }
    return UnsafeMutableRawPointer(c).assumingMemoryBound(to: CChar.self)
}

//  map a frequency (MHz) to a band (metres) -- referenced by ContestQSOObj
func band(_ freq: Float) -> Int32 {
    if freq < 1.7 { return 200 }
    if freq < 2.1 { return 160 }
    if freq < 4.1 { return 80 }
    if freq < 8.1 { return 40 }
    if freq < 11.1 { return 30 }
    if freq < 15.1 { return 20 }
    if freq < 19.1 { return 17 }
    if freq < 22.1 { return 15 }
    if freq < 25.1 { return 12 }
    if freq < 30.1 { return 10 }
    if freq < 60.1 { return 6 }
    return 2
}

private let defaultCWFrequency: [Float]   = [ 1.8, 3.525, 7.025, 14.025, 21.025, 28.025 ]
private let defaultRTTYFrequency: [Float] = [ 1.8, 3.580, 7.080, 14.080, 21.080, 28.080 ]
private let defaultSSBFrequency: [Float]  = [ 1.8, 3.750, 7.150, 14.150, 21.200, 28.350 ]
private let defaultPSKFrequency: [Float]  = [ 1.8, 3.610, 7.070, 14.070, 21.070, 28.120 ]

//  default RTTY frequency for a band -- referenced by ContestQSOObj
func rttyFrequency(_ band: Int32) -> Float {
    let b: Int
    switch band {
    case 160: b = 0
    case 80:  b = 1
    case 40:  b = 2
    case 15:  b = 4
    case 10:  b = 5
    default:  b = 3     // 20 (and any other)
    }
    return defaultRTTYFrequency[b]
}

func modeForString(_ str: String) -> Int32 {
    if str == "RY" { return RTTYMODE }
    if str == "CW" { return CWMODE }
    if str == "PH" { return SSBMODE }
    if str == "PK" { return PSKMODE }
    return CWMODE
}

func stringForMode(_ mode: Int32) -> String {
    switch mode {
    case RTTYMODE: return "RY"
    case CWMODE:   return "CW"
    case SSBMODE:  return "PH"
    case PSKMODE:  return "PK"
    default:       return "CW"
    }
}

//  copy a C string, replacing phi/Phi bytes with '0' (max ~61 chars, as original)
func cmStripPhi(_ input: UnsafePointer<CChar>?) -> String {
    guard let input = input else { return "" }
    var out = [CChar]()
    var p = input
    let zero = CChar(bitPattern: UInt8(ascii: "0"))
    var n = 0
    while p.pointee != 0 {
        let t = Int(UInt8(bitPattern: p.pointee))
        out.append((t == Int(phi) || t == Int(Phi)) ? zero : p.pointee)
        p += 1
        if n > 60 { break }
        n += 1
    }
    out.append(0)
    return NSString(cString: out, encoding: kLatin1Contest) as String? ?? ""
}

//  printf %-Ns / %Ns for strings (no truncation, matching C), plus a
//  C-strncpy-style truncation and a latin1 C-string -> String helper.  Used by
//  the Cabrillo QSO writers.
func ljust(_ s: String, _ w: Int) -> String {
    let n = s.count
    return n >= w ? s : s + String(repeating: " ", count: w - n)
}
func rjust(_ s: String, _ w: Int) -> String {
    let n = s.count
    return n >= w ? s : String(repeating: " ", count: w - n) + s
}
func cTrunc(_ s: String, _ n: Int) -> String {
    return String(s.prefix(n))
}
func latin1String(_ p: UnsafePointer<CChar>?) -> String {
    guard let p = p else { return "" }
    return NSString(cString: p, encoding: kLatin1Contest) as String? ?? ""
}
//  scan a leading integer from s, returning def if none (matches sscanf "%d")
func scanLeadingInt(_ s: String, _ def: Int32) -> Int32 {
    let sc = Scanner(string: s)
    var v = 0
    return sc.scanInt(&v) ? Int32(truncatingIfNeeded: v) : def
}

func saveQSONumberToXML(_ file: UnsafeMutablePointer<FILE>?, _ q: UnsafeMutablePointer<ContestQSO>) {
    cmFPuts(String(format: "\t\t\t<qnum>%d</qnum>\n", Int(q.pointee.qsoNumber)), file)
}

func saveCallToXML(_ file: UnsafeMutablePointer<FILE>?, _ q: UnsafeMutablePointer<ContestQSO>) {
    let call = cmStripPhi(callsignCName(q.pointee.callsign))
    cmFPuts("\t\t\t<call>\(call)</call>\n", file)
}

func saveDateToXML(_ file: UnsafeMutablePointer<FILE>?, _ q: UnsafeMutablePointer<ContestQSO>) {
    let t = q.pointee.time
    cmFPuts(String(format: "\t\t\t<date>%02d/%02d/%02d</date>\n", Int(t.day), Int(t.month), Int(t.year)), file)
}

func saveTimeToXML(_ file: UnsafeMutablePointer<FILE>?, _ q: UnsafeMutablePointer<ContestQSO>) {
    let t = q.pointee.time
    cmFPuts(String(format: "\t\t\t<time>%02d:%02d:%02d</time>\n", Int(t.hour), Int(t.minute), Int(t.second)), file)
}

func saveExchangeToXML(_ file: UnsafeMutablePointer<FILE>?, _ q: UnsafeMutablePointer<ContestQSO>) {
    let exch = cmStripPhi(q.pointee.exchange)
    cmFPuts("\t\t\t<exch>\(exch)</exch>\n", file)
}

func saveFrequencyToXML(_ file: UnsafeMutablePointer<FILE>?, _ q: UnsafeMutablePointer<ContestQSO>) {
    cmFPuts(String(format: "\t\t\t<freq>%.3f</freq>\n", Double(q.pointee.frequency)), file)
}

func saveModeToXML(_ file: UnsafeMutablePointer<FILE>?, _ q: UnsafeMutablePointer<ContestQSO>) {
    cmFPuts("\t\t\t<mode>\(stringForMode(Int32(q.pointee.mode)))</mode>\n", file)
}

private func makeDateTime(_ dt: inout DateTime, _ timet: time_t) {
    var tt = timet
    let t = gmtime(&tt)!.pointee
    dt.second = UInt8(truncatingIfNeeded: t.tm_sec)
    dt.minute = UInt8(truncatingIfNeeded: t.tm_min)
    dt.hour = UInt8(truncatingIfNeeded: t.tm_hour)
    dt.day = UInt8(truncatingIfNeeded: t.tm_mday)
    dt.month = UInt8(truncatingIfNeeded: t.tm_mon + 1)
    dt.year = UInt8(truncatingIfNeeded: (Int(t.tm_year) + 1900) % 100)
}

//  Informal access to the ContestManager methods used by the Contest tree,
//  resolved through dynamic dispatch.  This keeps ContestManager.h out of the
//  bridging header (mirrors CabrilloManager in Cabrillo.swift).
@objc protocol ContestManagerRef {
    func selectedContestInterface() -> ContestInterface?
    func allowDupe() -> Bool
    @objc(displayInfo:) func displayInfo(_ info: UnsafeMutablePointer<CChar>?)
    @objc(setDirty:) func setDirty(_ state: Bool)
    @objc(newQSOCreated:) func newQSOCreated(_ q: UnsafeMutablePointer<ContestQSO>)
    @objc(saveMacrosToXML:) func saveMacros(toXML file: UnsafeMutablePointer<FILE>?)
    @objc(saveCabrilloToXML:) func saveCabrillo(toXML file: UnsafeMutablePointer<FILE>?)
    func userInfoObject() -> UserInfo?
    @objc(expandMacroInUserAndQSOInfo:) func expandMacroInUserAndQSOInfo(_ macro: UnsafePointer<CChar>?) -> String?
    @objc(executeContestMacro:sheet:modem:) func executeContestMacro(_ n: Int32, sheet: Int32, modem: ContestInterface?) -> Bool
}

@objc(Contest)
class Contest: StripPhi, XMLParserDelegate {

    //  outlets connected by the prototype nib -- names must match nib keys exactly
    @objc var qsoNumberField: TransparentTextField!
    @objc var contestView: NSView!
    @objc var bandMenu: NSPopUpButton!
    @objc var logButton: NSButton!
    @objc var clearButton: NSButton!
    @objc var watermark: NSTextField!

    var client: ContestInterface!

    //  worked-callsign hash table and QSO lists (fixed C buffers -> heap)
    var activeCall: UnsafeMutablePointer<Callsign>?
    private let qso: UnsafeMutablePointer<Callsign>
    private let qsoList: UnsafeMutablePointer<UnsafeMutablePointer<ContestQSO>?>
    let sortedQSOList: UnsafeMutablePointer<UnsafeMutablePointer<ContestQSO>?>
    var numberOfQSO: Int32 = 0

    var activeBand: Int32 = 20
    var activeMode: Int32 = RTTYMODE
    var activeQSONumber: Int32 = 1
    private var oncePerMode = false     // one QSO per mode
    private var oncePerBand = true       // false = only once
    private var manyPerBand = false      // true = keep working the same station
    private var dupeState = false

    //  xml
    var parser: XMLParser?
    var parseContestName = false
    var parseContestLog = false
    var parseQSO = false
    var parseContest = false

    @objc var contestName: String = ""
    @objc var prototypeName: String = "Generic"
    var savedCallsign: String = ""
    var savedExchange: String = ""

    var manager: ContestManagerRef!
    var master: Contest?
    var activeSubordinate: Contest?

    var subordinate = [Contest?](repeating: nil, count: 16)
    var subordinates: Int32 = 0

    //  Cabrillo
    var cabrilloFile: UnsafeMutablePointer<FILE>?
    private var cabrilloContest: String = ""
    private var cabrilloCategorySuffix: String? = nil
    var userInfo: UserInfo?
    var cabrillo: Cabrillo!
    var usedCallString: String?
    var importedFrequency: Float = 0

    private var previousField: TransparentTextField?
    var previousCall: String = ""

    //  alphabet / numeric check
    var isAlpha = [Bool](repeating: false, count: 256)
    var isNumeric = [Bool](repeating: false, count: 256)

    //  ---- initialization ----

    override init() {
        qso = UnsafeMutablePointer<Callsign>.allocate(capacity: Int(MAXQ))
        qsoList = UnsafeMutablePointer<UnsafeMutablePointer<ContestQSO>?>.allocate(capacity: Int(MAXQ))
        sortedQSOList = UnsafeMutablePointer<UnsafeMutablePointer<ContestQSO>?>.allocate(capacity: Int(MAXQ))
        super.init()
        configureInitialState()
    }

    deinit {
        qso.deallocate()
        qsoList.deallocate()
        sortedQSOList.deallocate()
    }

    private func configureInitialState() {
        activeCall = nil
        activeBand = 20
        activeMode = RTTYMODE
        activeQSONumber = 1
        oncePerMode = false
        oncePerBand = true
        manyPerBand = false
        dupeState = false
        parser = nil
        master = nil
        manager = nil
        prototypeName = "Generic"
        cabrilloContest = ""
        cabrilloCategorySuffix = nil
        previousField = nil
        activeSubordinate = nil
        savedCallsign = ""
        savedExchange = ""
        previousCall = ""

        //  zero the hash table then build the free-list ring
        memset(qso, 0, Int(MAXQ) * MemoryLayout<Callsign>.stride)
        memset(qsoList, 0, Int(MAXQ) * MemoryLayout<UnsafeMutablePointer<ContestQSO>?>.stride)
        memset(sortedQSOList, 0, Int(MAXQ) * MemoryLayout<UnsafeMutablePointer<ContestQSO>?>.stride)

        let last = Int(MAXQ) - 1
        for i in 0..<last {
            qso[i].link = nil
            qso[i].next = qso.advanced(by: i + 1)
        }
        strcpy(callsignCName(qso.advanced(by: last)), "****")
        qso[last].link = nil
        qso[last].next = qso

        for i in 0..<256 {
            isAlpha[i] = (i >= Int(UInt8(ascii: "a")) && i <= Int(UInt8(ascii: "z"))) ||
                         (i >= Int(UInt8(ascii: "A")) && i <= Int(UInt8(ascii: "Z")))
        }
        for i in 0..<256 {
            isNumeric[i] = (i >= Int(UInt8(ascii: "0")) && i <= Int(UInt8(ascii: "9")))
        }
        isNumeric[Int(phi)] = true
        isNumeric[Int(Phi)] = true
    }

    func setInterface(_ object: NSControl?, to selector: Selector) {
        object?.action = selector
        object?.target = self
    }

    func initializeActions() {
        setInterface(logButton, to: #selector(logButtonPushed))
        setInterface(clearButton, to: #selector(clearButtonPushed))
        setInterface(bandMenu, to: #selector(bandMenuChanged))
    }

    func modemClient() -> ContestInterface! {
        return client
    }

    //  override by instance to pick the field to use as first responder
    func selectFirstResponderInActivePanel() {
    }

    @objc func selectFirstResponder() {
        if master != nil {
            selectFirstResponderInActivePanel()
        } else {
            let selectedModem = manager?.selectedContestInterface()
            activeMode = selectedModem?.transmissionMode() ?? activeMode
            for i in 0..<Int(subordinates) {
                if let sub = subordinate[i], sub.modemClient() === selectedModem {
                    sub.selectFirstResponder()
                    activeSubordinate = sub
                }
            }
        }
    }

    //  ---- designated set-up initializers (ObjC alloc/init pattern) ----

    @objc(initIntoBox:contestName:prototype:modem:master:manager:)
    convenience init?(intoBox box: NSBox?, contestName name: String, prototype: String, modem inClient: ContestInterface?, master inMaster: Contest?, manager mgr: Any?) {
        self.init()
        client = inClient
        manager = mgr as? ContestManagerRef
        master = inMaster
        parser = nil
        subordinates = 0
        numberOfQSO = 0
        parseContest = false; parseContestName = false; parseContestLog = false; parseQSO = false
        contestName = name
        if let box = box {
            //  subordinate
            if Bundle.main.loadNibNamed(prototype, owner: self, topLevelObjects: nil), contestView != nil {
                let content = box.contentView
                if let views = content?.subviews, views.count > 0 {
                    views[0].removeFromSuperview()
                }
                box.addSubview(contestView)
                if let wm = watermark {
                    contestView.addSubview(wm, positioned: .above, relativeTo: nil)
                }
                if let logButton = logButton {
                    //  add cmd-L to the button title
                    var u: [unichar] = [0x2318, unichar(UInt8(ascii: "L"))]
                    let commandL = NSString(characters: &u, length: 2) as String
                    logButton.title = "Log  " + commandL
                }
            } else {
                return nil
            }
        }
        prototypeName = prototype

        if master != nil {
            setupFields()
        }
    }

    //  master
    @objc(initContestName:prototype:parser:manager:)
    convenience init?(contestName name: String, prototype: String, parser inParser: XMLParser?, manager inManager: Any?) {
        self.init(intoBox: nil, contestName: name, prototype: prototype, modem: nil, master: nil, manager: inManager)

        importedFrequency = 14.080
        manager = inManager as? ContestManagerRef
        parser = inParser
        prepareForParsing()
        if let parser = inParser {
            parser.delegate = self
            parser.parse()
        }
    }

    //  override hook: set up master-only state before the XML parse begins
    //  (RTTYRoundup uses it to build its multiplier table)
    func prepareForParsing() {
    }

    //  add subordinates to master
    @objc(addSubordinate:)
    func addSubordinate(_ sub: Contest) {
        if master == nil {
            if subordinates < 15 {
                subordinate[Int(subordinates)] = sub
                subordinates += 1
                sub.updateBandMenu(importedFrequency)
            }
        }
    }

    func isEmpty(_ field: NSTextField) -> Bool {
        //  original also had a no-op whitespace scan that always broke on the
        //  first byte, so the field is "empty" iff its length is zero.
        return (field.stringValue as NSString).length == 0
    }

    //  update band menu from selected (importedFrequency) frequency
    func updateBandMenu(_ freq: Float) {
        if master != nil { return }
        let v = band(freq)
        let n = bandMenu.numberOfItems
        for i in 0..<n {
            if bandMenu.item(at: i)?.tag == Int(v) {
                bandMenu.selectItem(at: i)
                break
            }
        }
        bandSwitched(v)
    }

    //  subclasses of Contest should override this to set up fields
    func setupFields() {
        if master != nil { master?.setCabrilloContestName("**REPLACE-ME**") }
    }

    //  ---- hash table ----

    //  look for a callsign in the hash table, creating an entry if needed
    func hashCallsign(_ call: UnsafePointer<CChar>) -> UnsafeMutablePointer<Callsign>? {
        var h: UInt = 0
        var c = call
        var i = 0
        while i < 32 {
            if c.pointee == 0 { break }
            h = (h << 2) &+ (UInt(UInt8(bitPattern: c.pointee)) & 0xff)
            c += 1
            i += 1
        }
        h = h & UInt(MAXQ - 1)
        var p = qso.advanced(by: Int(h))
        i = 0
        while i < Int(MAXQ) {
            if callsignCName(p)!.pointee == 0 {
                strcpy(callsignCName(p), call)
                p.pointee.link = nil
                return p
            }
            if strcmp(callsignCName(p), call) == 0 { return p }
            p = p.pointee.next!
            i += 1
        }
        print("cocoaModem: hash table out of memory?!")
        return nil
    }

    func defaultFrequencyForBand() -> Float {
        let b: Int
        switch activeBand {
        case 160: b = 0
        case 80:  b = 1
        case 40:  b = 2
        case 15:  b = 4
        case 10:  b = 5
        default:  b = 3
        }
        if activeMode == CWMODE { return defaultCWFrequency[b] }
        if activeMode == SSBMODE { return defaultSSBFrequency[b] }
        if activeMode == PSKMODE { return defaultPSKFrequency[b] }
        return defaultRTTYFrequency[b]
    }

    //  return activeCall from master
    func currentCallsign() -> UnsafeMutablePointer<Callsign>? {
        if let master = master { return master.currentCallsign() }
        return activeCall
    }

    //  return callsign if not dupe, nil if dupe
    func getCallsignCheckingDupe(_ call: UnsafePointer<CChar>?) -> UnsafeMutablePointer<Callsign>? {
        guard let call = call, call.pointee != 0 else { return nil }

        activeCall = hashCallsign(call)
        if manyPerBand { return activeCall }        // unlimited calls

        var qsoLink = activeCall?.pointee.link
        for _ in 0..<2000 {
            guard let link = qsoLink else { return activeCall }

            if band(link.pointee.frequency) == activeBand {
                //  worked once already on this band
                if !oncePerMode || activeMode == Int32(link.pointee.mode) {
                    let t = link.pointee.time
                    let callStr = NSString(cString: callsignCName(link.pointee.callsign)!, encoding: kLatin1Contest) as String? ?? ""
                    let exchStr = link.pointee.exchange != nil ? (NSString(cString: link.pointee.exchange!, encoding: kLatin1Contest) as String? ?? "") : ""
                    let info = String(format: "DUPE: %d-%02d-%02d %02d:%02d (%d) %@ Received:%@",
                                      Int(t.day), Int(t.month), Int(t.year), Int(t.hour), Int(t.minute),
                                      Int(link.pointee.qsoNumber), callStr as NSString, exchStr as NSString)
                    displayInfo(info)
                    return nil
                }
            }
            qsoLink = link.pointee.next
        }
        return activeCall
    }

    func getCallsign(_ call: UnsafePointer<CChar>?) -> UnsafeMutablePointer<Callsign>? {
        guard let call = call else { return nil }
        activeCall = hashCallsign(call)
        return activeCall
    }

    //  override by instances which handle mults
    func createMult(_ p: UnsafeMutablePointer<ContestQSO>) {
    }

    //  create a new QSO in the database
    func createQSO(_ p: UnsafeMutablePointer<ContestQSO>, callsign call: UnsafeMutablePointer<Callsign>?, mode: Int32) {
        guard let call = call else {
            print("cocoaModem: createQSO called with nil callsign")
            return
        }
        createMult(p)
        qsoList[Int(numberOfQSO)] = p
        numberOfQSO += 1
        p.pointee.next = nil
        p.pointee.callsign = call
        p.pointee.mode = Int16(truncatingIfNeeded: mode)
        //  add to linked list
        if call.pointee.link == nil {
            call.pointee.link = p
        } else {
            var q = call.pointee.link
            while let qq = q {
                if qq.pointee.next == nil {
                    qq.pointee.next = p
                    break
                }
                q = qq.pointee.next
            }
        }
        manager?.setDirty(true)
        manager?.newQSOCreated(p)
        activeQSONumber += 1
    }

    func createQSOFromCurrentData() -> UnsafeMutablePointer<ContestQSO> {
        let p = UnsafeMutablePointer<ContestQSO>.allocate(capacity: 1)
        p.pointee.frequency = defaultFrequencyForBand()
        makeDateTime(&p.pointee.time, time(nil))
        p.pointee.mode = Int16(truncatingIfNeeded: activeMode)
        p.pointee.rst = 0
        p.pointee.qsoNumber = UInt16(truncatingIfNeeded: activeQSONumber)
        //  Contest subclasses fill in these...
        p.pointee.callsign = nil
        p.pointee.exchange = nil
        return p
    }

    //  overide by subclasses of Contest
    @objc(newQSO:)
    func newQSO(_ n: Int32) {
    }

    //  overide by subclasses of Contest
    @objc func clearCurrentQSO() {
    }

    //  overide by subclasses of Contest -- get callsign directly from the field
    func fetchCallString() -> String { return "" }
    func fetchSavedCallString() -> String { return "" }
    func fetchReceivedExchange() -> String { return "" }
    func fetchSavedReceivedExchange() -> String { return "" }

    //  get number directly from the number field
    func fetchExchangeNumberString() -> String {
        return qsoNumberField?.stringValue ?? ""
    }

    //  get callsign (only from master)
    @objc func callsign() -> String? {
        if master != nil { return nil }
        guard let sub = activeSubordinate else { return nil }
        return sub.fetchCallString()
    }

    //  renamed from -dxExchange to avoid an ObjC selector clash with the
    //  RSTExchange/Generic `dxExchange` nib outlet (which is a distinct member).
    //  Sole caller (ContestManager.m -updateQSOInfo) is updated to match.
    @objc func fetchDXExchange() -> String? {
        if master != nil { return nil }
        guard let sub = activeSubordinate else { return nil }
        return sub.fetchReceivedExchange()
    }

    //  overide by subclasses of Contest
    @objc func selectActiveField() {
    }

    //  get QSO number (only from master)
    @objc func qsoNumber() -> String {
        if master != nil { return "1" }
        guard let sub = subordinate[0] else { return "1" }
        return sub.fetchExchangeNumberString()
    }

    //  only in master -- returns nil if dupe
    func receivedCallsign(_ call: String?, band inBand: Int32, isDupe: inout Bool) -> UnsafeMutablePointer<Callsign>? {
        if master != nil { return nil }
        guard let call = call else { return nil }

        activeBand = inBand
        var c = getCallsignCheckingDupe((call as NSString).cString(using: kLatin1Contest))
        if c == nil {
            isDupe = true
            if manager?.allowDupe() == true {
                c = getCallsign((call as NSString).cString(using: kLatin1Contest))
            }
        } else {
            isDupe = false
        }
        dupeState = (c == nil)
        return c
    }

    //  only in master -- move the QSO entry under a different callsign
    @objc(changeQSO:to:)
    func changeQSO(_ oldqso: UnsafeMutablePointer<ContestQSO>, to callsign: UnsafeMutablePointer<CChar>) {
        guard let oldhead = hashCallsign(callsignCName(oldqso.pointee.callsign)!) else { return }

        var link = oldhead.pointee.link
        if link == oldqso {
            oldhead.pointee.link = oldqso.pointee.next
        } else {
            while true {
                guard let l = link else { return }
                if l.pointee.next == oldqso {
                    l.pointee.next = oldqso.pointee.next
                    break
                }
                if l.pointee.next == nil { return }
                link = l.pointee.next
            }
        }
        //  oldqso has been isolated
        guard let newhead = hashCallsign(callsign) else { return }
        oldqso.pointee.callsign = newhead
        oldqso.pointee.next = nil
        if newhead.pointee.link == nil {
            newhead.pointee.link = oldqso
            return
        }
        var l = newhead.pointee.link
        while let ll = l {
            if ll.pointee.next == nil {
                ll.pointee.next = oldqso
                return
            }
            l = ll.pointee.next
        }
    }

    //  only in master -- send post-logging macro
    func logMacro() {
        let str = cabrillo?.logExtensionString() ?? ""
        if !str.isEmpty { client?.executeMacroString(str) }
    }

    //  only in master -- returns old state
    @discardableResult
    func setDupeState(_ state: Bool) -> Bool {
        let old = dupeState
        dupeState = state
        return old
    }

    func isDuped() -> Bool {
        return dupeState
    }

    //  only in subordinate
    func setWatermarkState(_ state: Bool) {
        if master != nil {
            watermark?.stringValue = state ? "DUPE" : ""
            if state == false { displayInfo("") }
        }
    }

    func setSmallWatermarkState(_ state: Bool) {
        if master != nil {
            watermark?.stringValue = state ? "*" : ""
            if state == false { displayInfo("") }
        }
    }

    //  override by subclasses if something else needs to be done on band switch
    func bandSwitched(_ band: Int32) {
        activeBand = band
    }

    func selectField(_ field: NSTextField) {
        field.selectText(self)
    }

    //  ---- journaling / XML ----

    func saveQSOToXML(_ file: UnsafeMutablePointer<FILE>?, qso q: UnsafeMutablePointer<ContestQSO>) {
        cmFPuts("\t\t<QSO>\n", file)
        saveQSONumberToXML(file, q)
        saveCallToXML(file, q)
        saveDateToXML(file, q)
        saveTimeToXML(file, q)
        saveModeToXML(file, q)
        saveExchangeToXML(file, q)
        saveFrequencyToXML(file, q)
        cmFPuts("\t\t</QSO>\n", file)
    }

    //  dump all QSO up to this point to the journal
    @objc(updateQSOToJournal:)
    func updateQSO(toJournal file: UnsafeMutablePointer<FILE>) {
        saveXMLHead(file, isJournal: true)
        cmFPuts("\t<contestLog>\n", file)
        for i in 0..<Int(numberOfQSO) {
            if let q = qsoList[i] { saveQSOToXML(file, qso: q) }
        }
        fflush(file)
    }

    func journalQSO(_ q: UnsafeMutablePointer<ContestQSO>) {
        if cabrilloFile == nil {
            cabrilloFile = cabrillo?.openJournalFile(self)
            //  this should cause the QSO log up to this point to be dumped out
            return
        }
        saveQSOToXML(cabrilloFile, qso: q)
        if let f = cabrilloFile { fflush(f) }
    }

    @objc func createNewJournal() {
        cabrilloFile = (cabrilloFile == nil) ? cabrillo?.openJournalFile(self) : cabrillo?.reOpenJournalFile(self)
    }

    func saveLogToXML(_ file: UnsafeMutablePointer<FILE>?) {
        cmFPuts("\t<contestLog>\n", file)
        for i in 0..<Int(numberOfQSO) {
            if let q = qsoList[i] { saveQSOToXML(file, qso: q) }
        }
        cmFPuts("\t</contestLog>\n", file)
    }

    func saveXMLHead(_ file: UnsafeMutablePointer<FILE>?, isJournal: Bool) {
        cmFPuts("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n", file)
        if isJournal { cmFPuts("<!-- |journal| -->\n", file) }
        cmFPuts("<Contest>\n", file)
        cmFPuts("\t<contestName>\(contestName)</contestName>\n", file)
        let exchangeString = cabrillo?.exchangeString() ?? ""
        cmFPuts("\t<sent>\(exchangeString)</sent>\n", file)
        manager?.saveMacros(toXML: file)
        manager?.saveCabrillo(toXML: file)
    }

    //  save contest
    func saveXML(_ path: String) {
        guard let saveFile = fopen((path as NSString).cString(using: kLatin1Contest), "w") else { return }
        saveXMLHead(saveFile, isJournal: false)
        saveLogToXML(saveFile)
        cmFPuts("</Contest>\n", saveFile)
        fclose(saveFile)
    }

    //  overide by subclasses of Contest
    @objc(saveContest:)
    func saveContest(_ path: String) {
        saveXML(path)
    }

    @objc func showMultsWindow() {
        Messages.alert(withMessageText: "No multiplier panel for this contest.", informativeText: "Sorry.  Multiplier counting is not implemented for this contest.")
    }

    func switchBandTo(_ which: Int32, index: Int32) {
        activeBand = which
        if master == nil {
            for i in 0..<Int(subordinates) {
                subordinate[i]?.switchBandTo(which, index: index)
            }
        } else {
            //  visible instances
            bandSwitched(which)
            if self !== activeSubordinate { bandMenu.selectItem(at: Int(index)) }
        }
    }

    @objc func bandMenuChanged() {
        if self !== activeSubordinate, master != nil {
            let tag = Int32(bandMenu.selectedItem?.tag ?? 0)
            master?.switchBandTo(tag, index: Int32(bandMenu.indexOfSelectedItem))
        }
    }

    //  overide by subclasses of Contest
    @objc func logButtonPushed() {
    }

    //  overide by subclasses if needed -- default calls clearCurrentQSO in the subclass
    @objc func clearButtonPushed() {
        master?.clearCurrentQSO()
    }

    //  ---- Cabrillo ----

    private func convertToBand(_ s: String) -> String {
        return s.hasPrefix("ALL") ? "ALL" : s
    }

    //  called from setupFields of a subordinate
    func setCabrilloContestName(_ s: String) {
        cabrilloContest = s
    }

    func setCabrilloCategorySuffix(_ str: String) {
        cabrilloCategorySuffix = str
    }

    private func sortQSOForCabrillo() {
        //  just copy over for now
        for i in 0..<Int(MAXQ) { sortedQSOList[i] = qsoList[i] }
    }

    //  override by contests' individual formats
    func writeCabrilloQSOs() {
    }

    //  override by contests which don't use the ARRL categories
    func writeCabrilloCategory() {
        var category = (cabrillo.category()).uppercased()
        if category.hasPrefix("SINGLE-OP") {
            var band = (cabrillo.band()).uppercased()
            band = convertToBand(band)

            let tail = String((category as NSString).length > 10 ? (category as NSString).substring(from: 10) : "")
            if tail == "ASSISTED" {
                category = "SINGLE-OP-ASSISTED " + band
            } else {
                category = "SINGLE-OP " + band + " " + tail
            }
        }
        if let suffix = cabrilloCategorySuffix {
            cmFPuts("CATEGORY: \(category) \(suffix)\n", cabrilloFile)
        } else {
            cmFPuts("CATEGORY: \(category)\n", cabrilloFile)
        }
    }

    func writeCabrilloFields() {
        cmFPuts("CONTEST: \(cabrilloContest)\n", cabrilloFile)

        writeCabrilloCategory()

        let name = cabrillo.name()
        if !name.isEmpty { cmFPuts("NAME: \(name)\n", cabrilloFile) }

        var str = cabrillo.addr1()
        if !str.isEmpty { cmFPuts("ADDRESS: \(str)\n", cabrilloFile) }

        if name.isEmpty || str.isEmpty {
            Messages.alert(withMessageText: "No post office name/address in Contest panel.", informativeText: "Please enter the name and postal address fields (address where plaques and certificates are mailed to).")
        }

        str = cabrillo.addr2()
        if !str.isEmpty { cmFPuts("ADDRESS: \(str)\n", cabrilloFile) }
        str = cabrillo.addr3()
        if !str.isEmpty { cmFPuts("ADDRESS: \(str)\n", cabrilloFile) }
        str = cabrillo.email()
        if !str.isEmpty { cmFPuts("ADDRESS: E-mail: \(str)\n", cabrilloFile) }

        str = cabrillo.operators()
        if !str.isEmpty { cmFPuts("OPERATORS: \(str)\n", cabrilloFile) }
        str = cabrillo.club()
        if !str.isEmpty { cmFPuts("CLUB: \(str)\n", cabrilloFile) }

        var soap = cabrillo.soapbox()
        while !soap.isEmpty {
            let ns = soap as NSString
            if ns.length <= 64 {
                cmFPuts("SOAPBOX: \(soap)\n", cabrilloFile)
                soap = ""
            } else {
                let first64 = ns.substring(to: 64)
                let arr = Array(first64.utf16)
                var i = 63
                var cutAt = 0
                while i > 0 {
                    if arr[i] == 32 || arr[i] == 9 { cutAt = i; break }
                    i -= 1
                }
                if cutAt != 0 {
                    cmFPuts("SOAPBOX: \((first64 as NSString).substring(to: cutAt))\n", cabrilloFile)
                    soap = ns.substring(from: cutAt + 1)
                } else {
                    cmFPuts("SOAPBOX: \(first64)\n", cabrilloFile)
                    soap = ns.substring(from: 64)
                }
            }
        }
    }

    @objc(setCabrillo:)
    func setCabrillo(_ obj: Cabrillo) {
        cabrillo = obj
    }

    @objc(writeCabrilloToPath:callsign:)
    func writeCabrillo(toPath path: String, callsign: String) {
        userInfo = manager?.userInfoObject()

        cabrilloFile = fopen((path as NSString).cString(using: kLatin1Contest), "w")
        cmFPuts("START-OF-LOG: 2.0\n", cabrilloFile)

        //  create a CREATED-BY field with version number
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            cmFPuts("CREATED-BY: cocoaModem 2.0 v\(version) (W7AY)\n", cabrilloFile)
        }
        usedCallString = callsign
        cmFPuts("CALLSIGN: \(callsign)\n", cabrilloFile)

        writeCabrilloFields()

        sortQSOForCabrillo()
        writeCabrilloQSOs()

        cmFPuts("END-OF-LOG:\n", cabrilloFile)
        if let f = cabrilloFile { fclose(f) }
    }

    //  ---- AppleScript support ----

    @objc(selectBand:)
    func selectBand(_ v: Int32) {
        if master == nil {
            if v == 160 || v == 80 || v == 40 || v == 20 || v == 15 || v == 10 {
                for i in 0..<Int(subordinates) {
                    subordinate[i]?.selectBand(v)
                }
            }
        } else {
            let n = bandMenu.numberOfItems
            for i in 0..<n {
                if bandMenu.item(at: i)?.tag == Int(v) {
                    bandMenu.selectItem(at: i)
                    break
                }
            }
        }
        bandSwitched(v)
    }

    @objc func selectedBand() -> Int32 {
        return activeBand
    }

    //  ---- ContestManager helper ----

    private func displayInfo(_ s: String) {
        s.withCString { cptr in
            manager?.displayInfo(UnsafeMutablePointer(mutating: cptr))
        }
    }
}
