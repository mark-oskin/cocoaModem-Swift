//
//  ModemManager.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 8/7/05.
//  Swift port of ModemManager.m.
//
//  ModemManager is the abstract base of the interface-manager tree.  It owns the
//  main window's NSTabView, tracks the set of installed modems, and is the
//  delegate of both the tabview (to follow modem selection) and the window (for
//  close/quit).  The concrete interactive manager is StdManager (a subclass).
//
//  The InstalledModem C struct (was in ModemManager.h) is expressed here as a
//  small Swift reference type -- it is used only inside ModemManager/StdManager.
//

import Cocoa

//  interface-mode FourCharCodes for the deprecated AppleScript support.
//  (Originally the RTTYInterfaceMode/PSKInterfaceMode enum in modemTypes.h,
//  which is no longer reachable from Swift once ModemManager.h is removed.)
private let kRTTYInterfaceMode: Int32 = 0x69727479      // 'irty'
private let kPSKInterfaceMode:  Int32 = 0x6970736B      // 'ipsk'

//  file-scope diagnostic flag (was Boolean gTestDump in ModemManager.m)
var gTestDump = false

//  was: typedef struct { ... } InstalledModem ;
final class InstalledModem {
    var name: String = ""                   //  AppleScript name
    var modem: Modem?
    var tabItem: NSTabViewItem?
    var contest = false
    var rttyMacro = false                    //  use shared RTTY macros
    var slashedZero = false
    var receiveOnly = false
    var numberOfReceiveViews: Int32 = 0      //  v0.96c
    var updatedFromPlist = false
}

@objc(ModemManager)
class ModemManager: NSObject, NSTabViewDelegate, NSWindowDelegate {

    //  ---- outlets (names must match the nib keys exactly) ----
    //  used by StdManager too -> internal
    @objc var application: Application!
    @objc var logView: NSTextView!
    //  used only by the base -> private
    @objc private var tabviewTextured: NSTabView!
    @objc private var tabviewUntextured: NSTabView!
    @objc private var tabviewLite: NSTabView!
    @objc private var waitPanel: NSPanel!
    @objc private var waitProgressBar: NSProgressIndicator!
    @objc private var selectReceive1MenuItem: NSMenuItem!
    @objc private var selectReceive2MenuItem: NSMenuItem!
    @objc private var selectTransmitMenuItem: NSMenuItem!

    //  the tabview (textured/untextured/lite) which is actually in use
    var tabview: NSTabView!
    var log: Messages!

    //  PTT
    private var ptt: PTTHub!

    //  modems (accessed by StdManager) -> internal
    var rtty: Modem!
    var psk: Modem!
    var dualRTTY: Modem!
    var wfRTTY: Modem!
    var asciiRTTY: Modem!
    var cw: Modem!
    var mfsk: Modem!
    var hell: Modem!
    var sitor: Modem!
    private var analyze: Modem!
    var selectedModem: Modem!

    //  Preferences (0.53b)
    private var preferences: Preferences!

    //  SDR (SoftRock is still Objective-C and not in the bridging header; it is
    //  only ever nil'd here and never messaged)
    private var softRock: AnyObject?

    var installedModem: [InstalledModem] = []
    var installedModems: Int32 = 0

    private var origin: NSPoint = .zero
    private var windowLocked = false

    var takesContestMenus = false
    //  renamed from the Objective-C ivar "useWatchdog" to avoid clashing with the
    //  -useWatchdog accessor of the same name
    var useWatchdogFlag = false
    var isLiteWindow = false
    var finishedCreatingModems = false      //  v0.41

    //  ------------------------------------------------------------------

    @objc(setupWindow:lite:)
    func setupWindow(_ textured: Bool, lite: Bool) {
        isLiteWindow = lite
        takesContestMenus = false
        useWatchdogFlag = true
        preferences = nil                   //  v0.53b

        //  create hub for PTT actions
        ptt = PTTHub()

        //  AppleScript support for window position
        windowLocked = false

        //  select whether to use textured interface
        if lite {
            tabview = tabviewLite
        } else {
            tabview = textured ? tabviewTextured : tabviewUntextured
        }
        //  hide window for now
        if let window = tabview.window {
            if lite { window.level = .normal }
            window.orderOut(self)
            //  delegate window for close/quit
            window.delegate = self
        }
        //  set tabview delegate to ourself to capture tab changes
        tabview.delegate = self
    }

