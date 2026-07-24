//
//  ContestManager.swift
//  cocoaModem
//
//  Created by Kok Chen on 10/17/04.
//  Swift port of ContestManager.{h,m} -- the last Objective-C class in the
//  cocoaModem 2.0 modernization.
//
//  Port notes:
//   * Every original ivar is preserved as a stored property with its EXACT
//     original name, EXCEPT the Boolean state ivar `allowDupe`, which collided
//     with the `-allowDupe` accessor (Swift cannot have a property and a method
//     of the same name).  It is renamed `allowDupeState`; the getter/setter keep
//     their `allowDupe()` / `setAllowDupe(_:)` selectors so callers are unchanged.
//   * Carbon `Boolean` params/returns import to plain `Bool` in this codebase
//     (verified against the already-Swift consumers), so the Boolean state ivars
//     and the allowDupe/executeContestMacro/contestSwitchedToCQ/okToQuit APIs use
//     `Bool` (not DarwinBoolean).
//   * The two-phase `allocContest` (bare +alloc, then a separate -initContestName:
//     ... in place) is folded into `makeContest(_:parser:)`, which selects the
//     Contest subclass and returns a fully initialised instance (Swift cannot
//     +alloc without initialising).  It preserves allocContest's side effect of
//     setting `prototypeName`.
//   * Deprecated/removed AppKit panel APIs (runModalForDirectory:file:types:,
//     -filename, -filenames, NSOKButton) are modernised to NSOpenPanel/NSSavePanel
//     runModal() == .OK + .url, matching the rest of the converted codebase.
//   * The NSXMLParser delegate state machine (isContestName / isMacros /
//     isCabrillo / ...) is preserved verbatim.
//

import Cocoa

//  kTextEncoding == NSISOLatin1StringEncoding (see TextEncoding.h); redeclared
//  locally as the C #define macro is not visible to Swift.
private let kTextEncoding = String.Encoding.isoLatin1.rawValue
//  Plist.h: #define kRecentContest @"Recent Contest"  (not visible to Swift)
private let kRecentContest = "Recent Contest"
//  ContestManager.h: #define kTempFile "/tmp/cocoaModemTempFile"
private let kTempFile = "/tmp/cocoaModemTempFile"

@objc(ContestManager)
class ContestManager: NSObject, XMLParserDelegate {

	//  --- IBOutlets ---
	@IBOutlet var application: Application!
	@IBOutlet var stdManager: StdManager!
	@IBOutlet var contestMenu: NSMenu!
	@IBOutlet var cabrilloMenuItem: NSMenuItem!
	@IBOutlet var saveMenuItem: NSMenuItem!
	@IBOutlet var saveAsMenuItem: NSMenuItem!
	@IBOutlet var showLogMenuItem: NSMenuItem!
	@IBOutlet var showMultMenuItem: NSMenuItem!
	@IBOutlet var recentContestMenuItem: NSMenuItem!
	@IBOutlet var clearQSOMenuItem: NSMenuItem!
	@IBOutlet var ignoreNewlineMenuItem: NSMenuItem!

	//  --- state ---
	var selectedMenuItem: NSMenuItem?
	var isContestName: Bool = false
	var isMacros: Bool = false
	var isCabrillo: Bool = false
	var ignoreNewline: Bool = false
	var isCaption: Bool = false, isMessage: Bool = false, isExchange: Bool = false
	var isCName: Bool = false, isAddr1: Bool = false, isAddr2: Bool = false, isAddr3: Bool = false, isEmail: Bool = false, isCategory: Bool = false, isBand: Bool = false, isCallUsed: Bool = false, isNameUsed: Bool = false, isClub: Bool = false, isOperator: Bool = false, isSoapbox: Bool = false
	var messageSheet: Int = 0
	var captionSheet: Int = 0
	var xmlError: Bool = false
	//  original ivar `allowDupe`; renamed to avoid clashing with -allowDupe accessor
	private var allowDupeState: Bool = false

