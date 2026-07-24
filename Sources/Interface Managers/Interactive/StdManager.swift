//
//  StdManager.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 8/7/05.
//  Swift port of StdManager.m.
//
//  StdManager is the standard interactive interface manager (a ModemManager
//  subclass).  It creates every modem interface from the plist "Modems" string,
//  owns the QSO panel / contest bar tabview, the shared RTTY macro sheets, and
//  routes the contest machinery through the (still Objective-C) ContestManager.
//

import Cocoa

//  ascii '1' -- the "modem enabled" marker inside the kModemList plist string
private let kStdEnabledMarker: unichar = 0x31

@objc(StdManager)
class StdManager: ModemManager {

    //  ---- outlets (names must match the nib keys exactly) ----
    @objc private var qsoTabviewTextured: NSTabView!
    @objc private var qsoTabviewUntextured: NSTabView!
    //  ContestManager remains Objective-C -- reference it via the bridging header
    @objc private var contestManager: ContestManager!

    private var qsoTabview: NSTabView!
    private var qso: QSO!
    private var contestBar: ContestBar!

    private var tooltip: NSView.ToolTipTag = 0
    private var enableCloseButton = false
    private var isTextured = false

    private var contest: Contest!
    private var qsoShowing = false
    private var contestInCQ = false

    //  common macro sheet for all RTTY macros
    private var rttyMacroSheet: [RTTYMacros?] = [nil, nil, nil]

    //  ------------------------------------------------------------------

    @objc(setupWindow:lite:)
    override func setupWindow(_ textured: Bool, lite: Bool) {
        //  create logging object
        log = nil
        if logView != nil {
            log = Messages(intoView: logView)
            log?.awakeFromApplication()
        }

        super.setupWindow(textured, lite: lite)
        takesContestMenus = true
        //  set up main window
        let window = tabview.window
        window?.orderOut(self)
        if let view = window?.contentView {
            tooltip = view.addToolTip(view.bounds, owner: "", userData: nil)
            view.toolTip = ""
        }
        enableCloseButton = true
        contestInCQ = true
        qsoShowing = false
        contest = nil
        isTextured = textured

        //  QSO/ContestBar
        qsoTabview = textured ? qsoTabviewTextured : qsoTabviewUntextured
        qso = QSO(intoTabView: qsoTabview, app: application)
        contestBar = ContestBar(intoTabView: qsoTabview, app: application)
        //  initialize ContestManager
        contestManager?.awakeFromApplication()
        contestManager?.initContestMacros()

        //  set delegate window to ourself
        window?.delegate = self
    }

    @objc(useSmoothPattern:)
    override func useSmoothPattern(_ state: Bool) {
        //  "smooth" = a flat window fill instead of the (now-removed) brushed
        //  metal texture.  Use the semantic windowBackgroundColor so the fill
        //  follows the system Light/Dark appearance instead of the old fixed
        //  deviceWhite 0.80 grey, which washed out under Dark mode.
        if isTextured {
            let window = tabview.window
            window?.backgroundColor = state ? .windowBackgroundColor : nil
        }
    }

    @objc(setModemCanTransmit:)
    override func setModemCanTransmit(_ state: Bool) {
        //  turn off QSO log items for non transmitting modes
        qso?.showOnlyDateAndTime(DarwinBoolean(!state))
    }

    //  is the modem enabled in the kModemList plist string?
    private func modemEnabled(_ modemString: String, _ order: Int32) -> Bool {
        let idx = Int(order)
        let ns = modemString as NSString
        if idx < 0 || idx >= ns.length { return false }
        return ns.character(at: idx) == kStdEnabledMarker
    }

    //  create one InstalledModem entry and append it
    @discardableResult
    private func addInstalled(_ modem: Modem?, name: String, contest: Bool, rttyMacro: Bool,
                              slashedZero: Bool, receiveOnly: Bool, receiveViews: Int32) -> InstalledModem {
        let entry = InstalledModem()
        entry.modem = modem
        entry.name = name
        entry.tabItem = modem?.tabItem()
        entry.contest = contest
        entry.rttyMacro = rttyMacro
        entry.slashedZero = slashedZero
        entry.receiveOnly = receiveOnly
        entry.numberOfReceiveViews = receiveViews
        entry.updatedFromPlist = false
        installedModem.append(entry)
        return entry
    }

