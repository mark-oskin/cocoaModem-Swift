//
//  PSKBrowserTable.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 10/20/08.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//  Swift port of PSKBrowserTable.m.  (Slot/Row C structs live in
//  PSKBrowserTypes.h so they can be shared with PSKBrowserHub.m.)
//

import Cocoa

@objc(PSKBrowserTable)
class PSKBrowserTable: NSObject {

    //  IBOutlet id
    @objc var alarmTextField: NSTextField!
    @objc var ignoreCaseCheckbox: NSButton!

    private var hub: PSKBrowserHub!

    private var table: NSTableView!
    private var freqColumn: NSTableColumn!
    private var textColumn: NSTableColumn!
    private var fontAdvance: Float = 0

    private var alarmText: NSDictionary!

    //  Slot slot[41], Row row[21]  -> heap buffers with the shared C layout.
    private let slotStorage = UnsafeMutablePointer<Slot>.allocate(capacity: 41)
    private let rowStorage = UnsafeMutablePointer<Row>.allocate(capacity: 21)
    private var busy: NSLock!

    private var dot: String = "."
    private var null: String = ""
    private var returnString: NSMutableString!
    private var attributedString: NSMutableAttributedString!
    //  vfo offsets
    private var isUSB: Bool = true
    private var vfoOffset: Float = 0

    private var refreshTimer: Timer!            //  ObjC ivar was "refreshCheck"
    private var refreshCycle: Int32 = 0
    private var refreshBusy: Bool = false

    //  alarms
    private var alarmString: String?
    private var alarmMask: NSString.CompareOptions = .caseInsensitive
    private var alarmLock: NSLock!

    //  Byte offset of the C array member `message` inside Slot.
    private static let messageOffset = MemoryLayout<Slot>.offset(of: \Slot.message)!

    private func messagePointer(_ i: Int) -> UnsafeMutablePointer<unichar> {
        let raw = UnsafeMutableRawPointer(slotStorage)
            .advanced(by: i * MemoryLayout<Slot>.stride + PSKBrowserTable.messageOffset)
        return raw.assumingMemoryBound(to: unichar.self)
    }

    //  C truncated (finite) float->int toward zero; guard NaN/inf.
    private func cInt(_ x: Float) -> Int32 {
        if !x.isFinite { return 0 }
        if x >= 2147483647.0 { return Int32.max }
        if x <= -2147483648.0 { return Int32.min }
        return Int32(x)
    }

    //  The tableView has 21 rows, mapped from 41 possible slots of 50 Hz each.
    private func initSlot(_ index: Int32, row rowIndex: Int32, frequency freq: Float) {
        let i = Int(index)
        slotStorage[i].row = rowIndex
        slotStorage[i].frequency = freq
        slotStorage[i].length = 220
        let s = messagePointer(i)
        let space: unichar = 32
        for k in 0..<220 { s[k] = space }       //  left fill with spaces
        slotStorage[i].spaces = 0
        slotStorage[i].active = false
    }