	//  log
	var contestLog: ContestLog?

	//  save file
	var dirty: Bool = false
	var sessionStarted: Bool = false
	var saveFileName: String?

	//  contest strings
	var contestName: String?
	var prototypeName: String = "Generic"
	var contestCallsign: String? = ""
	var myName: String? = ""

	var userInfo: UserInfo?
	var cabrilloInfo: Cabrillo?
	var qsoInfo: QSO?
	//  macros -- fixed-size [6] (3 for CQ mode, 3 for S&P mode)
	var contestMacroSheet: [ContestMacroSheet?] = Array(repeating: nil, count: 6)
	//  master contest instance
	var master: Contest?
	//  clients
	var currentModem: ContestInterface?
	var client: [ContestInterface?] = Array(repeating: nil, count: 64)
	var clients: Int = 0
	//  preferences
	var preference: Preferences?

	//  =======================================================================

	//  ascii code of a single-character Character (for macro-code comparisons)
	private func ascii(_ c: Character) -> Int32 {
		return Int32(c.asciiValue ?? 0)
	}

	//  open a file with the path encoded as ISO Latin-1 (matches the original
	//  cStringUsingEncoding:kTextEncoding on every fopen path)
	private func openFile(_ path: String, _ mode: String) -> UnsafeMutablePointer<FILE>? {
		guard let c = (path as NSString).cString(using: kTextEncoding) else { return nil }
		return fopen(c, mode)
	}

	func setInterface(_ object: Any?, to selector: Selector) {
		if let item = object as? NSMenuItem {
			item.action = selector
			item.target = self
		} else if let control = object as? NSControl {
			control.action = selector
			control.target = self
		}
	}

	//  make sure to init macros only after the application is awake
	@objc func initContestMacros() {
		let sheetName = [ "Contest macros (CQ)", "Contest option macros (CQ)", "Contest option-shift macros (CQ)", "Contest macros (S&P)", "Contest option macros (S&P)", "Contest option-shift macros (S&P)" ]

		userInfo = application?.userInfoObject()
		qsoInfo = stdManager?.qsoObject()

		for i in 0..<6 {
			//  3 for CQ mode, 3 for S&P code
			let sheet = ContestMacroSheet(sheet: ())
			contestMacroSheet[i] = sheet
			sheet.setName(sheetName[i])
			sheet.setUserInfo(userInfo, qso: qsoInfo, modem: currentModem, canImport: true)
			sheet.delegateTextChanges(to: self)
		}
	}

