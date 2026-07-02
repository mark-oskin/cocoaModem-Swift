//
//  ContestLog.swift
//  cocoaModem
//
//  Created by Kok Chen on 12/23/04.
//
//  Swift port of ContestLog.m.  NSTableView data source / delegate that
//  holds the contest QSO log (an array of ContestQSOObj).
//

import Cocoa

private let kLatin1 = String.Encoding.isoLatin1.rawValue

//  preference keys (must match Plist.h)
private let kContestLogPosition = "ContestLogPosition"
private let kContestLogOrder = "ContestLogOrder"
private let kContestLogSize = "ContestLogSize"

//  informal access to the few ContestManager methods used here, resolved
//  through dynamic dispatch (keeps ContestManager.h out of the bridging header).
@objc private protocol ContestLogManager {
    @objc(changeQSO:to:)
    func changeQSO(_ oldqso: UnsafeMutablePointer<ContestQSO>, to callsign: UnsafeMutablePointer<CChar>)
    func journalChanged()
}

@objc(ContestLog)
class ContestLog: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    //  outlets connected by ContestLog.nib -- names must match nib keys exactly
    @objc var tableView: NSTableView!
    @objc var callsignSearchField: NSTextField!
    @objc var notFoundText: NSTextField!
    @objc var logLockButton: NSButton!
    @objc var infoField: NSTextField!

    private var manager: ContestLogManager?

    private var qsoNumber: NSTableColumn?
    private var callsign: NSTableColumn?
    private var timec: NSTableColumn?
    private var band: NSTableColumn?
    private var rst: NSTableColumn?
    private var received: NSTableColumn?
    private var mode: NSTableColumn?
    private var date: NSTableColumn?

    private var qsoArray = NSMutableArray()          //  array of ContestQSOObj
    private var ascend = [Bool](repeating: true, count: 8)
    private var previousLogColumn: NSTableColumn?
    private var currentSortCriterion: Int = 0
    private var searchIndex: Int = 0
    private var bulkLogEntry: Bool = false

    @objc(initWithManager:)
    init(manager control: Any?) {
        super.init()
        manager = control as? ContestLogManager
        //  this should call awakeFromNib
        _ = Bundle.main.loadNibNamed("ContestLog", owner: self, topLevelObjects: nil)
        callsignSearchField?.formatter = UpperFormatter()
        callsignSearchField?.delegate = self
    }

    @objc func awakeFromManager() {
        //  initialize QSO list for log (NSTableView)
        qsoArray = NSMutableArray(capacity: 2000)     //  initially 2000 items
        for i in 0..<8 { ascend[i] = true }
        previousLogColumn = nil
        currentSortCriterion = 0
        searchIndex = 0
        bulkLogEntry = false

        tableView.dataSource = self
        tableView.delegate = self                     //  delegate sorting

        let n = tableView.numberOfColumns
        let columns = tableView.tableColumns
        qsoNumber = nil; callsign = nil; timec = nil; band = nil
        rst = nil; received = nil; mode = nil; date = nil

        for i in 0..<n {
            var title = ""
            let column = columns[i]
            switch i {
            case 0: title = "QSO #";     qsoNumber = column
            case 1: title = "Call sign"; callsign = column
            case 2: title = "Time";      timec = column
            case 3: title = "Band";      band = column
            case 4: title = "RST";       rst = column
            case 5: title = "Received";  received = column
            case 6: title = "Mode";      mode = column
            case 7: title = "Date";      date = column
            default: break
            }
            column.identifier = NSUserInterfaceItemIdentifier(String(i))
            column.isEditable = false
            (column.headerCell as? NSTableHeaderCell)?.stringValue = title
        }
    }

    //  identifier holds the column's fixed integer index (was an NSNumber)
    private func columnID(_ column: NSTableColumn?) -> Int {
        guard let column = column else { return 0 }
        return Int(column.identifier.rawValue) ?? 0
    }

    @objc(displayInfo:)
    func displayInfo(_ info: UnsafeMutablePointer<CChar>) {
        infoField.stringValue = NSString(cString: info, encoding: kLatin1) as String? ?? ""
    }

    @objc(allowEdit:)
    func allowEdit(_ allow: Bool) {
        callsign?.isEditable = allow
        band?.isEditable = allow
        rst?.isEditable = allow
        received?.isEditable = allow
        mode?.isEditable = allow
    }

    @objc func showWindow() {
        tableView.window?.orderFront(self)
    }

    @objc(compare:)
    func compare(_ other: Any?) -> ComparisonResult {
        return .orderedSame
    }

    @objc(setupDefaultPreferences:)
    func setupDefaultPreferences(_ pref: Preferences) {
        pref.setString(tableView.window?.frameDescriptor ?? "", forKey: kContestLogPosition)

        pref.setString(defaultOrderString(), forKey: kContestLogOrder)

        let n = tableView.numberOfColumns
        let columns = tableView.tableColumns

        var w = [Int](repeating: 0, count: 16)
        for i in 0..<n {
            let column = columns[i]
            let j = columnID(column)
            w[j] = Int(column.width * 10)
        }
        pref.setString(widthString(w), forKey: kContestLogSize)
    }

    @objc(updateFromPlist:)
    @discardableResult
    func updateFromPlist(_ pref: Preferences) -> Bool {
        //  window position
        tableView.window?.setFrame(from: pref.stringValue(forKey: kContestLogPosition) ?? "")
        let columnString = Array((pref.stringValue(forKey: kContestLogOrder) ?? "").utf8)

        let n = tableView.numberOfColumns
        let columns = tableView.tableColumns

        for i in 0..<n {
            //  find who should map to column i (from columnString)
            guard i < columnString.count else { break }
            let c = Int(columnString[i])
            let p = (c >= 0x30 && c <= 0x39) ? (c - 0x30) : (c - 0x61 + 10)
            //  find the column whose identifier is the same as p
            for j in 0..<n {
                let column = columns[j]
                let identifier = columnID(column)
                if identifier == p && i != j {
                    tableView.moveColumn(j, toColumn: i)
                    break
                }
            }
        }
        let w = parseWidths(pref.stringValue(forKey: kContestLogSize) ?? "")
        for i in 0..<n {
            let column = columns[i]
            let j = columnID(column)
            column.width = CGFloat(w[j]) * 0.1
        }
        return true
    }

    @objc(retrieveForPlist:)
    func retrieveForPlist(_ pref: Preferences) {
        //  window position
        pref.setString(tableView.window?.frameDescriptor ?? "", forKey: kContestLogPosition)

        let n = tableView.numberOfColumns
        let columns = tableView.tableColumns

        //  column order
        var bytes = [UInt8](repeating: 0, count: 16)
        var i = 0
        while i < n {
            let column = columns[i]
            var identifier = columnID(column)
            if identifier < 0 { identifier = 0 } else if identifier >= n { identifier = n - 1 }
            bytes[i] = orderByte(identifier)
            i += 1
        }
        while i < 16 {
            bytes[i] = orderByte(i)
            i += 1
        }
        pref.setString(String(bytes: bytes, encoding: .isoLatin1) ?? "", forKey: kContestLogOrder)

        //  column widths
        var w = [Int](repeating: 0, count: 16)
        for i in 0..<n {
            let column = columns[i]
            let j = columnID(column)
            w[j] = Int(column.width * 10)
        }
        pref.setString(widthString(w), forKey: kContestLogSize)
    }

    //  '0'..'9' then 'a'.. for indices >= 10
    private func orderByte(_ v: Int) -> UInt8 {
        return (v < 10) ? UInt8(0x30 + v) : UInt8(0x61 - 10 + v)
    }

    private func defaultOrderString() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { bytes[i] = orderByte(i) }
        return String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    private func widthString(_ w: [Int]) -> String {
        return String(format: "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                      w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7],
                      w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15])
    }

    private func parseWidths(_ s: String) -> [Int] {
        var w = [Int](repeating: 0, count: 16)
        let scanner = Scanner(string: s)
        for i in 0..<16 {
            var v = 0
            if scanner.scanInt(&v) { w[i] = v } else { break }
        }
        return w
    }

    //  both find button and text field completion ends here
    @objc(findCallsign:)
    func findCallsign(_ sender: Any?) {
        let test = callsignSearchField.stringValue
        if test.isEmpty { return }

        let n = qsoArray.count
        var i = searchIndex
        while i < n {
            let q = qsoArray[i] as! ContestQSOObj
            if test == q.callsign() {
                tableView.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
                var j = i - 2
                if j < 0 { j = 0 }
                tableView.scrollRowToVisible(j)
                j = i + 2
                if j >= n { j = n - 1 }
                tableView.scrollRowToVisible(j)
                tableView.scrollRowToVisible(i)     //  make sure i is visible!
                //  update searchIndex for the next search
                searchIndex = i + 1
                return
            }
            i += 1
        }
        notFoundText.stringValue = (searchIndex == 0) ? "Not Found" : "No more QSO"
    }

    @objc(lockButtonChanged:)
    func lockButtonChanged(_ sender: Any?) {
        guard let button = sender as? NSButton else { return }
        switch button.state {
        case .off:
            button.title = "Locked"
            allowEdit(false)
        case .on:
            button.title = "Unlocked"
            allowEdit(true)
        default:
            break
        }
    }

    /* local */
    private func sortQSOList(_ p: ContestQSOObj, compare: (ContestQSOObj, ContestQSOObj) -> ComparisonResult) -> Int {
        var lower = 0
        let count = qsoArray.count
        var upper = count - 1
        var lastn = -1

        //  limit search to 2^16
        var order: ComparisonResult = .orderedAscending
        var n = 0
        for _ in 0..<16 {
            n = (upper + lower) / 2
            if n == lastn { break }
            lastn = n

            let q = qsoArray[n] as! ContestQSOObj
            order = compare(p, q)
            if order == .orderedAscending { upper = n } else { lower = n }
        }
        if order == .orderedDescending { n += 1 }

        return n
    }

    @objc(setBulkLog:)
    func setBulkLog(_ bulk: DarwinBoolean) {
        let old = bulkLogEntry
        bulkLogEntry = bulk.boolValue
        if old != bulkLogEntry && bulkLogEntry == false {
            //  finally sort at the end of a bulk entry
            tableView.reloadData()
        }
    }

    //  called from a Contest Interface when a new QSO is logged
    //  inform the ContestLog (NSTableView)
    @objc(newQSOCreated:)
    func newQSOCreated(_ qso: UnsafeMutablePointer<ContestQSO>) {
        let p = ContestQSOObj(with: qso)
        if bulkLogEntry {
            qsoArray.add(p)
            return
        }

        var whereIndex = 0
        switch currentSortCriterion {
        case 0:
            //  sort by QSO number
            if ascend[0] {
                qsoArray.add(p)
                whereIndex = qsoArray.count - 1
            } else {
                qsoArray.insert(p, at: 0)
            }
        case 1:
            let n = ascend[1]
                ? sortQSOList(p) { $0.sortByCallsign($1) }
                : sortQSOList(p) { $0.reverseByCallsign($1) }
            qsoArray.insert(p, at: n)
            whereIndex = n
        case 3:
            let n = ascend[3]
                ? sortQSOList(p) { $0.sortByBand($1) }
                : sortQSOList(p) { $0.reverseByBand($1) }
            qsoArray.insert(p, at: n)
            whereIndex = n
        default:
            //  default to adding at the end
            qsoArray.add(p)
            whereIndex = qsoArray.count - 1
        }
        tableView.noteNumberOfRowsChanged()
        tableView.scrollRowToVisible(whereIndex)
    }

    private func convertToUpper(_ string: UnsafeMutablePointer<CChar>) {
        var p = string
        while p.pointee != 0 {
            var v = Int(UInt8(bitPattern: p.pointee))
            if v == 216 || v == 175 { /* slashed zero */ v = 0x30 }
            if v >= 0x61 && v <= 0x7a { v += 0x41 - 0x61 }
            p.pointee = CChar(bitPattern: UInt8(truncatingIfNeeded: v))
            p = p.advanced(by: 1)
        }
    }

    //  ----- delegates ---------------

    //  ContestLog (NSTableViewDataSource)
    func numberOfRows(in tableView: NSTableView) -> Int {
        return qsoArray.count
    }

    //  ContestLog asking for a table value (NSTableViewDataSource)
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row index: Int) -> Any? {
        let column = columnID(tableColumn)
        let qso = qsoArray[index] as! ContestQSOObj
        var string = ""

        switch column {
        case 0:
            // QSO #
            string = String(format: "%d", qso.qsoNumber())
        case 1:
            //  call sign
            string = qso.callsign()
        case 2:
            //  time
            let t = qso.time()
            string = String(format: "%02d:%02d", Int(t.pointee.hour), Int(t.pointee.minute))
        case 3:
            //  band
            string = String(format: "%5d", qso.band())
        case 4:
            //  RST (can be blank)
            string = qso.rst()
        case 5:
            //  received exchange
            string = qso.exchange()
        case 6:
            //  mode
            string = qso.mode()
        case 7:
            //  date
            let t = qso.time()
            string = String(format: "%02d-%02d-%02d", Int(t.pointee.day), Int(t.pointee.month), Int(t.pointee.year) % 100)
        default:
            break
        }
        return string
    }

    //  value set from ContestLog (NSTableViewDataSource)
    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row index: Int) {
        let column = columnID(tableColumn)
        var value = object as? String ?? ""
        let qso = qsoArray[index] as! ContestQSOObj
        var changed = false

        switch column {
        case 1:
            // callsign
            let was = qso.callsign()
            //  change to NIL if empty
            if value.isEmpty { value = "NIL" }
            if was == value { /* no change */ return }
            // need to modify the log data structure in the contest
            guard let src = (value as NSString).cString(using: kLatin1) else { return }
            var buf = [CChar](repeating: 0, count: 64)
            buf.withUnsafeMutableBufferPointer { p in
                let dst = p.baseAddress!
                strncpy(dst, src, 63)
                dst[63] = 0
                convertToUpper(dst)
                manager?.changeQSO(qso.ptr(), to: dst)
            }
            changed = true
        case 3:
            // band
            let old = qso.band()
            var metres = old
            if value.isEmpty { value = "20" }
            let scanner = Scanner(string: value)
            var v = 0
            if scanner.scanInt(&v) { metres = Int32(truncatingIfNeeded: v) }
            if metres != old {
                if metres == 160 || metres == 80 || metres == 40 || metres == 20 || metres == 15 || metres == 10 {
                    qso.setBand(metres)
                    changed = true
                }
            }
        case 4:
            // RST
            let was = qso.rst()
            if value.isEmpty { value = "599" }
            if was == value { /* no change */ return }
            qso.setRST(value)
            changed = true
        case 5:
            // received exchange
            let was = qso.exchange()
            if was == value { /* no change */ return }
            qso.setExchange(value)
            changed = true
        case 6:
            //  mode
            if value.isEmpty { value = "RY" }
            guard let src = (value as NSString).cString(using: kLatin1) else { return }
            var buf = [CChar](repeating: 0, count: 64)
            let matched: Bool = buf.withUnsafeMutableBufferPointer { p in
                let dst = p.baseAddress!
                strncpy(dst, src, 3)
                dst[2] = 0
                convertToUpper(dst)
                if strcmp(dst, (qso.mode() as NSString).cString(using: kLatin1)) == 0 { return false }
                if strcmp(dst, "RY") == 0 || strcmp(dst, "CW") == 0 || strcmp(dst, "PH") == 0 || strcmp(dst, "PK") == 0 {
                    qso.setQSOMode(dst)
                    return true
                }
                return false
            }
            if matched { changed = true } else { return }
        default:
            break
        }
        if changed { manager?.journalChanged() }
    }

    //  clicked on column header (NSTableViewDelegate), decide on the sort method to use
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let reclick = (previousLogColumn == tableColumn)
        previousLogColumn = tableColumn

        let column = columnID(tableColumn)
        currentSortCriterion = column

        if reclick { ascend[column] = !ascend[column] }

        let preamble = ascend[column] ? "sort" : "reverse"

        let sortSelector: Selector
        switch column {
        case 0: sortSelector = NSSelectorFromString(preamble + "ByNumber:")
        case 1: sortSelector = NSSelectorFromString(preamble + "ByCallsign:")
        case 3: sortSelector = NSSelectorFromString(preamble + "ByBand:")
        default: return
        }
        qsoArray.sort(using: sortSelector)
        tableView.reloadData()
    }

    //  reset search index
    func controlTextDidChange(_ aNotification: Notification) {
        notFoundText.stringValue = ""
        searchIndex = 0
    }

    //  allow editing tableview columns that are editable
    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row index: Int) -> Bool {
        return true
    }
}