    @objc(useSmoothPattern:)
    func useSmoothPattern(_ state: Bool) {
        //  implemented in StdManager
    }

    //  v0.70
    @objc(setUseShiftJIS:)
    func setUseShiftJIS(_ state: Bool) {
        (psk as? PSK)?.setUseShiftJIS(state)
    }

    //  v0.70
    @objc(setUseRawForPSK:)
    func setUseRawForPSK(_ state: Bool) {
        (psk as? PSK)?.setUseRawForPSK(state)
    }

    //  v0.71
    @objc(setAllowShiftJISForPSK:)
    func setAllowShiftJISForPSK(_ state: Bool) {
        application?.setAllowShiftJISForPSK(state)
    }

    @objc func applicationTerminating() {
        enableModems(false)
        for i in 0..<Int(installedModems) {
            installedModem[i].modem?.applicationTerminating()
        }
    }

    @objc func pttHub() -> PTTHub! {
        return ptt
    }

    @objc(showSplash:)
    func showSplash(_ msg: String!) {
        application?.showSplash(msg)
    }

    //  override by subclass
    @objc func updateRTTYMacroButtons() {
    }

    //  override by subclass
    @objc(createModems:startModemsFromPlist:)
    func createModems(_ pref: Preferences!, startModemsFromPlist modemList: Preferences!) {
        rtty = nil; psk = nil; dualRTTY = nil; wfRTTY = nil
        cw = nil; hell = nil; analyze = nil; selectedModem = nil
        softRock = nil
        installedModems = 0
        preferences = pref                  //  0.53b
    }

    //  override by subclass
    @objc func updateModemSources() {
    }

    @objc(activateModems:)
    func activateModems(_ state: Bool) {
        if state == false {
            enableModems(false)
            tabview.window?.orderOut(self)
        } else {
            enableModems(true)
            //  check to see if window should be visible  v0.64c
            if (NSApp.delegate as? AppDelegate)?.windowIsVisible() == true {
                tabview.window?.orderFront(self)
            }
        }
    }

    //  override by subclass
    @objc(enableModems:)
    func enableModems(_ state: Bool) {
    }

    @objc func currentModem() -> Modem! {
        return selectedModem
    }

    @objc(modemIsVisible:)
    func modemIsVisible(_ modem: Modem!) -> Bool {
        let currentTabViewItem = tabview.selectedTabViewItem
        return currentTabViewItem === modem?.tabItem()
    }

    //  Recursively clearing tooltips inside a view
    @objc(clearToolTipsInView:)
    func clearToolTips(inView view: NSView?) {
        guard let view = view else { return }
        view.removeAllToolTips()
        for sub in view.subviews {
            clearToolTips(inView: sub)
        }
    }

    //  v0.53b -- for case where there is only one modem interface
    private func switchToInstalledModem(_ installed: InstalledModem) {
        if !finishedCreatingModems { return }

        let newModem = installed.modem
        let enableContest = installed.contest
        let canTransmit = !installed.receiveOnly

        if let newModem = newModem {
            selectedModem = newModem
            selectedModem.setVisibleState(true)
            if enableContest { (selectedModem as? ContestInterface)?.updateContestMacroButtons() }     // v0.21
            setModemCanTransmit(canTransmit)
        }
        if takesContestMenus { application?.enableContestMenuItems(enableContest) }
    }

    //  0.31 / 0.53d also call -selectModemInTabViewItem
    private func switchToTabView(_ index: Int32) {
        var index = index
        let selected = tabview.selectedTabViewItem
        let currentIndex = (selected != nil) ? tabview.indexOfTabViewItem(selected!) : NSNotFound

        if Int(index) == currentIndex {
            //  v0.78 - need to call selectModemInTabViewItem if the tab view had
            //  changed previously (happens when first launched into a tab view)
            selectModemInTabViewItem(tabview.selectedTabViewItem)
        } else {
            if index < 0 { index = 0 }
            tabview.selectTabViewItem(at: Int(index))
            //  v0.76 the above already causes tabview:willSelectTabViewItem: to run
        }
    }