    //  here is where all the modems are created
    @objc(createModems:startModemsFromPlist:)
    override func createModems(_ pref: Preferences!, startModemsFromPlist modemList: Preferences!) {
        super.createModems(pref, startModemsFromPlist: modemList)

        let dummy = tabview.tabViewItem(at: 0)
        tabview.removeTabViewItem(dummy)
        //  create modems from the initial plist and place into the tabview.
        //  modems with tabs at right are created first; modems that support
        //  contests need to have the contest bar set.
        installedModem.removeAll()
        finishedCreatingModems = false          //  v0.41

        var modemString = modemList.stringValue(forKey: kModemList)
        if modemString == nil { modemString = "11111111111111" }
        let modems = modemString!

        if modemEnabled(modems, Int32(kAMModemOrder)) && isLiteWindow == false {
            let m = SynchAM(into: tabview, manager: self)
            addInstalled(m, name: "am", contest: false, rttyMacro: false,
                         slashedZero: false, receiveOnly: true, receiveViews: 0)
        }
        if modemEnabled(modems, Int32(kFAXModemOrder)) && isLiteWindow == false {
            let m = FAX(into: tabview, manager: self)
            addInstalled(m, name: "fax", contest: false, rttyMacro: false,
                         slashedZero: false, receiveOnly: true, receiveViews: 0)
        }
        if modemEnabled(modems, Int32(kSitorModemOrder)) && isLiteWindow == false {
            let m = SITOR(into: tabview, manager: self)
            sitor = m
            addInstalled(m, name: "sitor modem", contest: false, rttyMacro: false,
                         slashedZero: false, receiveOnly: true, receiveViews: 2)
        }
        if modemEnabled(modems, Int32(kASCIIModemOrder)) && isLiteWindow == false {
            let m = ASCII(into: tabview, manager: self)
            asciiRTTY = m
            addInstalled(m, name: "ascii rtty modem", contest: false, rttyMacro: true,
                         slashedZero: true, receiveOnly: false, receiveViews: 2)
        }
        if modemEnabled(modems, Int32(kCWModemOrder)) && isLiteWindow == false {
            let m = WBCW(into: tabview, manager: self)
            cw = m
            addInstalled(m, name: "cw modem", contest: true, rttyMacro: false,
                         slashedZero: true, receiveOnly: false, receiveViews: 2)
        }
        if modemEnabled(modems, Int32(kHellModemOrder)) && isLiteWindow == false {
            let m = Hellschreiber(into: tabview, manager: self)
            hell = m
            addInstalled(m, name: "hellschreiber modem", contest: true, rttyMacro: false,
                         slashedZero: false, receiveOnly: false, receiveViews: 0)
        }
        if modemEnabled(modems, Int32(kMFSKModemOrder)) && isLiteWindow == false {
            let m = MFSK(into: tabview, manager: self)
            mfsk = m
            addInstalled(m, name: "mfsk modem", contest: false, rttyMacro: false,
                         slashedZero: true, receiveOnly: false, receiveViews: 1)
        }
        if modemEnabled(modems, Int32(kPSKModemOrder)) {
            let m: Modem?
            if isLiteWindow {
                m = LitePSK(into: tabview, manager: self)
            } else {
                m = PSK(into: tabview, manager: self)
            }
            psk = m
            addInstalled(m, name: "psk modem", contest: true, rttyMacro: false,
                         slashedZero: true, receiveOnly: false, receiveViews: 2)
        }
        if modemEnabled(modems, Int32(kDualRTTYModemOrder)) && isLiteWindow == false {
            let m = DualRTTY(into: tabview, manager: self)
            dualRTTY = m
            addInstalled(m, name: "dual rtty modem", contest: true, rttyMacro: true,
                         slashedZero: true, receiveOnly: false, receiveViews: 2)
        }
        if modemEnabled(modems, Int32(kWidebandRTTYModemOrder)) {
            let m: Modem?
            if isLiteWindow {
                m = LiteRTTY(into: tabview, manager: self)
                (m as? LiteRTTY)?.showControlWindow(false)      //  v0.64c don't display yet
            } else {
                m = WFRTTY(into: tabview, manager: self)
            }
            wfRTTY = m
            addInstalled(m, name: "wideband rtty modem", contest: true, rttyMacro: true,
                         slashedZero: true, receiveOnly: false, receiveViews: 2)
        }
        if modemEnabled(modems, Int32(kRTTYModemOrder)) && isLiteWindow == false {
            //  v0.41 -- installedModems must be updated before calling initIntoTabView
            let entry = InstalledModem()
            installedModem.append(entry)
            installedModems = Int32(installedModem.count)
            let m = RTTY(into: tabview, manager: self)
            rtty = m
            entry.modem = m
            entry.name = "rtty modem"
            entry.tabItem = m?.tabItem()
            entry.contest = true
            entry.rttyMacro = true
            entry.slashedZero = true
            entry.receiveOnly = false
            entry.numberOfReceiveViews = 1
            entry.updatedFromPlist = false
        }
        installedModems = Int32(installedModem.count)
        finishedCreatingModems = true           //  v0.41
    }