	override func awakeFromNib() {
		setInterface(ignoreNewlineMenuItem, to: #selector(ignoreNewlineChanged))
		ignoreNewlineMenuItem?.state = .off
		ignoreNewline = false
	}

	@objc func ignoreNewlineChanged() {
		ignoreNewline = !ignoreNewline
		ignoreNewlineMenuItem?.state = ignoreNewline ? .on : .off
		for i in 0..<clients { client[i]?.setIgnoreNewline(ignoreNewline) }
	}

	//  MyCall notification message from one of the callsign spots
	@objc(checkCallsign:)
	func checkCallsign(_ notify: Notification?) {
		var str = cabrilloInfo?.callUsed() ?? ""
		if str.isEmpty { str = userInfo?.call() ?? "" }
		contestCallsign = str.isEmpty ? "" : str.uppercased()
	}

	//  MyName notification message from one of the callsign spots
	@objc(checkName:)
	func checkName(_ notify: Notification?) {
		var str = cabrilloInfo?.nameUsed() ?? ""
		if str.isEmpty { str = userInfo?.name() ?? "" }
		myName = str.isEmpty ? "" : str
	}

	//  SetDirty notification
	@objc(setDirtyBit:)
	func setDirtyBit(_ notify: Notification?) {
		setDirty(true)
	}

	@objc func awakeFromApplication() {
		contestName = nil
		contestCallsign = ""
		myName = ""
		prototypeName = "Generic"
		saveFileName = nil
		master = nil
		selectedMenuItem = nil
		currentModem = nil
		dirty = false
		sessionStarted = false
		allowDupeState = false
		preference = nil

		//  create ContestLog
		contestLog = ContestLog(manager: self)

		cabrilloInfo = Cabrillo(manager: self)
		contestMenu?.autoenablesItems = false
		showLogMenuItem?.isEnabled = false
		showMultMenuItem?.isEnabled = false
		cabrilloMenuItem?.isEnabled = false
		ignoreNewlineMenuItem?.isEnabled = false
		saveMenuItem?.isEnabled = false
		saveAsMenuItem?.isEnabled = false
		clearQSOMenuItem?.isEnabled = false
		let center = NotificationCenter.default
		center.addObserver(self, selector: #selector(checkCallsign(_:)), name: NSNotification.Name("MyCall"), object: nil)
		center.addObserver(self, selector: #selector(checkName(_:)), name: NSNotification.Name("MyName"), object: nil)
		center.addObserver(self, selector: #selector(setDirtyBit(_:)), name: NSNotification.Name("SetDirty"), object: nil)

		contestLog?.awakeFromManager()
	}

	@objc(displayInfo:)
	func displayInfo(_ info: UnsafeMutablePointer<CChar>!) {
		contestLog?.displayInfo(info)
	}

	@objc(setAllowDupe:)
	func setAllowDupe(_ state: Bool) {
		allowDupeState = state
	}

	@objc func allowDupe() -> Bool {
		return allowDupeState
	}

	@objc(newQSOCreated:)
	func newQSOCreated(_ q: UnsafeMutablePointer<ContestQSO>!) {
		contestLog?.newQSOCreated(q)
	}

	@objc(changeQSO:to:)
	func change(_ oldqso: UnsafeMutablePointer<ContestQSO>!, to callsign: UnsafeMutablePointer<CChar>!) {
		master?.changeQSO(oldqso, to: callsign)
	}

	//  local -- pick the Contest subclass for a contest name, set prototypeName as
	//  a side effect (mirrors the original -allocContest:) and return an initialised
	//  instance.  A non-nil parser drives the master's XML load in the initializer.
	private func makeContest(_ name: String, parser: XMLParser?) -> Contest? {
		switch name {
		case "Generic":
			prototypeName = "Generic"
			return Generic(contestName: name, prototype: prototypeName, parser: parser, manager: self)
		case "RST - Exchange":
			prototypeName = "RSTExchange"
			return RSTExchange(contestName: name, prototype: prototypeName, parser: parser, manager: self)
		case "RST - QSO Number":
			prototypeName = "RSTExchange"
			return RST_Number(contestName: name, prototype: prototypeName, parser: parser, manager: self)
		case "QSO Number (No RST)":
			prototypeName = "NumberOnly"
			return NumberOnly(contestName: name, prototype: prototypeName, parser: parser, manager: self)
		case "BARTG Sprint":
			prototypeName = "NumberOnly"
			return BARTGSprint(contestName: name, prototype: prototypeName, parser: parser, manager: self)
		case "CQ WPX RTTY":
			prototypeName = "RSTExchange"
			return WPX(contestName: name, prototype: prototypeName, parser: parser, manager: self)
		case "RTTY Roundup":
			prototypeName = "RSTExchange"
			return RTTYRoundup(contestName: name, prototype: prototypeName, parser: parser, manager: self)
		case "TARA":
			prototypeName = "RSTExchange"
			return TARA(contestName: name, prototype: prototypeName, parser: parser, manager: self)
		case "XE RTTY":
			prototypeName = "RSTExchange"
			return XERTTY(contestName: name, prototype: prototypeName, parser: parser, manager: self)
		case "BARTG HF":
			prototypeName = "BARTG"
			return BARTG(contestName: name, prototype: prototypeName, parser: parser, manager: self)
		case "SP RTTY":
			prototypeName = "RSTExchange"
			return SPRTTY(contestName: name, prototype: prototypeName, parser: parser, manager: self)
		default:
			return nil
		}
	}

	//  create a master contest instance
	@objc(selectContest:parser:)
	func selectContest(_ newContestName: String!, parser: XMLParser!) -> Contest! {
		clients = 0
		contestName = newContestName
		saveFileName = nil

		cabrilloMenuItem?.isEnabled = true
		saveMenuItem?.isEnabled = true
		saveAsMenuItem?.isEnabled = true
		showLogMenuItem?.isEnabled = true
		showMultMenuItem?.isEnabled = true
		clearQSOMenuItem?.isEnabled = true
		ignoreNewlineMenuItem?.isEnabled = true

		//  create a master contest
		master = makeContest(contestName ?? "", parser: parser)
		if let master = master {
			if let cabrilloInfo = cabrilloInfo { master.setCabrillo(cabrilloInfo) }
			return master
		}
		print("cannot alloc contest!")
		return nil
	}

	//  return the contest master
	@objc func contestObject() -> Contest! {
		return master
	}

	@objc(addContestClient:)
	func addContestClient(_ modem: ContestInterface!) {
		if master != nil {
			//  has master
			client[clients] = modem
			clients += 1
			//  clientContest provides the user interface; the actual database is in
			//  the master contest object.  Let the ContestInterface (mode) hook up
			//  its own user interface, then register this subordinate with the master.
			let clientContest = makeContest(contestName ?? "", parser: nil)
			modem?.initContest(clientContest, master: master, manager: self)
			if let clientContest = clientContest { master?.addSubordinate(clientContest) }
		}
	}

	@objc func startUp() {
		master?.newQSO(0)		// this will propagate to the subordinates
	}

	//  select the active contest interface, also set up fonts of interface at this point
	@objc(setActiveContestInterface:)
	func setActiveContestInterface(_ interface: ContestInterface!) {
		currentModem = interface
		master?.selectFirstResponder()
		//  3 macro sheets for CQ mode and 3 for S&P mode
		for i in 0..<6 { contestMacroSheet[i]?.setModem(currentModem) }
		//  set up fonts
		cabrilloInfo?.setFonts()
	}

	@objc func selectedContestInterface() -> ContestInterface! {
		return currentModem
	}

	//  fetch macro
	@objc(macroFor:)
	func macroFor(_ c: Int32) -> String? {
		if c == ascii("c") {
			//  callsign
			return contestCallsign
		}
		if c == ascii("h") {
			//  name
			return myName
		}
		return userInfo?.macroFor(c)
	}

	@objc(showCabrilloInfoSheet:)
	func showCabrilloInfoSheet(_ window: NSWindow!) {
		if let cabrilloInfo = cabrilloInfo, let window = window { cabrilloInfo.showSheet(window) }
	}

	@objc func cabrilloObject() -> Cabrillo! {
		return cabrilloInfo
	}

	@objc func userInfoObject() -> UserInfo! {
		return userInfo
	}

	@objc(showContestMacroSheet:)
	func showContestMacroSheet(_ n: Int32) {
		if let window = application?.mainWindow() {
			contestMacroSheet[Int(n)]?.showMacroSheet(window)
		}
	}

	@objc(contestSwitchedToCQ:)
	func contestSwitched(toCQ cqmode: Bool) {
		stdManager?.contestSwitchedToCQ(cqmode)
	}

	//  call from application when Command-1, etc seen
	@objc(executeContestMacroFromShortcut:sheet:modem:)
	@discardableResult
	func executeContestMacro(fromShortcut n: Int32, sheet: Int32, modem: ContestInterface!) -> Bool {
		let s = (sheet % 3) + (modem?.contestModeIndex ?? 0)		//  get sheet for CQ/S&P mode
		modem?.newMacroForContestBar(n, sheet: s)
		return executeContestMacro(n, sheet: s, modem: modem)
	}

	//  local
	private func updateQSOInfo() {
		//  first set up the needed QSO fields, in case they are needed
		guard let qsoInfo = qsoInfo else { return }

		let call = master?.callsign()
		qsoInfo.setCallsign(call ?? "")
		qsoInfo.setDXExchange(master?.fetchDXExchange() ?? "")

		var number: String? = nil
		if let raw = master?.qsoNumber() {
			let num = scanLeadingInt(raw, 0)
			number = String(format: "%03d", num)
			qsoInfo.setNumber(number!)
		}
		//  set exchange in QSO depending on whether we are DX or not
		if userInfo != nil, let call = call, !call.isEmpty, let number = number {
			let qth = userInfo?.qth()
			let isDX: Bool
			if qth == nil || qth!.isEmpty {
				isDX = true
			} else {
				isDX = qth!.lowercased().hasPrefix("dx")
			}
			qsoInfo.setExchangeString(isDX ? number : (qth ?? ""))
		}
	}

	@objc(executeContestMacro:sheet:modem:)
	@discardableResult
	func executeContestMacro(_ n: Int32, sheet: Int32, modem: ContestInterface!) -> Bool {
		if sheet >= 6 { return false }		// some internal error

		updateQSOInfo()

		guard let macroSheet = contestMacroSheet[Int(sheet)] else { return false }
		let title = macroSheet.title(n)

		if title == nil || title!.isEmpty {
			//  no macro defined for this button
			NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
			return false
		}
		modem?.executeMacro(n, macroSheet: macroSheet, fromContest: true)
		return true
	}

	@objc(macroTitles:)
	func macroTitles(_ sheet: Int32) -> NSMatrix! {
		return contestMacroSheet[Int(sheet)]?.titles()
	}

	@objc(setupDefaultPreferences:)
	func setupDefaultPreferences(_ pref: Preferences!) {
		preference = pref
		pref?.setString("", forKey: kRecentContest)

		cabrilloInfo?.setupDefaultPreferences(pref)
		contestLog?.setupDefaultPreferences(pref)
	}

	@objc(updateFromPlist:)
	@discardableResult
	func update(fromPlist pref: Preferences!) -> Bool {
		_ = contestLog?.updateFromPlist(pref)
		_ = cabrilloInfo?.updateFromPlist(pref)

		let recent = pref?.stringValue(forKey: kRecentContest)
		if let recent = recent, !recent.isEmpty { recentContestMenuItem?.title = recent }

		return true
	}

	@objc(retrieveForPlist:)
	func retrieve(forPlist pref: Preferences!) {
		contestLog?.retrieveForPlist(pref)
		cabrilloInfo?.retrieveForPlist(pref)
	}

	@objc(setDirty:)
	func setDirty(_ state: Bool) {
		dirty = state
	}

	//  log has been edited
	@objc func journalChanged() {
		setDirty(true)
		master?.createNewJournal()
	}

	@objc func okToQuit() -> Bool {
		if contestName == nil { return true }
		return !dirty
	}

	// expand macro in UserInfo and QSO info
	@objc(expandMacroInUserAndQSOInfo:)
	func expandMacroInUserAndQSOInfo(_ macro: UnsafePointer<CChar>!) -> String {
		var macroBuf = ""

		var p: UnsafePointer<CChar> = macro
		while p.pointee != 0 {
			var c = Int32(UInt8(bitPattern: p.pointee)); p += 1
			if c == ascii("%") {
				c = Int32(UInt8(bitPattern: p.pointee)); p += 1
				if c == ascii("b") || c == ascii("c") || c == ascii("h") || c == ascii("s") {
					if let userInfo = userInfo { macroBuf += userInfo.macroFor(c) }
				} else if c == ascii("x") {
					if let qsoInfo = qsoInfo { macroBuf += qsoInfo.macroFor(ascii("x")) }
				} else if c == ascii("C") || c == ascii("H") || c == ascii("n") {
					if let qsoInfo = qsoInfo { macroBuf += qsoInfo.macroFor(c) }
				}
			} else {
				macroBuf += String(UnicodeScalar(UInt8(truncatingIfNeeded: c)))
			}
		}
		return macroBuf
	}

	@objc(saveMacrosToXML:)
	func saveMacros(toXML file: UnsafeMutablePointer<FILE>!) {
		cmFPuts("\t<macros>\n", file)
		for i in 0..<6 {
			var caption = ""
			if let s = contestMacroSheet[i]?.captions() { caption = s as String }
			var body = ""
			if let s = contestMacroSheet[i]?.messages() { body = s as String }
			cmFPuts("\t\t<caption>\(caption)</caption>\n", file)
			cmFPuts("\t\t<body>\(body)</body>\n", file)
		}
		cmFPuts("\t</macros>\n", file)
	}

	@objc(saveCabrilloToXML:)
	func saveCabrillo(toXML file: UnsafeMutablePointer<FILE>!) {
		cmFPuts("\t<cabrillo>\n", file)
		cabrilloInfo?.saveFieldsToFile(file)
		cmFPuts("\t</cabrillo>\n", file)
	}

	//  local
	//  open/continue a contest from a specification file given
	private func contestWithPath(_ path: String) {
		//  try opening to check for existance of file
		guard let f = openFile(path, "r") else { return }
		fclose(f)

		contestName = nil
		isContestName = false; isMacros = false; isCabrillo = false
		isCName = false; isAddr1 = false; isAddr2 = false; isAddr3 = false; isEmail = false; isCategory = false; isBand = false; isExchange = false
		isCaption = false; isMessage = false
		xmlError = false
		let url = URL(fileURLWithPath: path)

		//  first pass to get contest name
		guard let xmlParser = XMLParser(contentsOf: url) else { return }
		xmlParser.shouldResolveExternalEntities = true
		xmlParser.delegate = self
		if !xmlParser.parse() {
			_ = Messages.alert(withMessageText: "Problem with contest file.", informativeText: "A parsing error occured with the contest file.")
			return
		}
		if xmlError {
			_ = Messages.alert(withMessageText: "Problem with contest file.", informativeText: "Duplicate contest name in the contest file?")
			return
		}
		if contestName == nil {
			_ = Messages.alert(withMessageText: "Problem with contest file.", informativeText: "No contest name found in file?")
			return
		}

		guard let xmlParser2 = XMLParser(contentsOf: URL(fileURLWithPath: path)) else { return }
		xmlParser2.shouldResolveExternalEntities = true
		// create contest and parse
		contestLog?.setBulkLog(true)
		_ = stdManager?.selectContest(contestName, parser: xmlParser2)
		contestLog?.setBulkLog(false)

		//  clean dirty bit after the log has been updated by the parser and mark session
		dirty = false
		sessionStarted = true
	}

	@objc(showLog:)
	func showLog(_ sender: Any?) {
		contestLog?.showWindow()
	}

	@objc(showMults:)
	func showMults(_ sender: Any?) {
		master?.showMultsWindow()
	}

	@objc(clearQSO:)
	func clearQSO(_ sender: Any?) {
		master?.clearCurrentQSO()
	}

	//  sender is a NSMenuItem
	//  resolve title and look inside application bundle's Contents/Resources/ for it, with xml extension
	@objc(newContest:)
	func newContest(_ sender: Any?) {
		if sessionStarted && dirty {
			_ = Messages.alert(withMessageText: "A contest session is already active!", informativeText: "You cannot start a new contest log in the middle of an existing contest session.\nSave the current session, quit and relaunch cocoaModem to start a fresh contest session.")
			return
		}
		let oldItem = selectedMenuItem
		oldItem?.state = .off
		selectedMenuItem = sender as? NSMenuItem
		selectedMenuItem?.state = .on

		let name = selectedMenuItem?.title ?? ""
		let bundle = Bundle.main
		var path = bundle.bundlePath
		path += "/Contents/Resources/"
		path += name
		path += ".xml"
		//  check if path is in app resources
		if let test = openFile(path, "r") {
			fclose(test)
			contestWithPath(path)
		} else {
			//  try it without the macros, etc
			var errString = "Cannot find file "
			errString += path
			errString += " .   Using default without loading macros."
			_ = Messages.alert(withMessageText: "Contest template file not found.", informativeText: errString)
			_ = stdManager?.selectContest(name, parser: nil)
		}
	}

	//  open a recent .xml contest file
	@objc(recentContest:)
	func recentContest(_ sender: Any?) {
		let path = recentContestMenuItem?.title ?? ""
		if path == "None" { return }

		if sessionStarted && dirty {
			_ = Messages.alert(withMessageText: "A contest session is already active!", informativeText: "You cannot resume a previous log in the middle of a contest session.")
			return
		}
		contestWithPath(path)
	}

	//  restore either from a contest archive (.xml) or a journal file (.jnl)
	@objc(continueContest:)
	func continueContest(_ sender: Any?) {
		if dirty {
			_ = Messages.alert(withMessageText: "Another contest session active!", informativeText: "You can only restore a contest when a contest session is not already running.")
			return
		}
		let open = NSOpenPanel()
		open.allowsMultipleSelection = false
		open.allowedFileTypes = [ "xml", "jnl" ]
		if open.runModal() == .OK, let path = open.url?.path {
			let inputFile = openFile(path, "r")
			let tempFile = openFile(kTempFile, "w")
			// create a file in .tmp which has the proper header and trailer
			if let inputFile = inputFile, let tempFile = tempFile {
				var isJournal = false
				var line = [CChar](repeating: 0, count: 133)
				while fgets(&line, 132, inputFile) != nil {
					//  check for journal
					if line[0] == CChar(UInt8(ascii: "<")) && strncmp(line, "<!-- |journal|", 14) == 0 { isJournal = true }
					fputs(line, tempFile)
				}
				if isJournal {
					//  if journal, append suffix
					fputs("\t</contestLog>\n", tempFile)
					fputs("</Contest>\n", tempFile)
				} else {
					//  if not journal, make it "recent contest"
					preference?.setString(path, forKey: kRecentContest)
					recentContestMenuItem?.title = path
				}
				fclose(tempFile)
				fclose(inputFile)
			}
			contestWithPath(kTempFile)
			dirty = true
		}
	}

	//  called from saveContest and log macro %[sl]
	@objc func actualSaveContest() {
		if saveFileName == nil {
			saveContestAs(self)
			return
		}
		master?.saveContest(saveFileName!)
		dirty = false
	}

	@objc(saveContest:)
	func saveContest(_ sender: Any?) {
		actualSaveContest()
	}

	@objc(saveContestAs:)
	func saveContestAs(_ sender: Any?) {
		var timet = time_t()
		time(&timet)
		let t = gmtime(&timet)
		let year: Int32 = (t?.pointee.tm_year ?? 0) + 1900

		let name = contestName ?? "Contest"
		let fullname = name + String(format: " %d.xml", year)

		let save = NSSavePanel()
		save.nameFieldStringValue = fullname
		if save.runModal() == .OK, let path = save.url?.path {
			saveFileName = path
			master?.saveContest(path)
			dirty = false
		}
	}

	@objc(createCabrillo:)
	func createCabrillo(_ sender: Any?) {
		if master != nil {
			//  create a file named callsign.log
			checkCallsign(nil)
			var callsign = contestCallsign ?? ""
			if callsign.isEmpty { callsign = "XXX" }
			let filename = callsign + ".log"

			let save = NSSavePanel()
			save.nameFieldStringValue = filename
			if save.runModal() == .OK, let path = save.url?.path {
				master?.writeCabrillo(toPath: path, callsign: callsign)
			}
		}
	}

	//  contest macro text field changed
	@objc(control:textShouldBeginEditing:)
	func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
		journalChanged()
		return true
	}

	//  --------- NSXMLParser delegates ---------------
	//  only need to recognize contestName
	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
		isContestName = (elementName == "contestName")
		isMacros = (elementName == "macros")
		isCabrillo = (elementName == "cabrillo")
		isCaption = (elementName == "caption")
		isMessage = (elementName == "body")
		isExchange = (elementName == "sent")
		isCName = (elementName == "cname")
		isAddr1 = (elementName == "addr1")
		isAddr2 = (elementName == "addr2")
		isAddr3 = (elementName == "addr3")
		isEmail = (elementName == "email")
		isCallUsed = (elementName == "callused")
		isNameUsed = (elementName == "nameused")
		isClub = (elementName == "club")
		isOperator = (elementName == "operator")
		isSoapbox = (elementName == "soapbox")
		isCategory = (elementName == "category")
		isBand = (elementName == "band")
	}

	func parser(_ parser: XMLParser, foundCharacters string: String) {
		if isContestName {
			if contestName != nil {
				xmlError = true	// duplicate contest name?
				contestName = nil
			} else {
				contestName = string
			}
		} else if isMacros {
			isCabrillo = false; isMessage = false
			messageSheet = 0; captionSheet = 0
		} else if isCabrillo {
			isCName = false; isAddr1 = false; isAddr2 = false; isAddr3 = false; isEmail = false; isCategory = false; isBand = false; isExchange = false
			isCallUsed = false; isNameUsed = false; isClub = false; isOperator = false; isSoapbox = false
		} else if isExchange { cabrilloInfo?.setExchange(string) }
		else if isCategory { cabrilloInfo?.setCategory(string) }
		else if isBand { cabrilloInfo?.setBand(string) }
		else if isCName { cabrilloInfo?.setCName(string) }
		else if isAddr1 { cabrilloInfo?.setCAddr1(string) }
		else if isAddr2 { cabrilloInfo?.setCAddr2(string) }
		else if isAddr3 { cabrilloInfo?.setCAddr3(string) }
		else if isEmail { cabrilloInfo?.setEmail(string) }
		else if isCallUsed { cabrilloInfo?.setCallUsed(string) }
		else if isNameUsed { cabrilloInfo?.setNameUsed(string) }
		else if isClub { cabrilloInfo?.setClub(string) }
		else if isOperator { cabrilloInfo?.setOperators(string) }
		else if isSoapbox { cabrilloInfo?.setSoapbox(string) }
		else if isCaption {
			if captionSheet >= 0 && captionSheet < 6 { contestMacroSheet[captionSheet]?.setCaptions(string) }
			captionSheet += 1
		} else if isMessage {
			if messageSheet >= 0 && messageSheet < 6 { contestMacroSheet[messageSheet]?.setMessages(string) }
			messageSheet += 1
		}
	}

	func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
		if elementName == "contestName" { isContestName = false }
		else if elementName == "macros" { isMacros = false }
		else if elementName == "cabrillo" { isCabrillo = false }
		else if elementName == "caption" { isCaption = false }
		else if elementName == "body" { isMessage = false }
		else if elementName == "sent" { isExchange = false }
		else if elementName == "cname" { isCName = false }
		else if elementName == "addr1" { isAddr1 = false }
		else if elementName == "addr2" { isAddr2 = false }
		else if elementName == "addr3" { isAddr3 = false }
		else if elementName == "email" { isEmail = false }
		else if elementName == "callused" { isCallUsed = false }
		else if elementName == "nameused" { isNameUsed = false }
		else if elementName == "club" { isClub = false }
		else if elementName == "operator" { isOperator = false }
		else if elementName == "soapbox" { isSoapbox = false }
		else if elementName == "category" { isCategory = false }
		else if elementName == "band" { isBand = false }
	}
}