    //  select a modem by its reference.  Return NO if not possible.
    @objc(selectModem:)
    func selectModem(_ modem: Modem!) -> Bool {
        if let item = modem?.tabItem() {
            //  make sure it exists by looking for the index
            let index = tabview.indexOfTabViewItem(item)
            if index != NSNotFound {
                switchToTabView(Int32(index))
                return true
            }
        }
        return false
    }

    //  select a modem by its tab view name
    @objc(selectTabView:)
    func selectTabView(_ viewName: String!) {
        let n = tabview.numberOfTabViewItems
        for i in 0..<n {
            let tabName = tabview.tabViewItem(at: i).label
            if tabName == viewName {
                switchToTabView(Int32(i))
                return
            }
        }
        //  v0.53b select first view when the original tab name is not found
        switchToTabView(0)
    }

    //  return name of tab view item
    @objc func nameOfSelectedTabView() -> String! {
        return tabview.selectedTabViewItem?.label
    }

    @objc func activeTabView() -> NSTabViewItem! {
        return tabview.selectedTabViewItem
    }

    //  override by subclass to display current modem config panel
    @objc func showConfigPanel() {
    }

    @objc func showSoftRock() {
    }

    //  override by subclass to close all modem config panels
    @objc func closeConfigPanels() {
    }

    @objc func appObject() -> Application! {
        return application
    }

    //  return the window (textured or untextured) which is in use
    @objc func windowObject() -> NSWindow! {
        return tabview.window
    }

    @objc func okToQuit() -> Bool {
        return true
    }

    @objc(setModemCanTransmit:)
    func setModemCanTransmit(_ state: Bool) {
    }

    @objc func useWatchdog() -> Bool {
        return useWatchdogFlag
    }

    @objc(setupDefaultPreferences:)
    func setupDefaultPreferences(_ pref: Preferences!) {
    }

    @objc(updateFromPlist:)
    func update(fromPlist pref: Preferences!) -> Bool {
        return true
    }

    @objc(retrieveForPlist:)
    func retrieve(forPlist pref: Preferences!) {
    }

    @objc(setAppearancePrefs:)
    func setAppearancePrefs(_ appearancePrefs: NSMatrix!) {
    }

    @objc(setPSKPrefs:)
    func setPSKPrefs(_ pskPrefs: NSMatrix!) {
    }

    @objc(showDiagnostic:)
    func showDiagnostic(_ sender: Any?) {
        if let log = log { log.show() }
    }

    //  v0.41
    @objc(setModemAtTab:)
    func setModemAtTab(_ tabViewItem: NSTabViewItem!) {
        var newModem: Modem?
        var enableContest = false
        var canTransmit = false

        //  flag new modem as active
        for installed in installedModem {
            if installed.modem?.tabItem() === tabViewItem {
                newModem = installed.modem
                enableContest = installed.contest
                canTransmit = !installed.receiveOnly
                break
            }
        }
        if let newModem = newModem {
            selectedModem = newModem
            selectedModem.setVisibleState(true)
            if enableContest { (selectedModem as? ContestInterface)?.updateContestMacroButtons() }     // v0.21
            setModemCanTransmit(canTransmit)
        }
        if takesContestMenus { application?.enableContestMenuItems(enableContest) }
    }

    //  v0.53b overridden by StdManager to defer updating the contest bar
    //  (which does not exist in ModemManager)
    @objc(updateContestBar:)
    func updateContestBar(_ modem: ContestInterface!) {
    }