    //  v0.53b
    @objc func selectDefaultModem() {
    }

    //  0.53b -- called after deferred plist is updated in super -willSelectTabViewItem
    @objc(updateContestBar:)
    override func updateContestBar(_ modem: ContestInterface!) {
        modem?.setContestBar(contestBar)
    }

    //  0.53b -- moved to the deferred Plist update code in ModemManager
    @objc override func updateModemSources() {
        return
    }

    //  switch all contest-capable modems between interactive and contest interface
    @objc(useContestMode:)
    func useContestMode(_ state: Bool) {
        for installed in installedModem {
            if installed.contest { (installed.modem as? ContestInterface)?.selectContestMode(state) }
        }
    }

    //  enable/disable all installed modems
    @objc(enableModems:)
    override func enableModems(_ state: Bool) {
        for installed in installedModem {
            installed.modem?.enableModem(state)
        }
    }

    //  called from selectContest:parser:
    private func createContestClients() -> Contest! {
        var activeInterface: ContestInterface?
        let currentTabViewItem = tabview.selectedTabViewItem

        for installed in installedModem {
            if installed.contest {
                contestManager?.addContestClient(installed.modem as? ContestInterface)
                if currentTabViewItem === installed.tabItem {
                    activeInterface = installed.modem as? ContestInterface
                    activeInterface?.updateContestMacroButtons()
                }
            }
        }
        if let activeInterface = activeInterface {
            contestManager?.setActiveContestInterface(activeInterface)
            contestManager?.startUp()
        }
        return contest
    }

    //  local -- the modem whose tab is currently selected (was -selectedModem in
    //  StdManager.m; renamed to avoid clashing with the base selectedModem ivar)
    private func selectedTabModem() -> Modem? {
        let currentTabViewItem = tabview.selectedTabViewItem
        for installed in installedModem {
            if currentTabViewItem === installed.tabItem {
                return installed.modem
            }
        }
        return nil
    }

    //  v0.96c
    @objc(selectView:)
    func selectView(_ index: Int32) {
        selectedTabModem()?.selectView(index)
    }

    @objc func selectedModemName() -> String! {
        let currentTabViewItem = tabview.selectedTabViewItem
        for installed in installedModem {
            if currentTabViewItem === installed.tabItem { return installed.name }
        }
        return "unknown modem"
    }

    @objc(switchCurrentModemToTransmit:)
    func switchCurrentModem(toTransmit state: Bool) {
        selectedTabModem()?.enterTransmitMode(state)
    }

    @objc func flushCurrentModem() {
        selectedTabModem()?.flushAndLeaveTransmit()
    }

    @objc override func showConfigPanel() {
        selectedTabModem()?.showConfigPanel()
    }

    @objc override func closeConfigPanels() {
        for installed in installedModem {
            installed.modem?.closeConfigPanel()
        }
    }

    @objc func updateQSOWindow() {
        let index: Int
        if application?.contestModeState() == true {
            index = contestInCQ ? 2 : 1
        } else {
            index = qsoShowing ? 0 : 1
        }
        qsoTabview.selectTabViewItem(at: index)
    }

    @objc(setEnableQSOInterface:)
    func setEnableQSOInterface(_ state: Bool) {
        qsoShowing = state
        application?.qsoEnableItem()?.state = qsoShowing ? .on : .off
        updateQSOWindow()
    }

    @objc func qsoInterfaceShowing() -> Bool {
        return qsoShowing
    }

    @objc func toggleQSOShowing() {
        setEnableQSOInterface(!qsoShowing)
    }

    //  v1.01a
    @objc func selectQSOCall() {
        qso?.selectCall()
    }

    //  v1.01a
    @objc func selectQSOName() {
        qso?.selectName()
    }

    //  called from ContestManager
    @objc(contestSwitchedToCQ:)
    func contestSwitchedToCQ(_ cqmode: Bool) {
        contestInCQ = cqmode
        updateQSOWindow()
    }

    @objc func currentContest() -> Contest! {
        return contest
    }