    @objc(initWithTable:client:)
    init(table which: NSTableView, client: PSKBrowserHub) {
        super.init()
        slotStorage.initialize(repeating: Slot(), count: 41)
        rowStorage.initialize(repeating: Row(), count: 21)

        alarmLock = NSLock()
        alarmString = nil
        alarmMask = .caseInsensitive
        Bundle.main.loadNibNamed("PSKAlarms", owner: self, topLevelObjects: nil)

        alarmText = [NSAttributedString.Key.foregroundColor: NSColor.red] as NSDictionary

        table = which
        busy = NSLock()
        hub = client

        let columns = table.tableColumns
        freqColumn = columns[1]
        textColumn = columns[0]

        vfoOffset = 0
        isUSB = true

        dot = "."
        null = ""
        returnString = NSMutableString(capacity: 1024)
        returnString.setString(null)

        attributedString = NSMutableAttributedString(string: "test 0123456789")

        //  assume fixed width font
        if let cell = textColumn.dataCell as? NSCell, let font = cell.font {
            fontAdvance = Float(font.maximumAdvancement.width)
        }

        //  allow up to 41 (50 Hz wide) frequency slots
        for i in 0..<41 { initSlot(Int32(i), row: -1, frequency: -1) }   // init slots as unused
        for i in 0..<21 {
            rowStorage[i].slot = -1
            rowStorage[i].dirty = false
            rowStorage[i].refreshedCount = 0
            rowStorage[i].refreshNeeded = 0
        }
        refreshBusy = false
        refreshTimer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(refreshCheck(_:)), userInfo: self, repeats: true)
    }

    deinit {
        refreshTimer?.invalidate()
        slotStorage.deinitialize(count: 41)
        slotStorage.deallocate()
        rowStorage.deinitialize(count: 21)
        rowStorage.deallocate()
    }

    /* local */
    private func setInterface(_ object: NSControl, to selector: Selector) {
        object.action = selector
        object.target = self
    }

    @objc func alarmChanged() {
        alarmLock.lock()

        let string = alarmTextField.stringValue
        if string.count > 0 { alarmString = string } else { alarmString = nil }
        alarmMask = (ignoreCaseCheckbox.state == .on) ? .caseInsensitive : []

        alarmLock.unlock()
    }

    override func awakeFromNib() {
        setInterface(alarmTextField, to: #selector(alarmChanged))
        setInterface(ignoreCaseCheckbox, to: #selector(alarmChanged))
        alarmChanged()
    }

    @objc func openAlarm() {
        alarmTextField.window?.makeKeyAndOrderFront(self)
    }

    @objc func refreshCheck(_ timer: Timer) {
        if refreshBusy { return }
        refreshBusy = true

        var i = Int(refreshCycle & 0x1)
        refreshCycle += 1
        while i < 21 {
            let refreshNeeded = rowStorage[i].refreshNeeded
            if rowStorage[i].refreshedCount < refreshNeeded {
                let tableRow = isUSB ? i : 20 - i
                table.setNeedsDisplay(table.rect(ofRow: tableRow))
                rowStorage[i].refreshedCount = refreshNeeded
            }
            i += 2
        }
        refreshBusy = false
    }

    @objc func slot() -> UnsafeMutablePointer<Slot> {
        return slotStorage
    }

    private func mappedRow(_ inrow: Int32) -> Int32 {
        if isUSB { return inrow }
        return 20 - inrow               //  v0.59 bugfix; was 21-inrow
    }

    //  note: the rows assigned here is referenced to the absolute tone (irrespective of USB or LSB)
    @objc(assignRow:toSlot:frequency:)
    func assignRow(_ rowIndex: Int32, toSlot slotIndex: Int32, frequency freq: Float) {
        if rowIndex < 0 || rowIndex > 20 { return }
        rowStorage[Int(rowIndex)].slot = slotIndex
        initSlot(slotIndex, row: rowIndex, frequency: freq)
    }

    @objc(rowIsInUse:)
    func rowIsInUse(_ rowIndex: Int32) -> DarwinBoolean {
        if rowIndex < 0 || rowIndex > 20 { return true }
        return (rowStorage[Int(rowIndex)].slot < 0) ? false : true
    }

    private func updateRow(_ rowIndex: Int32) {
        if rowIndex < 0 || rowIndex > 20 { return }
        rowStorage[Int(rowIndex)].refreshNeeded += 1
    }

    @objc(checkAndUpdateRow:)
    func checkAndUpdateRow(_ rowIndex: Int32) {
        if rowIndex < 0 || rowIndex > 20 { return }
        if !rowStorage[Int(rowIndex)].dirty.boolValue { return }
        rowStorage[Int(rowIndex)].refreshNeeded += 1
    }

    @objc(removeSlot:)
    func removeSlot(_ slotIndex: Int32) {
        if slotIndex < 0 || slotIndex > 40 { return }   //  sanity check

        //  unlink row points to slots
        let rowIndex = slotStorage[Int(slotIndex)].row
        if rowIndex >= 0 && rowIndex < 21 { rowStorage[Int(rowIndex)].slot = -1 }

        initSlot(slotIndex, row: -1, frequency: -1)
        updateRow(rowIndex)
    }

    @objc(frequencyForSlot:)
    func frequencyForSlot(_ slotIndex: Int32) -> Float {
        if slotIndex < 0 || slotIndex > 40 { return 0.0 }
        return slotStorage[Int(slotIndex)].frequency
    }

    @objc(rowForSlot:)
    func rowForSlot(_ slotIndex: Int32) -> Int32 {
        if slotIndex < 0 || slotIndex > 40 { return -1 }
        return slotStorage[Int(slotIndex)].row
    }

    @objc(slotForRow:)
    func slotForRow(_ rowIndex: Int32) -> Int32 {
        //  ObjC only tested (> 20); also reject negatives to stay in bounds.
        if rowIndex < 0 || rowIndex > 20 { return -1 }
        return rowStorage[Int(rowIndex)].slot
    }

    @objc func numberOfRows(in tableView: NSTableView) -> Int {
        //  set to 21 rows
        return 21
    }

    //  v0.70 change from ascii to unicode
    //  clears the buffer if freq < 0; that should free the slot
    @objc(addUnicodeCharacter:toSlot:withFrequency:)
    func addUnicodeCharacter(_ unicode: unichar, toSlot slotIndex: Int32, withFrequency freq: Float) {
        if slotIndex < 0 || slotIndex > 40 { return }   //  sanity check
        let si = Int(slotIndex)
        let rowIndex = slotStorage[si].row
        if rowIndex < 0 || rowIndex > 20 { return }

        slotStorage[si].frequency = freq
        slotStorage[si].active = true
        var length = Int(slotStorage[si].length)
        let s = messagePointer(si)

        if unicode == 8 {
            //  backspace
            if length <= 2 { return }   //  don't apply backspace for the first couple of characters
            if slotStorage[si].spaces > 0 {
                slotStorage[si].spaces -= 1
                if slotStorage[si].spaces >= 3 { return }
            }
            slotStorage[si].length = Int32(length - 1)
            updateRow(rowIndex)
            return
        }
        if length <= 0 {
            s[0] = unicode
            slotStorage[si].length = 1
        } else {
            //  truncate spaces to at most 3
            if unicode == 32 {          //  ' '
                slotStorage[si].spaces += 1
                if slotStorage[si].spaces > 3 { return }
            } else {
                slotStorage[si].spaces = 0
            }

            if length >= 512 {
                //  exceeded buffer length, prune it back to 200 characters
                memcpy(s, s + (512 - 200), 200 * MemoryLayout<unichar>.size)
                length = 200
            }
            s[length] = unicode
            slotStorage[si].length = Int32(length + 1)
        }
        updateRow(rowIndex)
    }

    @objc(setVFOOffset:sideband:)
    func setVFOOffset(_ offset: Float, sideband polarity: DarwinBoolean) {
        isUSB = polarity.boolValue
        vfoOffset = offset
        table.reloadData()
    }

    //  v0.70  - change font metric for ShiftJIS
    @objc(tableView:objectValueForTableColumn:row:)
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row requestedRow: Int) -> Any? {
        let inrow = Int32(requestedRow)
        let rowIndex = mappedRow(inrow)     //  in LSB, the table row is inverted from the virtual row

        let t = slotForRow(rowIndex)
        var sp = (t < 0 || t > 40) ? -1 : Int(t)
        if sp >= 0 && slotStorage[sp].active.boolValue == false { sp = -1 }

        if tableColumn == freqColumn {
            if sp < 0 { return dot }

            var freq = slotStorage[sp].frequency
            if freq < 0 { return dot }

            freq -= vfoOffset
            if !isUSB { freq = -freq }

            returnString.setString(String(format: "%d", cInt(freq + 0.5)))
            return returnString
        }

        if sp < 0 || slotStorage[sp].length <= 0 {
            rowStorage[Int(rowIndex)].dirty = false
            return null
        }
        let s = messagePointer(sp)
        rowStorage[Int(rowIndex)].dirty = true

        //  typography nonsense so text line fits the table column
        let tableWidth = Float(tableColumn?.width ?? 0)
        var width: Float = 0
        let end = Int(slotStorage[sp].length) - 1
        var i = 0
        while i <= end {
            width += (s[end - i] > 256) ? fontAdvance * 1.7 : fontAdvance * 1.10
            if width > tableWidth { break }
            i += 1
        }
        let characters = i
        let str = NSString(characters: s + (Int(slotStorage[sp].length) - characters), length: characters) as String

        if alarmString == nil { return str }

        //  check for alarms
        alarmLock.lock()

        var range = (str as NSString).range(of: alarmString!, options: alarmMask)
        if range.location == NSNotFound {
            alarmLock.unlock()
            return str
        }

        //  Has alarm -- create attributedString to highlight the alarm string.
        let length = attributedString.length
        attributedString.removeAttribute(.foregroundColor, range: NSMakeRange(0, 1))
        attributedString.replaceCharacters(in: NSMakeRange(0, length), with: str)

        //  find other ranges
        var offset = 0
        let strlength = (str as NSString).length
        for _ in 0..<50 {
            range.location += offset
            attributedString.addAttribute(.foregroundColor, value: NSColor.red, range: range)
            //  next search at a different offset in the string
            offset = range.location + range.length
            if offset >= strlength { break }        //  reach end of string
            let substr = (str as NSString).substring(from: offset)
            range = (substr as NSString).range(of: alarmString!, options: alarmMask)
            if range.location == NSNotFound { break }   //  no more found
        }
        alarmLock.unlock()
        return attributedString
    }

    //	v0.97, 1.01d
    @objc(selectSlot:)
    func selectSlot(_ slotIndex: Int32) -> Float {
        let mappedRowIndex = Int(mappedRow(rowForSlot(slotIndex)))

        if mappedRowIndex >= 0 {
            table.selectRowIndexes(IndexSet(integer: mappedRowIndex), byExtendingSelection: false)
        }
        if slotIndex >= 0 && slotIndex < 40 {
            hub.tableViewSelectedTone(slotStorage[Int(slotIndex)].frequency, option: false)
            return slotStorage[Int(slotIndex)].frequency
        }
        return -1
    }

    //	v0.97
    @objc func unselectSlots() {
        table.deselectAll(self)
    }

    @objc(tableView:shouldSelectRow:)
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        let optionClicked = (tableView as? ClickedTableView)?.optionClicked().boolValue ?? false

        let rowIndex = mappedRow(Int32(row))
        let index = slotForRow(rowIndex)
        if index >= 0 && index < 40 {
            hub.tableViewSelectedTone(slotStorage[Int(index)].frequency, option: optionClicked)
        }

        return true
    }

    @objc(updateFromPlist:)
    func updateFromPlist(_ pref: Preferences) -> DarwinBoolean {
        if let str = pref.stringValue(forKey: kPSKAlarmString), alarmTextField != nil {
            alarmTextField.stringValue = str
        }
        if let str = pref.stringValue(forKey: kPSKAlarmCase), ignoreCaseCheckbox != nil {
            let ns = str as NSString
            if ns.length > 0 {
                ignoreCaseCheckbox.state = (ns.character(at: 0) == 49 /* '1' */) ? .on : .off
            }
        }
        if alarmTextField != nil { alarmChanged() }

        return true
    }

    @objc(retrieveForPlist:)
    func retrieveForPlist(_ pref: Preferences) {
        if alarmTextField != nil {
            pref.setString(alarmTextField.stringValue, forKey: kPSKAlarmString)
        }
        if ignoreCaseCheckbox != nil {
            pref.setString((ignoreCaseCheckbox.state == .on) ? "1" : "0", forKey: kPSKAlarmCase)
        }
    }
}