    private func updateModemNow(_ installed: InstalledModem) {
        //  gSplashShowing global moved into the Swift Application class
        let splashShowing = Application.splashShowing

        if installed.updatedFromPlist == false {
            if splashShowing == false {
                waitProgressBar?.usesThreadedAnimation = true
                waitPanel?.orderFront(self)
                Thread.sleep(forTimeInterval: 0.1)
                waitProgressBar?.startAnimation(self)
            }
            _ = installed.modem?.updateFromPlist(preferences)

            if installed.contest { updateContestBar(installed.modem as? ContestInterface) }
            //  turn on active if updateFromPlist has set the active button
            if splashShowing == false {
                Thread.sleep(forTimeInterval: 0.1)
            }
            installed.modem?.updateSourceFromConfigInfo()
            //  set the already-updated-from-Plist flag
            installed.updatedFromPlist = true
            if splashShowing == false {
                waitProgressBar?.stopAnimation(self)
                waitPanel?.orderOut(self)
            }
        }
    }

    //  0.53d -- called when tab changes or when the app starts (to select first modem)
    @objc(selectModemInTabViewItem:)
    func selectModemInTabViewItem(_ tabViewItem: NSTabViewItem!) {
        var installedMatch: InstalledModem?
        var newModem: Modem?
        var enableContest = false
        var canTransmit = false

        //  flag new modem as active
        for installed in installedModem {
            if installed.modem?.tabItem() === tabViewItem {
                installedMatch = installed
                newModem = installed.modem
                enableContest = installed.contest
                canTransmit = !installed.receiveOnly
                break
            }
        }
        if let newModem = newModem, let installed = installedMatch {
            //  v0.53b if the plist has not yet been updated, update the modem from
            //  the plist and also update the active state
            if installed.updatedFromPlist == false { updateModemNow(installed) }
            //  change visibility if needed
            if selectedModem !== newModem {
                selectedModem?.setVisibleState(false)       //  disable previous modem
                selectedModem = newModem
                selectedModem.setVisibleState(true)
                if enableContest { (selectedModem as? ContestInterface)?.updateContestMacroButtons() }     // v0.21
            }
            setModemCanTransmit(canTransmit)
            //  v0.87
            selectedModem.switchModemIn()

            //  v0.99 -- Gestalt(gestaltSystemVersionMinor) > 4 test removed; on every
            //  supported macOS this branch is always taken (see report)
            selectTransmitMenuItem?.isHidden = installed.receiveOnly
            selectReceive1MenuItem?.isHidden = installed.numberOfReceiveViews < 1
            selectReceive2MenuItem?.isHidden = installed.numberOfReceiveViews < 2
        }
        if takesContestMenus { application?.enableContestMenuItems(enableContest) }
    }

    //  v1.02b
    @objc(directSetFrequency:)
    func directSetFrequency(_ freq: Float) {
        if selectedModem == nil { return }
        selectedModem.directSetFrequency(freq)
    }

    //  v1.02b
    @objc func selectedFrequency() -> Float {
        if selectedModem == nil { return -10.0 }
        return selectedModem.selectedFrequency()
    }

    //  v1.02c
    @objc func speakModemSelection() {
        _ = application?.speakAssist(tabview.selectedTabViewItem?.label ?? "")
        _ = application?.speakAssist(" interface selected.")
    }

    //  v1.02c
    @objc(tabView:didSelectTabViewItem:)
    func tabView(_ view: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if view === tabview {
            speakModemSelection()
            //  the Swift AppDelegate has appLevel == 1, so this always drills into
            //  the application object (the appLevel == 0 path could not fire)
            (NSApp.delegate as? AppDelegate)?.application()?.updateDirectAccessFrequency()
        }
    }

    //  v1.02c
    @objc func selectNextModem() {
        guard let selected = tabview.selectedTabViewItem else { return }
        let i = tabview.indexOfTabViewItem(selected)
        let n = tabview.numberOfTabViewItems
        if i > (n - 2) { tabview.selectFirstTabViewItem(self) } else { tabview.selectNextTabViewItem(self) }
    }

    //  v1.02c
    @objc func selectPreviousModem() {
        guard let selected = tabview.selectedTabViewItem else { return }
        let i = tabview.indexOfTabViewItem(selected)
        if i == 0 { tabview.selectLastTabViewItem(self) } else { tabview.selectPreviousTabViewItem(self) }
    }