    @objc(selectContest:parser:)
    func selectContest(_ contestName: String!, parser: XMLParser!) -> Contest! {
        application?.switchInterfaceMode(1)
        contest = contestManager?.selectContest(contestName, parser: parser)
        return createContestClients()
    }

    @objc(executeContestMacroFromShortcut:sheet:modem:)
    @discardableResult
    func executeContestMacro(fromShortcut n: Int32, sheet: Int32, modem: ContestInterface!) -> Bool {
        return contestManager?.executeContestMacro(fromShortcut: n, sheet: sheet, modem: modem) ?? false
    }

    @objc func showCabrilloInfo() {
        contestManager?.showCabrilloInfoSheet(tabview.window)
    }

    @objc override func updateRTTYMacroButtons() {
        for installed in installedModem {
            if installed.rttyMacro { (installed.modem as? MacroInterface)?.updateModeMacroButtons() }
        }
    }

    @objc func displayRTTYScope() {
        if wfRTTY != nil { (wfRTTY as? WFRTTY)?.showScope() }
        else if rtty != nil { (rtty as? RTTY)?.showScope() }
        else if dualRTTY != nil { (dualRTTY as? DualRTTY)?.showScope() }
    }

    @objc func qsoObject() -> QSO! {
        return qso
    }

    @objc func qsoTabviewObject() -> NSTabView! {
        return qsoTabview
    }

    @objc override func okToQuit() -> Bool {
        return contestManager?.okToQuit() ?? true
    }

    //  create the shared RTTY macros
    private func createRTTYMacros(_ pref: Preferences!) {
        for i in 0..<3 {
            let macroSheet = RTTYMacros(sheet: ())
            rttyMacroSheet[i] = macroSheet
            macroSheet.setUserInfo(application?.userInfoObject(), qso: qso, modem: nil, canImport: true)
            macroSheet.setupDefaultPreferences(pref, option: Int32(i))
        }
    }

    private func loadRTTYMacros(_ pref: Preferences!) {
        showSplash("Loading RTTY macros")
        for i in 0..<3 {
            guard let macroSheet = rttyMacroSheet[i] else { continue }
            _ = macroSheet.updateFromPlist(pref, option: Int32(i))
            //  link and update RTTY mode macros to the common RTTY macros
            for installed in installedModem {
                if installed.rttyMacro {
                    (installed.modem as? MacroInterface)?.setMacroSheet(macroSheet, index: Int32(i))
                }
            }
        }
        updateRTTYMacroButtons()
    }

    private func retrieveRTTYMacros(_ pref: Preferences!) {
        for i in 0..<3 {
            rttyMacroSheet[i]?.retrieveForPlist(pref, option: Int32(i))
        }
    }

    @objc(setupDefaultPreferences:)
    override func setupDefaultPreferences(_ pref: Preferences!) {
        createRTTYMacros(pref)
        //  set up defaults of each component
        for installed in installedModem {
            installed.modem?.setupDefaultPreferences(pref)
        }
        contestManager?.setupDefaultPreferences(pref)
    }

    //  v0.53b -- defer plist updates
    @objc(updateFromPlist:)
    override func update(fromPlist pref: Preferences!) -> Bool {
        _ = super.update(fromPlist: pref)

        loadRTTYMacros(pref)
        _ = contestManager?.update(fromPlist: pref)
        return true
    }

    @objc(retrieveForPlist:)
    override func retrieve(forPlist pref: Preferences!) {
        super.retrieve(forPlist: pref)
        retrieveRTTYMacros(pref)
        contestManager?.retrieve(forPlist: pref)

        for installed in installedModem {
            installed.modem?.retrieveForPlist(pref)
        }
    }