    //  delegate of tabview -- tracks which modem interface is being viewed.
    //  sound streams are activated/deactivated here.
    @objc(tabView:willSelectTabViewItem:)
    func tabView(_ view: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        let oldTabViewItem = tabview.selectedTabViewItem

        if !finishedCreatingModems { return }

        if view === tabview && tabViewItem !== oldTabViewItem {
            application?.clearAllVoices()        //  v0.96d
            //  tab view changed
            application?.closeConfigPanels()
            Thread.sleep(forTimeInterval: 0.05)
            selectModemInTabViewItem(tabViewItem)
        }
    }

    //  -- AppleScript support --

    @objc func backgroundColor() -> NSColor! {
        guard let window = tabview.window else {
            return NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
        }
        return window.backgroundColor.usingColorSpaceName(.deviceRGB)
    }

    @objc(setBackgroundColor:)
    func setBackgroundColor(_ inColor: NSColor!) {
        let color = inColor.usingColorSpaceName(.deviceRGB)
        tabview.window?.backgroundColor = color
    }

    @objc func windowPosition() -> NSPoint {
        return tabview.window?.frame.origin ?? .zero
    }

    @objc(setWindowPosition:)
    func setWindowPosition(_ position: NSPoint) {
        guard var frame = tabview.window?.frame else { return }
        frame.origin = position
        tabview.window?.setFrame(frame, display: true)
    }

    //  AppleScript for showing/hiding window
    @objc func windowState() -> Bool {
        return tabview.window?.isVisible ?? false
    }

    @objc(setWindowState:)
    func setWindowState(_ state: Bool) {
        let window = tabview.window
        if state == true { window?.makeKeyAndOrderFront(self) } else { window?.orderOut(self) }
        (NSApp.delegate as? AppDelegate)?.setWindowIsVisible(state)
    }

    //  AppleScript select <interface> command
    @objc(selectInterface:)
    func selectInterface(_ command: NSScriptCommand!) {
    }

    @objc(resetWatchdog:)
    func resetWatchdog(_ command: NSScriptCommand!) {
    }

    //  contest band
    @objc func band() -> Int32 {
        return 0
    }

    @objc(setBand:)
    func setBand(_ data: Int32) {
    }

    @objc func position() -> Data! {
        let point = tabview.window?.frame.origin ?? .zero
        var array: [Int16] = [
            Int16(truncatingIfNeeded: Int(point.y)),
            Int16(truncatingIfNeeded: Int(point.x)),
        ]
        return Data(bytes: &array, count: 4)
    }

    @objc(setPosition:)
    func setPosition(_ data: Data!) {
        guard let data = data, data.count >= 4 else { return }
        let (p0, p1): (Int16, Int16) = data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            return (p[0], p[1])
        }
        origin.x = CGFloat(Int(p1) - 1)
        origin.y = CGFloat(p0)
        tabview.window?.setFrameOrigin(origin)
    }

    @objc func lock() -> Bool {
        return windowLocked
    }

    @objc(setLock:)
    func setLock(_ state: Bool) {
        windowLocked = state
    }

    //  ---------- the following have been deprecated ----------
    @objc func pskModulation() -> Int32 {
        if let psk = psk as? PSK { return psk.getPskModulation() }
        return 0
    }

    @objc(setPskModulation:)
    func setPskModulation(_ modulation: Int32) {
        if let psk = psk as? PSK { psk.changePskModulationTo(modulation) }
    }

    @objc func modemMode() -> Int32 {
        let modem = currentModem()
        if modem === rtty || modem === dualRTTY { return kRTTYInterfaceMode }
        if modem === psk { return kPSKInterfaceMode }
        return 0
    }

    @objc(setModemMode:)
    func setModemMode(_ interfaceMode: Int32) {
        let target: String
        switch interfaceMode {
        case kPSKInterfaceMode:
            target = "PSK"
        default:            //  RTTYInterfaceMode
            target = "RTTY"
        }
        let n = tabview.numberOfTabViewItems
        for i in 0..<n {
            let str = tabview.tabViewItem(at: i).label
            if target == str.uppercased() {
                switchToTabView(Int32(i))
                break
            }
        }
    }

    @objc(testDump:)
    func testDump(_ sender: Any?) {
        gTestDump = true
    }
}