    @objc(setAppearancePrefs:)
    override func setAppearancePrefs(_ appearancePrefs: NSMatrix!) {
        let count = appearancePrefs.numberOfRows
        let window = tabview.window
        for i in 0..<count {
            //  matrix cells are NSButtonCells; -state lives on NSCell
            guard let b = appearancePrefs.cell(atRow: i, column: 0) else { continue }
            let state = b.state
            if state == .on {
                switch i {
                case 1:
                    //  enable main window close button
                    enableCloseButton = true
                case 2:
                    //  hide main window on deactivation
                    window?.hidesOnDeactivate = true
                case 3:
                    //  hide aux windows on deactivation
                    if rtty != nil { (rtty as? RTTY)?.hideScopeOnDeactivation(true) }
                case 6:
                    //  slashed zeros
                    for installed in installedModem {
                        if installed.slashedZero { installed.modem?.useSlashedZero(true) }
                    }
                case 7:
                    useWatchdogFlag = true
                default:
                    break
                }
            } else {
                switch i {
                case 1:
                    //  disable main window close button
                    enableCloseButton = false
                case 2:
                    //  disable hide main window on deactivation
                    window?.hidesOnDeactivate = false
                case 3:
                    //  disable hide aux windows on deactivation
                    if rtty != nil { (rtty as? RTTY)?.hideScopeOnDeactivation(false) }
                case 4:
                    //  remove tooltips from modems
                    for installed in installedModem {
                        installed.modem?.removeToolTips()
                    }
                case 6:
                    //  slashed zeros
                    for installed in installedModem {
                        if installed.slashedZero { installed.modem?.useSlashedZero(false) }
                    }
                case 7:
                    useWatchdogFlag = false
                default:
                    break
                }
            }
        }
    }

    @objc(setPSKPrefs:)
    override func setPSKPrefs(_ pskPrefs: NSMatrix!) {
        let count = pskPrefs.numberOfRows
        for i in 0..<count {
            guard let b = pskPrefs.cell(atRow: i, column: 0) else { continue }
            let state = b.state
            let pskModem = psk as? PSK
            if state == .on {
                switch i {
                case 0:
                    //  use control instead of option
                    pskModem?.useControlButton(true)
                case 1:
                    pskModem?.setAFCState(true)
                case 2:
                    pskModem?.setAllowShiftJIS(true)
                default:
                    break
                }
            } else {
                switch i {
                case 0:
                    //  use option instead of control
                    pskModem?.useControlButton(false)
                case 1:
                    pskModem?.setAFCState(false)
                case 2:
                    pskModem?.setAllowShiftJIS(false)
                default:
                    break
                }
            }
        }
    }

    //  delegate of main window
    @objc(windowShouldClose:)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if enableCloseButton {
            NSApp.terminate(self)
            return true
        }
        NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
        return false
    }

    //  AppleScript support

    //  contest band
    @objc override func band() -> Int32 {
        if contest == nil { return 0 }
        return contest.selectedBand()
    }

    @objc(setBand:)
    override func setBand(_ data: Int32) {
        contest?.selectBand(data)
    }

    @objc(selectInterface:)
    override func selectInterface(_ command: NSScriptCommand!) {
        let param = command.directParameter as? NSScriptObjectSpecifier
        let type = param?.key
        application?.changeInterface(to: self, alternate: type == "contestInterface")
    }

    @objc(resetWatchdog:)
    override func resetWatchdog(_ command: NSScriptCommand!) {
        selectedModem?.resetWatchdog()
    }

    @objc func dualRTTYModem() -> Modem! {
        return dualRTTY
    }

    @objc func wfRTTYModem() -> Modem! {
        return wfRTTY
    }

    @objc func rttyModem() -> Modem! {
        return rtty
    }

    @objc func pskModem() -> Modem! {
        return psk
    }

    @objc func hellschreiberModem() -> Modem! {
        return hell
    }

    @objc func cwModem() -> Modem! {
        return cw
    }

    @objc func mfskModem() -> Modem! {
        return mfsk
    }

    @objc func sitorModem() -> Modem! {
        return sitor
    }

    @objc(QSOData)
    func qsoData() -> QSO! {
        return qso
    }

    //  v0.97
    @objc(openTableView:)
    func openTableView(_ sender: Any?) {
        if selectedTabModem() === pskModem() {
            (pskModem() as? PSK)?.openTableView(true)
        } else {
            NSSound.beep()
        }
    }

    //  v0.97
    @objc(closeTableView:)
    func closeTableView(_ sender: Any?) {
        if selectedTabModem() === pskModem() {
            (pskModem() as? PSK)?.openTableView(false)
        } else {
            NSSound.beep()
        }
    }

    //  v0.97
    @objc(nextStationInTableView:)
    func nextStationInTableView(_ sender: Any?) {
        if selectedTabModem() === pskModem() {
            (pskModem() as? PSK)?.nextStationInTableView()
        } else {
            NSSound.beep()
        }
    }

    //  v1.01c
    @objc(previousStationInTableView:)
    func previousStationInTableView(_ sender: Any?) {
        if selectedTabModem() === pskModem() {
            (pskModem() as? PSK)?.previousStationInTableView()
        } else {
            NSSound.beep()
        }
    }
}
